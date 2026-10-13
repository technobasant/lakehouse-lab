"""End-to-end lakehouse pipeline: land, transform, maintain.

The shape is deliberate. Most lakehouse demos stop at "transform", which is the
half that is fun. The half that decides whether the thing survives six months is
the third task: Iceberg accumulates a data file per write and a snapshot per
commit, and a table nobody compacts gets slower every single run.

Three tasks, each doing one thing:

    land      append a day of orders to bronze, as an ingest would
    transform dbt build — silver by MERGE, gold rebuilt from silver
    maintain  optimize (compact), then expire old snapshots

`maintain` runs on every pass here because the lab needs to show its effect
quickly. In production it belongs on its own schedule — compaction rewrites
files and competes with the pipeline for the same workers.

Nothing in this DAG holds an S3 credential. Airflow talks to Trino, Trino asks
Polaris, Polaris vends per table.
"""

from __future__ import annotations

import pendulum
from airflow.sdk import dag, task
from airflow.providers.trino.hooks.trino import TrinoHook

CATALOG = "lakehouse"


def _run(sql: str) -> None:
    """Execute one statement against Trino and discard the result."""
    TrinoHook(trino_conn_id="trino_lakehouse").run(sql)


@dag(
    dag_id="lakehouse_pipeline",
    schedule="@daily",
    start_date=pendulum.datetime(2026, 8, 1, tz="UTC"),
    catchup=False,
    max_active_runs=1,
    tags=["iceberg", "trino", "polaris"],
    doc_md=__doc__,
)
def lakehouse_pipeline():
    @task
    def land(**context) -> int:
        """Append one logical day of orders to bronze.

        Keyed off the run's timestamp so a re-run of the same interval writes
        the same keys, which is what makes the downstream MERGE meaningful
        rather than an append in disguise.

        `context["logical_date"]` is what this was, and it raises KeyError on
        Airflow 3. AIP-83 made logical date optional: a manually triggered run
        has none at all, so the key is simply absent and the task dies before it
        reaches Trino. `dag_run.run_after` is always populated; fall back to it
        and the DAG behaves identically whether it was scheduled or triggered.
        """
        run = context["dag_run"]
        stamp = getattr(run, "logical_date", None) or run.run_after
        ds = stamp.strftime("%Y-%m-%d")
        offset = int(stamp.timestamp()) % 1_000_000
        _run(
            f"""
            INSERT INTO {CATALOG}.bronze.orders
            SELECT orderkey + 100000000 + {offset}, custkey, 'O', totalprice,
                   DATE '{ds}', orderpriority, clerk
            FROM tpch.sf1.orders
            LIMIT 20000
            """
        )
        return 20000

    @task.bash(cwd="/opt/airflow/dbt")
    def transform() -> str:
        # `dbt build` rather than `dbt run`: it runs tests alongside models, so a
        # silver table that violates its own contract fails the DAG rather than
        # quietly feeding gold.
        return "dbt build --profiles-dir /opt/airflow/dbt"

    @task
    def maintain() -> dict[str, int]:
        """Compact, then expire. Order matters and the reason is not obvious.

        `optimize` writes new compacted files and leaves the originals behind,
        still referenced by older snapshots. Expiring afterwards is what
        actually releases them. Run expire first and compaction's own garbage
        stays until the next cycle.
        """
        hook = TrinoHook(trino_conn_id="trino_lakehouse")
        before = hook.get_first(
            f'SELECT count(*) FROM {CATALOG}.silver."orders_enriched$files"'
        )[0]

        _run(f"ALTER TABLE {CATALOG}.silver.orders_enriched EXECUTE optimize")
        # Keep a short window so the effect is visible in a lab. Production
        # wants this comfortably longer than the longest-running reader, or a
        # query planned against a snapshot you just expired dies mid-flight.
        _run(
            f"ALTER TABLE {CATALOG}.silver.orders_enriched "
            "EXECUTE expire_snapshots(retention_threshold => '7d')"
        )

        after = hook.get_first(
            f'SELECT count(*) FROM {CATALOG}.silver."orders_enriched$files"'
        )[0]
        return {"data_files_before": before, "data_files_after": after}

    land() >> transform() >> maintain()


lakehouse_pipeline()
