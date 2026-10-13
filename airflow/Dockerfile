FROM apache/airflow:3.3.1-python3.12

# dbt lives in the scheduler image rather than behind a DockerOperator. The
# alternative means mounting the host docker socket into Airflow, which is a
# real privilege escalation for the sake of avoiding one pip install.
#
# The Trino provider gives the connection type and the SQL operators; dbt-trino
# is the same version the standalone dbt container uses, so a DAG run and a
# manual `dbt run` cannot drift.
USER airflow
RUN pip install --no-cache-dir \
      "dbt-trino==1.10.3" \
      "apache-airflow-providers-trino==6.3.0"
