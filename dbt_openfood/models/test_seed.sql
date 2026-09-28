{{
    config (
            {
            "materialized": 'table',
            "schema": 'OPENFOOD_API'
            }
        )
}}


SELECT * FROM {{source('openfood_sources', 'raw_customers')}}