FROM python:3.12-slim
# git is not decoration: dbt shells out to it for package installs and to stamp
# the run manifest, and `dbt debug` fails a check without it.
RUN apt-get update && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*
# dbt-trino pins its own dbt-core; let pip resolve rather than pinning both and
# fighting it.
RUN pip install --no-cache-dir "dbt-trino==1.10.3"
WORKDIR /dbt
ENTRYPOINT ["dbt"]
