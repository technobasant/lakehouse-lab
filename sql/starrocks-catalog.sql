-- Attach StarRocks to the same Polaris catalog Trino writes through (part four).
--
--   docker compose --profile engines up -d starrocks
--   docker compose exec -T starrocks mysql -h127.0.0.1 -P9030 -uroot < sql/starrocks-catalog.sql
--
-- Note what is absent: no aws.s3.access_key. Polaris vends a scoped credential
-- to StarRocks exactly as it does to Trino.

CREATE EXTERNAL CATALOG lakehouse PROPERTIES (
  'type' = 'iceberg',
  'iceberg.catalog.type' = 'rest',
  'iceberg.catalog.uri' = 'http://polaris:8181/api/catalog',
  'iceberg.catalog.warehouse' = 'lakehouse',
  'iceberg.catalog.security' = 'oauth2',
  'iceberg.catalog.oauth2.credential' = 'root:s3cr3t-dev-only',
  'iceberg.catalog.oauth2.scope' = 'PRINCIPAL_ROLE:ALL',
  'iceberg.catalog.vended-credentials-enabled' = 'true',
  'aws.s3.endpoint' = 'http://minio:9000',
  'aws.s3.enable_path_style_access' = 'true'
);

SHOW DATABASES FROM lakehouse;
