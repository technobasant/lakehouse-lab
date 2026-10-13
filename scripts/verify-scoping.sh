#!/usr/bin/env bash
# =============================================================================
# Prove the vended credential is confined to its own table prefix.
#
# "Polaris returns a prefix field" is a label, not evidence. The only thing that
# settles it is taking the credential Polaris just handed out and trying to read
# something it should not reach.
#
# Expected result:
#   own prefix                       ALLOW
#   sibling table bronze.customers   DENY (AccessDenied)
#   whole warehouse bucket           DENY (AccessDenied)
#
# Run it from a container on the compose network:
#   docker run --rm --network lakehouse_default -v "$PWD/scripts:/s:ro" \
#     --entrypoint bash amazon/aws-cli:latest /s/verify-scoping.sh
#
# Two things that make this look broken when it is not, both cost me a while:
#
#   1. The vended prefix carries the table UUID Iceberg assigns at create time
#      — `bronze/orders-964137655cf0...`, not `bronze/orders`. Probing the tidy
#      path denies, and reads as a scoping failure.
#   2. `aws s3 ls` needs the trailing slash and a region. Without them the call
#      fails in a way that is indistinguishable from AccessDenied at a glance.
#
# Prints allow/deny only. No secret reaches stdout.
# =============================================================================
set -euo pipefail

POLARIS_URL="${POLARIS_URL:-http://polaris:8181}"
S3_ENDPOINT="${S3_ENDPOINT:-http://minio:9000}"
CATALOG="${CATALOG:-lakehouse}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

TOKEN="$(curl -s -X POST "$POLARIS_URL/api/catalog/v1/oauth/tokens" \
  -d grant_type=client_credentials -d client_id=root \
  -d client_secret="${POLARIS_ROOT_SECRET:-s3cr3t-dev-only}" -d 'scope=PRINCIPAL_ROLE:ALL' \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
[ -n "$TOKEN" ] || { echo "no token from $POLARIS_URL"; exit 1; }

load() { # namespace table -> /tmp/<table>.json
  curl -s -H "Authorization: Bearer $TOKEN" \
       -H 'X-Iceberg-Access-Delegation: vended-credentials' \
       "$POLARIS_URL/api/catalog/v1/$CATALOG/namespaces/$1/tables/$2" > "/tmp/$2.json"
}

field() { # file  jq-ish path -> value
  python3 -c "
import json,sys
d = json.load(open(sys.argv[1]))
c = (d.get('storage-credentials') or [{}])[0]
print(c['config'][sys.argv[2]] if sys.argv[2].startswith('s3.') else c.get(sys.argv[2], ''))
" "$1" "$2"
}

probe() { # label  s3-uri
  local out rc
  set +e; out="$(aws --endpoint-url "$S3_ENDPOINT" s3 ls "$2" --recursive 2>&1)"; rc=$?; set -e
  if [ "$rc" -eq 0 ]; then
    printf '  %-34s ALLOW  %s objects\n' "$1" "$(printf '%s\n' "$out" | grep -c . || true)"
  else
    printf '  %-34s DENY   %s\n' "$1" \
      "$(printf '%s\n' "$out" | grep -o 'AccessDenied\|[A-Za-z]*Error' | head -1)"
  fi
}

load bronze orders
load bronze customers
OWN="$(field /tmp/orders.json prefix)"
SIB="$(field /tmp/customers.json prefix)"

# Assigned before export so a failed lookup stops the script under `set -e`
# instead of exporting an empty credential and probing anonymously.
AWS_ACCESS_KEY_ID="$(field /tmp/orders.json s3.access-key-id)"
AWS_SECRET_ACCESS_KEY="$(field /tmp/orders.json s3.secret-access-key)"
AWS_SESSION_TOKEN="$(field /tmp/orders.json s3.session-token)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

echo "credential vended for bronze.orders"
echo "  prefix: $OWN"
echo
echo "using only that credential:"
probe "own prefix"                "$OWN/"
probe "sibling bronze.customers"  "$SIB/"
probe "whole warehouse bucket"    "s3://warehouse/"
