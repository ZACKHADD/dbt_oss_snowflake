{%- macro drop_objects(objects) -%}
  {%- for o in objects -%}
    {%- set rel = api.Relation.create(
        database=o.get('database', target.database),
        schema=o.get('schema', target.schema),
        identifier=o['identifier'],
        type=o.get('type', 'table')
    ) -%}
    {%- do adapter.drop_relation(rel) -%}
    {{ log('dropped ' ~ rel, info=True) }}
  {%- endfor -%}
{%- endmacro -%}