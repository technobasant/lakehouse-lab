#!/usr/bin/env bash
# =============================================================================
# Time the same query against the same data in two places: Iceberg-on-MinIO,
# and Trino's built-in tpch connector, which generates rows in memory.
#
# tpch is not a fair "before" — it is a generator, not a storage format, and it
# never touches the network. It is here as a floor: whatever Iceberg costs above
# this number is the cost of object storage, Parquet decoding, and manifest
# planning. That framing matters more than the raw figures, which come off a
# single host and should not be quoted at anyone.
#
# Each query runs $WARMUP times to let the JIT settle, then $RUNS times timed.
# The reported figure is the median, not the mean: one GC pause in a five-run
# sample moves a mean and does not move a median.
# =============================================================================
set -euo pipefail

RUNS="${RUNS:-5}"
WARMUP="${WARMUP:-2}"
TRINO="docker compose exec -T trino-coordinator trino --server localhost:8080"

q() { # name  sql-with-{SRC}-placeholder
  local name="$1" sql="$2"
  for src_label in "tpch.sf1" "lakehouse.bronze"; do
    local stmt="${sql//\{SRC\}/$src_label}"
    for _ in $(seq 1 "$WARMUP"); do $TRINO --execute "$stmt" >/dev/null 2>&1 || true; done
    local times=()
    for _ in $(seq 1 "$RUNS"); do
      local start end
      start=$(python3 -c 'import time;print(int(time.time()*1000))')
      $TRINO --execute "$stmt" >/dev/null 2>&1
      end=$(python3 -c 'import time;print(int(time.time()*1000))')
      times+=( $(( end - start )) )
    done
    local median
    median=$(printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1} END {print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}')
    printf '  %-26s %-16s median %6s ms   runs: %s\n' "$name" "$src_label" "$median" "${times[*]}"
  done
}

echo "trino: $($TRINO --execute 'SELECT version()' 2>/dev/null | tr -d '"')  |  runs=$RUNS warmup=$WARMUP"
echo

# q01-shaped: full scan, group + aggregate. Iceberg has to read every file.
q "scan+aggregate (q01)" \
  "SELECT orderstatus, count(*), sum(totalprice) FROM {SRC}.orders GROUP BY orderstatus"

# Partition pruning. orders is partitioned by month(orderdate), so Iceberg
# should touch a single manifest entry while tpch generates the lot.
q "partition prune (1 month)" \
  "SELECT count(*), sum(totalprice) FROM {SRC}.orders WHERE orderdate >= DATE '1995-03-01' AND orderdate < DATE '1995-04-01'"

# Selective predicate on a non-partition column — this is where Parquet
# row-group statistics earn their keep, or fail to.
q "non-partition predicate" \
  "SELECT count(*) FROM {SRC}.orders WHERE totalprice > 400000"
