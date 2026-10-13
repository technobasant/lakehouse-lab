-- Bronze: land TPC-H scale factor 1 into Iceberg, through Polaris.
--
--   docker compose exec -T trino-coordinator trino < sql/01-bronze.sql
--
-- `orders` is the statement from part one, partitioned by month so the
-- one-month predicate can prune. `customers` follows the same pattern
-- unpartitioned; the silver model joins it and verify-scoping.sh uses it as
-- the sibling table the vended credential must NOT reach.

CREATE SCHEMA IF NOT EXISTS lakehouse.bronze;

CREATE TABLE IF NOT EXISTS lakehouse.bronze.orders
WITH (partitioning = ARRAY['month(orderdate)']) AS
SELECT orderkey, custkey, orderstatus, totalprice, orderdate, orderpriority, clerk
FROM tpch.sf1.orders;

CREATE TABLE IF NOT EXISTS lakehouse.bronze.customers AS
SELECT custkey, name, nationkey, mktsegment, acctbal
FROM tpch.sf1.customer;
