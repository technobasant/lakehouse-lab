-- How the published query timings were read: server-side, from Trino's own
-- query log, not wall clock around the CLI (which adds ~515 ms of
-- `docker compose exec` and JVM startup to every run). Take the median of the
-- runs after two warm-ups.
SELECT substr(query, 1, 80) AS query,
       date_diff('millisecond', created, "end") AS ms
FROM system.runtime.queries
WHERE state = 'FINISHED'
ORDER BY created DESC
LIMIT 30;
