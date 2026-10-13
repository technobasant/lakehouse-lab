# Measured results

Every figure below came off this lab on 2026-08-16, on an Apple M-series laptop
with Docker Desktop allocated 8 CPUs and 11.67 GB. They are honest ceilings for
a laptop, not benchmarks to quote at anyone.

Query timings are **server-side**, read from `system.runtime.queries`
(`date_diff('millisecond', created, "end")`), median of 5–7 runs after 2 warm-ups.
Wall-clock timing through the Trino CLI was discarded: `docker compose exec` plus
the CLI's own JVM startup added ~515 ms to every measurement, which is 6× the
figure being measured.

## Versions

| component | version |
|---|---|
| Trino | 483 |
| Apache Polaris | 1.7.0 |
| MinIO | RELEASE.2025-09-07T16-13-09Z |
| PostgreSQL (Polaris + Airflow metadata) | 18.1 |
| dbt-core / dbt-trino | 1.12.2 / 1.10.3 |
| Apache Airflow | 3.3.1 |

All images publish a native arm64 manifest. Nothing runs under emulation.

## Ingest

| what | figure | method |
|---|---|---|
| bronze.orders created | 1,500,000 rows in 5.4 s | `CREATE TABLE ... AS SELECT` from `tpch.sf1`, partitioned by `month(orderdate)` |
| resulting object layout | 80 Parquet + 2 Avro + 1 Puffin `.stats` + 1 `metadata.json`, 16 MiB | `mc ls --recursive` on the MinIO bucket |

## Query: Iceberg on MinIO vs the in-memory tpch generator

`tpch` is a generator, not a storage format, and never touches the network. It
is a floor, not a fair "before" — whatever Iceberg costs above it is the cost of
object storage, Parquet decoding and manifest planning.

| query | tpch | Iceberg | ratio |
|---|---|---|---|
| scan + aggregate over 1.5M rows | 238 ms | 183 ms | 1.3× |
| one-month partition predicate | 615 ms | 88 ms | 7.0× |
| non-partition predicate (`totalprice > 400000`) | 595 ms | 202 ms | 2.9× |

## dbt: the silently-dropped partition spec

Same model, same 1.5M rows, same predicate.

| table | data files | partitions | median query |
|---|---|---|---|
| `partitioning` at config level (ignored) | 2 | 0 | 131 ms |
| `properties = {"partitioning": ...}` | 80 | 80 | 99 ms |

## Incremental MERGE

| snapshot | operation | added files | added rows | total files |
|---|---|---|---|---|
| 1 | append | 80 | 1,500,000 | 80 |
| 2 | append | 1 | 25,000 | 81 |

dbt reported `MERGE (25_000 rows) in 2.66s`. The run touched 1 file of 81 —
not a rewrite. Note the operation is `append`, not `overwrite`: every incoming
key was new, so Iceberg degraded the MERGE to an append. A MERGE that actually
matches existing keys would show `deleted-data-files`.

## Compaction

Twenty 5,000-row inserts into a single partition, then `ALTER TABLE ... EXECUTE optimize`.

| | before | after |
|---|---|---|
| data files in partition | 20 | 1 |
| total bytes | 1,006 KB | 430 KB |
| average file | 50 KB | 430 KB |
| median query on that partition | 184 ms | 69 ms |

Compaction took 1.4 s. The 57% byte reduction is Parquet compressing better with
more rows per row-group — it is not just a file-count change.

`optimize` only merges files **within** a partition. Run on a table with 82
partitions holding one file each, it correctly does nothing, which looks like a
failure and is not.

## Time travel and rollback

| step | rows |
|---|---|
| before the accident | 1,645,000 |
| after `DELETE ... WHERE orderdate < DATE '1996-01-01'` | 735,032 |
| `FOR VERSION AS OF <snapshot>` | 1,645,000 |
| after `EXECUTE rollback_to_snapshot(<snapshot>)` | 1,645,000 |

**909,968 rows recovered in 589 ms.** No data moved: a rollback rewrites the
current-snapshot pointer, which is why it is three orders of magnitude faster
than the equivalent pgBackRest PITR in the Patroni lab.

## Expiry destroys the safety net

| step | result |
|---|---|
| snapshot A readable while in history | 1,645,000 rows |
| after `expire_snapshots(retention_threshold => '0s')` | `Iceberg snapshot ID does not exists` |

Snapshot count went 25 → 1. The retention threshold **is** the recovery window.
Trino guards this with a 7-day floor (`iceberg.expire-snapshots.min-retention`);
overriding it needs a session property namespaced by **catalog** name, not the
connector name the error message prints.

## Second engine: StarRocks on the same catalog

StarRocks 4.1.4 attached to the same Polaris REST catalog. No export, no copy, no
re-registration — it saw `bronze`, `silver` and `gold` immediately, including the
`silver_silver` / `silver_gold` debris left by the dbt schema-naming bug.

| | rows |
|---|---|
| Trino sees `silver.orders_enriched` | 1,645,100 |
| StarRocks sees the same table | 1,645,100 |

Same query, same data, both measured server-side (Trino from
`system.runtime.queries`, StarRocks from `fe.audit.log` `Time=`):

| engine | server-side median |
|---|---|
| Trino 483 | 99 ms |
| StarRocks 4.1.4 | **34 ms** |

Caveat worth stating: this is one small aggregate over a single partition, which
is the shape StarRocks' vectorised MPP engine is built for. It says nothing
about federation across catalogs or large multi-table joins, which is where
Trino is chosen.

**Credential vending works on both.** A StarRocks catalog defined with
`iceberg.catalog.vended-credentials-enabled = 'true'` and **no** `aws.s3.access_key`
read the table successfully. The authorisation boundary from part one is engine
independent, which is the actual argument for a REST catalog over a metastore.

Client-side wall clock was discarded again. Subtracting a `SELECT 1` baseline
gave Trino a *negative* query time, because JVM startup varies by more than the
query costs.
