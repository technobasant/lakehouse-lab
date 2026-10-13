{#
    Partitioning goes in `properties`, as a literal Trino SQL fragment.

    A bare `partitioning = ["month(orderdate)"]` at config level is accepted
    silently by dbt, warned about by nothing, and produces an UNPARTITIONED
    table. `SHOW CREATE TABLE` is the only thing that tells you, and the cost is
    not theoretical: the same one-month predicate took 131 ms unpartitioned
    against 88 ms on the partitioned bronze table holding the same rows.

    Also note this is a Jinja expression, so `--` comments inside `config()`
    are a compilation error, not a comment.
#}
{{
  config(
    materialized         = 'incremental',
    incremental_strategy = 'merge',
    unique_key           = 'orderkey',
    table_type           = 'iceberg',
    properties           = {
      "partitioning": "ARRAY['month(orderdate)']"
    }
  )
}}

-- Silver: one row per order, customer attributes resolved, priority parsed out
-- of TPC-H's "1-URGENT" encoding.
--
-- `merge` is the point of this model. Iceberg supports row-level MERGE, so an
-- incremental run rewrites only the affected data files and appends a snapshot,
-- rather than replacing the table. The snapshot count in `$snapshots` after a
-- second run is the evidence for that, and it is the number worth checking.

select
    o.orderkey,
    o.custkey,
    c.name                                        as customer_name,
    c.nationkey,
    o.orderstatus,
    o.totalprice,
    o.orderdate,
    cast(split_part(o.orderpriority, '-', 1) as integer) as priority_rank,
    split_part(o.orderpriority, '-', 2)           as priority_label,
    o.clerk
from {{ source('bronze', 'orders') }}      o
join {{ source('bronze', 'customers') }}   c on c.custkey = o.custkey

{% if is_incremental() %}
  -- Only orders newer than what we already hold. On the first run the table
  -- does not exist and this branch is skipped entirely.
  where o.orderdate > (select coalesce(max(orderdate), date '1990-01-01') from {{ this }})
{% endif %}
