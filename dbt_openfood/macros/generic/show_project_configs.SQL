{# macros/run_start_fancy_overview.sql #}

{% macro _env_first(keys) -%}
  {# Return first non empty env var among keys #}
  {%- for k in keys -%}
    {%- set v = env_var(k, "") -%}
    {%- if v is string and v|length > 0 -%}
      {{- return(v) -}}
    {%- endif -%}
  {%- endfor -%}
  {{ return(none) }}
{%- endmacro %}

{% macro show_project_configs() %}
  {% if not execute %}
    {{ return("skipped at parse time") }}
  {% endif %}

  {# Collect local environment (read only) #}
  {% set local_user     = _env_first(["LOCAL_USER","USER","USERNAME","LOGNAME"]) %}
  {% set local_hostname = _env_first(["LOCAL_HOSTNAME","HOSTNAME","COMPUTERNAME"]) %}
  {% set local_ip_env   = env_var("LOCAL_IP", "") %}
  {% set dev_machine    = env_var("DEV_MACHINE", "") %}
  {% set dev_os         = _env_first(["DEV_OS","OS"]) %}
  {% set dev_cpu        = _env_first(["DEV_CPU","PROCESSOR_IDENTIFIER","PROCESSOR_ARCHITECTURE"]) %}
  {% set git_branch     = env_var("GIT_BRANCH", "") %}
  {% set ci_flag        = env_var("CI", "") %}

  {# dbt and target context #}
  {% set ctx_dbt = {
    "dbt_version": dbt_version,
    "project_name": project_name,
    "target_name": target.name,
    "target_database": target.database,
    "target_schema": target.schema,
    "invocation_id": invocation_id,
    "run_started_at": run_started_at.astimezone(modules.pytz.utc).isoformat(),
    "threads": target.threads
  } %}

  {# Project meta from config #}
  {% set project_meta = config.get("meta", default={}) %}
  {% set wanted_meta_keys = ["country","cost_center","domain","owner","entity","environment","project","custom"] %}

  {# Snowflake session query (single request) #}
  {% set _sf_tbl = run_query("
    select
      to_varchar(current_ip_address())   as client_ip,
      to_varchar(current_client())       as client,
      to_varchar(current_version())      as snowflake_version,
      to_varchar(current_user())         as snowflake_user,
      to_varchar(current_role())         as snowflake_role,
      to_varchar(current_warehouse())    as snowflake_warehouse,
      to_varchar(current_database())     as snowflake_database,
      to_varchar(current_schema())       as snowflake_schema,
      to_varchar(current_account())      as snowflake_account,
      to_varchar(current_region())       as snowflake_region
  ") %}

  {% set sf = {} %}
  {% if _sf_tbl and _sf_tbl.columns and _sf_tbl.columns[0].values()|length > 0 %}
    {% set sf = sf.update({"client_ip":           _sf_tbl.columns[0].values()[0]}) or sf %}
    {% set sf = sf.update({"client":              _sf_tbl.columns[1].values()[0]}) or sf %}
    {% set sf = sf.update({"snowflake_version":   _sf_tbl.columns[2].values()[0]}) or sf %}
    {% set sf = sf.update({"snowflake_user":      _sf_tbl.columns[3].values()[0]}) or sf %}
    {% set sf = sf.update({"snowflake_role":      _sf_tbl.columns[4].values()[0]}) or sf %}
    {% set sf = sf.update({"snowflake_warehouse": _sf_tbl.columns[5].values()[0]}) or sf %}
    {% set sf = sf.update({"snowflake_database":  _sf_tbl.columns[6].values()[0]}) or sf %}
    {% set sf = sf.update({"snowflake_schema":    _sf_tbl.columns[7].values()[0]}) or sf %}
    {% set sf = sf.update({"snowflake_account":   _sf_tbl.columns[8].values()[0]}) or sf %}
    {% set sf = sf.update({"snowflake_region":    _sf_tbl.columns[9].values()[0]}) or sf %}
  {% endif %}

  {# Merge overall context #}
  {% set ctx_env = {} %}
  {% if local_user %}{% set ctx_env = ctx_env.update({"local_user": local_user}) or ctx_env %}{% endif %}
  {% if local_hostname %}{% set ctx_env = ctx_env.update({"local_hostname": local_hostname}) or ctx_env %}{% endif %}
  {% if local_ip_env %}{% set ctx_env = ctx_env.update({"local_ip_env": local_ip_env}) or ctx_env %}{% endif %}
  {% if dev_machine %}{% set ctx_env = ctx_env.update({"dev_machine": dev_machine}) or ctx_env %}{% endif %}
  {% if dev_os %}{% set ctx_env = ctx_env.update({"dev_os": dev_os}) or ctx_env %}{% endif %}
  {% if dev_cpu %}{% set ctx_env = ctx_env.update({"dev_cpu": dev_cpu}) or ctx_env %}{% endif %}
  {% if git_branch %}{% set ctx_env = ctx_env.update({"git_branch": git_branch}) or ctx_env %}{% endif %}
  {% if ci_flag %}{% set ctx_env = ctx_env.update({"ci": ci_flag}) or ctx_env %}{% endif %}

  {% set overview = ctx_dbt.update(ctx_env) or ctx_dbt %}
  {% set overview = overview.update(sf) or overview %}

  {# Include project meta in overview #}
  {% if project_meta %}
    {% set overview = overview.update({"meta": project_meta}) or overview %}
  {% endif %}

  {# Logs #}
  {% do log("----------------------------------------", info=True) %}
  {% do log("🚀 Run Start - Global Context", info=True) %}
  {% do log("----------------------------------------", info=True) %}

  {% do log("🧩 dbt", info=True) %}
  {% do log("  - project_name     : " ~ (ctx_dbt["project_name"] or "∅"), info=True) %}
  {% do log("  - dbt_version      : " ~ (ctx_dbt["dbt_version"] or "∅"), info=True) %}
  {% do log("  - target           : " ~ (ctx_dbt["target_name"] or "∅"), info=True) %}
  {% do log("  - target_database  : " ~ (ctx_dbt["target_database"] or "∅"), info=True) %}
  {% do log("  - target_schema    : " ~ (ctx_dbt["target_schema"] or "∅"), info=True) %}
  {% do log("  - invocation_id    : " ~ (ctx_dbt["invocation_id"] or "∅"), info=True) %}
  {% do log("  - run_started_at   : " ~ (ctx_dbt["run_started_at"] or "∅"), info=True) %}
  {% do log("  - project_configs  : " ~ (ctx_dbt["project_configs"] or "∅"), info=True) %}
  {% do log("  - threads          : " ~ (ctx_dbt["threads"] or "∅"), info=True) %}

  {% do log("🖥️ Local environment", info=True) %}
  {% do log("  - local_user       : " ~ (local_user or "∅"), info=True) %}
  {% do log("  - local_hostname   : " ~ (local_hostname or "∅"), info=True) %}
  {% do log("  - local_ip_env     : " ~ (local_ip_env or "∅"), info=True) %}
  {% do log("  - dev_machine      : " ~ (dev_machine or "∅"), info=True) %}
  {% do log("  - dev_os           : " ~ (dev_os or "∅"), info=True) %}
  {% do log("  - dev_cpu          : " ~ (dev_cpu or "∅"), info=True) %}
  {% do log("  - git_branch       : " ~ (git_branch or "∅"), info=True) %}
  {% do log("  - ci               : " ~ (ci_flag or "∅"), info=True) %}

  {% do log("❄️ Snowflake session", info=True) %}
  {% do log("  - account          : " ~ (sf.get("snowflake_account") or "∅"), info=True) %}
  {% do log("  - region           : " ~ (sf.get("snowflake_region") or "∅"), info=True) %}
  {% do log("  - user             : " ~ (sf.get("snowflake_user") or "∅"), info=True) %}
  {% do log("  - role             : " ~ (sf.get("snowflake_role") or "∅"), info=True) %}
  {% do log("  - warehouse        : " ~ (sf.get("snowflake_warehouse") or "∅"), info=True) %}
  {% do log("  - database         : " ~ (sf.get("snowflake_database") or "∅"), info=True) %}
  {% do log("  - schema           : " ~ (sf.get("snowflake_schema") or "∅"), info=True) %}
  {% do log("  - client           : " ~ (sf.get("client") or "∅"), info=True) %}
  {% do log("  - version          : " ~ (sf.get("snowflake_version") or "∅"), info=True) %}
  {% do log("  - client_ip        : " ~ (sf.get("client_ip") or "∅"), info=True) %}

  {% if project_meta %}
    {% do log("📦 Project meta", info=True) %}
    {% for k in wanted_meta_keys %}
      {% set v = project_meta.get(k) %}
      {% if v is mapping %}
        {% for subk, subv in v.items() %}
          {% do log("  - " ~ k ~ "." ~ subk ~ " : " ~ (subv|string), info=True) %}
        {% endfor %}
      {% elif v is not none %}
        {% do log("  - " ~ k ~ " : " ~ (v|string), info=True) %}
      {% endif %}
    {% endfor %}
  {% endif %}

  {% do log("----------------------------------------", info=True) %}

  {{ return("") }}
{% endmacro %}
