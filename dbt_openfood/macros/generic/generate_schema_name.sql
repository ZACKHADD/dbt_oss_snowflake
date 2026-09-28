{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- if target.name == 'dev_sandbox' -%}
        {%- set base = env_var('DBT_DEVELOPER_NAME') -%}
        {%- if custom_schema_name is none -%}
            {{ target.schema}}
        {%- else -%}
            {{ base ~ '_' ~ (custom_schema_name | trim) }}
        {%- endif -%}
    {%- else -%}
        {%- set default_schema = target.schema -%}
        {%- if custom_schema_name is none -%}
            {{ default_schema }}
        {%- else -%}
            {{ custom_schema_name | trim }}
        {%- endif -%}
    {%- endif -%}

{%- endmacro %}