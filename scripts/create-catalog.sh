#!/usr/bin/env bash
# =============================================================================
# Create the `lakehouse` catalog in Polaris and grant Trino's principal access.
#
# Polaris is not just a metadata store — it is an authorisation boundary, and
# that is the whole reason to prefer it over Hive Metastore. Three objects have
# to line up before Trino can write a single row:
#
#   catalog        where tables live, and which S3 prefix they are confined to
#   catalog_role   a bundle of privileges ON that catalog
#   principal_role the thing a principal actually holds
#
# Grant chain: principal -> principal_role -> catalog_role -> catalog.
# Miss the last link and Trino authenticates perfectly and then cannot see a
# single namespace, which reads like a connection problem and is not one.
#
# Idempotent: every step tolerates a 409 Conflict so a re-run is a no-op.
# =============================================================================
set -euo pipefail

POLARIS_URL="${POLARIS_URL:-http://localhost:8181}"
CLIENT_ID="${CLIENT_ID:-root}"
CLIENT_SECRET="${CLIENT_SECRET:-s3cr3t-dev-only}"
CATALOG="${CATALOG:-lakehouse}"
WAREHOUSE="${WAREHOUSE:-s3://warehouse/lakehouse}"
S3_ENDPOINT="${S3_ENDPOINT:-http://minio:9000}"
# MinIO ignores the role ARN entirely — it returns an empty AssumedRoleUser.Arn —
# but the STS API shape requires one, and Polaris will not call STS without it.
ROLE_ARN="${ROLE_ARN:-arn:aws:iam::123456789012:role/polaris}"

api() { # method path [body]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -s -o /tmp/resp -w '%{http_code}' -X "$method" "$POLARIS_URL$path" \
      -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$body"
  else
    curl -s -o /tmp/resp -w '%{http_code}' -X "$method" "$POLARIS_URL$path" \
      -H "Authorization: Bearer $TOKEN"
  fi
}

step() { # description method path body
  local desc="$1"; shift
  local code; code="$(api "$@")"
  case "$code" in
    2*)  printf '  ok    %-46s %s\n' "$desc" "$code" ;;
    409) printf '  ok    %-46s %s (already exists)\n' "$desc" "$code" ;;
    *)   printf '  FAIL  %-46s %s\n' "$desc" "$code"; cat /tmp/resp; echo; exit 1 ;;
  esac
}

TOKEN="$(curl -s -X POST "$POLARIS_URL/api/catalog/v1/oauth/tokens" \
  -d grant_type=client_credentials -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" -d 'scope=PRINCIPAL_ROLE:ALL' \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
[ -n "$TOKEN" ] || { echo "could not obtain a token from $POLARIS_URL"; exit 1; }
echo "polaris: authenticated as $CLIENT_ID"

# storageType is the enum S3 — there is no S3_COMPATIBLE in 1.7.0, and sending
# one gets a bare `HTTP 400` with an empty body, which is a miserable thing to
# debug. The S3-compatible knobs are flat camelCase fields on the AWS config
# (`endpoint`, `pathStyleAccess`), not the dotted `s3.endpoint` keys used in
# Iceberg client configuration.
#
# Three flags, and the last one cost the most to find.
#
# `stsUnavailable: false` lets Polaris call STS AssumeRole so it can vend
# short-lived, prefix-scoped credentials instead of handing out standing keys.
#
# `roleArn` is optional in Polaris 1.7.0, and MinIO ignores it (the response
# comes back with an empty AssumedRoleUser.Arn). This script sets a placeholder,
# and the account id in that placeholder is what triggers the next problem.
#
# `kmsUnavailable: true` is the one that is not in any quickstart. When Polaris
# knows a region and an account id (here, from roleArn), it adds a wildcard KMS
# statement to the session policy of READ-ONLY credentials. MinIO's policy
# engine does not understand KMS ARNs and rejects the whole request:
#
#   invalid resource 'arn:aws:kms:us-east-1:123456789012:key/*'
#   (Service: Sts, Status Code: 400)
#
# The failure mode is what makes this worth writing down. CREATE TABLE AS
# SELECT asked for write credentials, which never carry that statement, so it
# *succeeded* — 1.5M rows, 84 objects in the bucket — and then every SELECT,
# which gets read-only credentials, failed with "Failed to load table".
# Leaving roleArn out would avoid it too; kmsUnavailable states the intent. Data written, data unreadable, and
# the S3 error is four layers below the message Trino prints.
step "catalog $CATALOG" POST /api/management/v1/catalogs "$(cat <<JSON
{"catalog":{"name":"$CATALOG","type":"INTERNAL",
 "properties":{"default-base-location":"$WAREHOUSE"},
 "storageConfigInfo":{"storageType":"S3",
   "allowedLocations":["$WAREHOUSE"],
   "endpoint":"$S3_ENDPOINT",
   "endpointInternal":"$S3_ENDPOINT",
   "pathStyleAccess":true,
   "stsUnavailable":false,
   "stsEndpoint":"$S3_ENDPOINT",
   "roleArn":"$ROLE_ARN",
   "kmsUnavailable":true,
   "region":"us-east-1"}}}
JSON
)"

step "catalog_role engineer" POST "/api/management/v1/catalogs/$CATALOG/catalog-roles" \
  '{"catalogRole":{"name":"engineer"}}'

step "grant CATALOG_MANAGE_CONTENT to engineer" \
  PUT "/api/management/v1/catalogs/$CATALOG/catalog-roles/engineer/grants" \
  '{"grant":{"type":"catalog","privilege":"CATALOG_MANAGE_CONTENT"}}'

step "principal_role data_engineer" POST /api/management/v1/principal-roles \
  '{"principalRole":{"name":"data_engineer"}}'

step "principal_role -> catalog_role" \
  PUT "/api/management/v1/principal-roles/data_engineer/catalog-roles/$CATALOG" \
  '{"catalogRole":{"name":"engineer"}}'

step "root -> principal_role" \
  PUT "/api/management/v1/principals/root/principal-roles" \
  '{"principalRole":{"name":"data_engineer"}}'

echo "polaris: catalog '$CATALOG' ready at $WAREHOUSE"
