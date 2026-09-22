import requests
import json
import os
import pandas as pd
from datetime import datetime, timedelta


TOKEN_URL = "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token"
TOKEN_REFRESH_MARGIN = 30  # seconds

class TokenManager:
    def __init__(self, client_id: str, client_secret: str):
        self.client_id = client_id
        self.client_secret = client_secret
        self.token = None
        self.expires_at = None

    def get_token(self):
        if self.token and self.expires_at and datetime.now() < self.expires_at:
            return self.token
        return self._refresh()

    def _refresh(self):
        r = requests.post(
            TOKEN_URL,
            data={
                "grant_type": "client_credentials",
                "client_id": self.client_id,
                "client_secret": self.client_secret,
            },
        )
        r.raise_for_status()
        data = r.json()
        self.token = data["access_token"]
        expires_in = data.get("expires_in", 1800)
        self.expires_at = datetime.now() + timedelta(seconds=expires_in - TOKEN_REFRESH_MARGIN)
        return self.token

    def headers(self):
        return {"Authorization": f"Bearer {self.get_token()}"}
    

CLIENT_ID = os.getenv("Osky_ClientId")
CLIENT_SECRET = os.getenv("Osky_ClientSecret")

token_manager = TokenManager(CLIENT_ID, CLIENT_SECRET)

resp = requests.get(
    "https://opensky-network.org/api/states/all",
    headers=token_manager.headers(),
)

print(len(resp["states"].json()))