{%- macro cleanup_developer_schemas(database, min_age_days=14) -%}
  {%- set days = min_age_days | as_number -%}
  {%- set q -%}
    select schema_name
    from {{ database }}.information_schema.schemata
    where upper(schema_name) like 'ANALYTICS\_%' escape '\'
      and last_altered < dateadd(day, -{{ days }}, current_timestamp())
  {%- endset -%}
  {%- set results = run_query(q) -%}
  {%- set dropped = [] -%}
  {%- for r in results -%}
    {%- set s = r[0] -%}
    {%- do run_query('drop schema if exists ' ~ database ~ '.' ~ s ~ ' cascade') -%}
    {%- do dropped.append(s) -%}
  {%- endfor -%}
  {{ log('cleanup_developer_schemas dropped ' ~ (dropped | join(', ') | default('(none)')) ~ ' from ' ~ database, info=True) }}
{%- endmacro -%}