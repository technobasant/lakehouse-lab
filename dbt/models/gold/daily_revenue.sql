{{ config(materialized = 'table', table_type = 'iceberg') }}

-- Gold: the shape a dashboard actually queries. Small, wide, and derived
-- entirely from silver — no source table is referenced here on purpose, so the
-- lineage graph has no shortcuts in it.

select
    orderdate,
    priority_label,
    count(*)                                   as orders,
    sum(totalprice)                            as revenue,
    avg(totalprice)                            as avg_order_value,
    count(distinct custkey)                    as customers
from {{ ref('orders_enriched') }}
group by orderdate, priority_label
