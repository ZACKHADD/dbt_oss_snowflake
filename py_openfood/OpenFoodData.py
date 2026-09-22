import argparse
import json
import logging
import requests
import snowflake.connector
from io import BytesIO
import os
from cryptography.hazmat.primitives import serialization
from pathlib import Path
import time



################################################
#                  Logging                    #
################################################

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("openfoodfacts_batch")


################################################
# Prepare Snowflake connection and private key #
################################################

env = os.getenv("ENVIRONMENT", "dev").lower()

if env == "dev":
    SNOWFLAKE_PRIVATE_KEY = "SNOWFLAKE_KEY_D"
    SNOWFLAKE_KEY_PATH = "SNOWFLAKE_KEY_PATH_D"
    SNOWFLAKE_PRIVATE_KEY_PASSPHRASE = "SNOWFLAKE_KEY_PASSPHRASE_D"
    
def load_private_key_der() -> bytes:
    """
    Loads Snowflake RSA private key (encrypted or not)
    and returns DER bytes required by snowflake-connector.
    """

    passphrase = os.getenv(f"{SNOWFLAKE_PRIVATE_KEY_PASSPHRASE}")

    # CASE 1: GitLab CI → key is in env var
    if os.getenv(f"{SNOWFLAKE_PRIVATE_KEY}"):
        logger.debug("Loading Snowflake private key from environment variable")
        pem_data = os.environ[f"{SNOWFLAKE_PRIVATE_KEY}"].encode()

    # CASE 2: Local → key is in file
    elif os.getenv(f"{SNOWFLAKE_KEY_PATH}"):
        logger.debug("Loading Snowflake private key from file: %s", os.environ[f"{SNOWFLAKE_KEY_PATH}"])
        with open(os.environ[f"{SNOWFLAKE_KEY_PATH}"], "rb") as f:
            pem_data = f.read()

    else:
        raise RuntimeError("Missing Snowflake private key configuration")

    # Load key (WITH passphrase support)
    private_key = serialization.load_pem_private_key(
        pem_data,
        password=passphrase.encode() if passphrase else None,
    )

    # Convert to DER (required by Snowflake connector)
    return private_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


################################################
#             API functions                 #
################################################


HEADERS = {"User-Agent": "ZackFoodDataFrance/1.0 (zakariahaddouche5@gmail.com)"}
DELTA_INDEX_URL = "https://static.openfoodfacts.org/data/delta/index.txt"
DELTA_BASE_URL = "https://static.openfoodfacts.org/data/delta/"

# TRo Reuse a single session for connection pooling across all requests
SESSION = requests.Session()
SESSION.headers.update(HEADERS)

# We set the max number of retries befor giving up on a request
MAX_RETRIES = 5
# We need to set backoff factor for exponential backoff between retries
BACKOFF_FACTOR = 2
# we need a delay between successive downloads to avoid tripping rate limits
DOWNLOAD_DELAY_SECONDS = 1

#returns a requests.Response object with retry logic ! to be reused for all requests to OpenFoodFacts API
def _request_with_retry(method: str, url: str, **kwargs) -> requests.Response:
    """
    Perform an HTTP request with retry + exponential backoff.
    Respects the Retry-After header on 429 responses.
    """
    last_error = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = SESSION.request(method, url, timeout=kwargs.pop("timeout", 30), **kwargs)

            if resp.status_code == 429:
                wait = int(resp.headers.get("Retry-After", BACKOFF_FACTOR ** attempt))
                logger.warning(
                    "429 Too Many Requests for %s (attempt %d/%d). Waiting %ds before retry.",
                    url, attempt, MAX_RETRIES, wait,
                )
                time.sleep(wait)
                continue

            resp.raise_for_status()
            return resp

        except requests.exceptions.RequestException as exc:
            last_error = exc
            wait = BACKOFF_FACTOR ** attempt
            logger.error(
                "Request error for %s (attempt %d/%d): %s. Retrying in %.1fs.",
                url, attempt, MAX_RETRIES, exc, wait,
            )
            time.sleep(wait)

    raise RuntimeError(f"Failed to fetch {url} after {MAX_RETRIES} attempts") from last_error

# List available delta files from OpenFoodFacts with retry logic
def list_available_deltas() -> list[str]:
    logger.info("Fetching list of available delta files")
    resp = _request_with_retry("GET", DELTA_INDEX_URL)
    files = resp.text.strip().split("\n")
    logger.debug("%d delta file(s) listed upstream", len(files))
    return files

# function to download a delta file into memory with retry logic
def download_delta_to_buffer(filename: str) -> BytesIO:
    """Stream the delta file fully into memory, with retry on failure."""
    url = DELTA_BASE_URL + filename
    last_error = None

    for attempt in range(1, MAX_RETRIES + 1):
        buf = BytesIO()
        try:
            with SESSION.get(url, stream=True, timeout=60) as resp:
                if resp.status_code == 429:
                    # Respect Retry-After (provided by the server) header if present, otherwise use exponential backoff
                    wait = int(resp.headers.get("Retry-After", BACKOFF_FACTOR ** attempt))
                    logger.warning(
                        "429 Too Many Requests downloading %s (attempt %d/%d). Waiting %ds.",
                        filename, attempt, MAX_RETRIES, wait,
                    )
                    time.sleep(wait)
                    continue

                resp.raise_for_status()
                for chunk in resp.iter_content(chunk_size=1024 * 1024):  # 1MB chunks
                    buf.write(chunk)

            buf.seek(0)  # rewind before reading, otherwise the buffer is at EOF
            logger.info("Downloaded %s (%d bytes)", filename, buf.getbuffer().nbytes)
            return buf

        except requests.exceptions.RequestException as exc:
            last_error = exc
            buf.close()
            wait = BACKOFF_FACTOR ** attempt
            logger.error(
                "Download error for %s (attempt %d/%d): %s. Retrying in %.1fs.",
                filename, attempt, MAX_RETRIES, exc, wait,
            )
            time.sleep(wait)

    raise RuntimeError(f"Failed to download {filename} after {MAX_RETRIES} attempts") from last_error


################################################
#             Snowflake helpers                #
################################################


def list_files_in_stage(cursor, database: str, schema: str, stage: str, folder: str = "") -> list[str]:
    """List files in a Snowflake internal stage."""
    cursor.execute(f"""LIST @{database}.{schema}.{stage}/{folder}
                ->> SELECT SPLIT_PART("name", '/', -1) FROM $1 WHERE "name" ILIKE '%{folder}%'  """)
    return [row[0] for row in cursor.fetchall()]

def put_buffer_to_stage(cursor, database: str, schema: str, buf: BytesIO, filename: str, stage: str, folder: str = ""):
    """Upload an in-memory buffer directly to a Snowflake internal stage."""
    cursor.execute(
        f"PUT file://unused/{filename} @{database}.{schema}.{stage}/{folder} AUTO_COMPRESS=FALSE PARALLEL=4",
        file_stream=buf,
    )


################################################
#                 Main batch                   #
################################################

def run_daily_batch():


    parser = argparse.ArgumentParser(description="Run daily batch to download OpenFoodFacts delta files and upload to Snowflake stage.")
    parser.add_argument("--user")
    parser.add_argument("--account")
    parser.add_argument("--warehouse")
    parser.add_argument("--role")
    parser.add_argument("--database")
    parser.add_argument("--schema")
    parser.add_argument("--stage")
    parser.add_argument("--folder")
    args = parser.parse_args()


######## Retrieve default settings if any ######


    config_file = Path("py_snowflake_defeault_configs.json")
    if config_file.exists():
        with open("py_snowflake_defeault_configs.json", "rb") as f:
            configs = json.load(f)
    else:
        configs = {}


######## Final configs : args or default args ######

    final_configs = {
        "user": args.user or configs.get("user"),
        "account": args.account or configs.get("account"),
        "warehouse": args.warehouse or configs.get("warehouse"),
        "role": args.role or configs.get("role"),
        "database": args.database or configs.get("database"),
        "schema": args.schema or configs.get("schema"),
        "stage": args.stage or configs.get("stage"),
        "folder": args.folder or configs.get("folder"),
    }


######## Check if all required arguments are provided ######

    required_args = ["user", "account", "warehouse", "role", "database", "schema", "stage", "folder"]
    missing_args = [arg for arg in required_args if not final_configs.get(arg)]
    if missing_args:
        raise ValueError(
            f"Missing required arguments: {', '.join(missing_args)} : "
            "Please provide them via command line or in py_snowflake_defeault_configs.json"
        )
    

######## Connect to Snowflake ######

    logger.info("Connecting to Snowflake as %s on account %s using role %s and warehouse %s", final_configs["user"], final_configs["account"], final_configs["role"], final_configs["warehouse"])
    conn = snowflake.connector.connect(
        user=final_configs["user"],
        account=final_configs["account"],
        role=final_configs["role"],
        warehouse=final_configs["warehouse"],
        private_key = load_private_key_der()
    )

    try:
        cursor = conn.cursor()

    ######## set the list of files to process ######

        deltas = set(list_available_deltas())
        files_in_stage = set(
            list_files_in_stage(
                cursor, final_configs["database"], final_configs["schema"],
                final_configs["stage"], final_configs["folder"],
            )
        )
        files_to_download = sorted(deltas - files_in_stage)
        logger.info(
            "%d delta file(s) upstream, %d already in stage, %d to process",
            len(deltas), len(files_in_stage), len(files_to_download),
        )

        if not files_to_download:
            logger.info("Nothing new to download. Exiting.")
            return
        
    ######## download files and upload to stage ######

        for i, filename in enumerate(files_to_download, start=1):
            logger.info("Processing file %d/%d: %s", i, len(files_to_download), filename)
            try:
                buf = download_delta_to_buffer(filename)
                try:
                    put_buffer_to_stage(
                        cursor, final_configs["database"], final_configs["schema"],
                        buf, filename, final_configs["stage"], final_configs["folder"],
                    )
                finally:
                    buf.close()  # free memory immediately
            except Exception:
                logger.exception("Failed to process %s. Skipping to next file.", filename)
                continue

            # relief the upstream API between downloads
            if i < len(files_to_download):
                time.sleep(DOWNLOAD_DELAY_SECONDS)

    ######## close snowflake connection ######


    finally:
        cursor.close()
        conn.close()
        logger.info("Snowflake connection closed.")


if __name__ == "__main__":
    run_daily_batch()