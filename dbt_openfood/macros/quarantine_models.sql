{%- macro quarantine_models(models) -%}
  {%- for m in models -%}
    {%- set parts = m.strip().split('.') -%}
    {%- set identifier = parts | last -%}
    {%- set schema = parts[-2] if parts | length >= 2 else target.schema -%}
    {%- set database = parts[-3] if parts | length >= 3 else target.database -%}
    {%- set rel = api.Relation.create(database=database, schema=schema, identifier=identifier, type='table') -%}
    {%- do adapter.drop_relation(rel) -%}
    {{ log('quarantined ' ~ rel, info=True) }}
  {%- endfor -%}
{%- endmacro -%}