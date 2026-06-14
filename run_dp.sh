#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
set -a
source .env.konnect
set +a

NAME="straiker-konnect-dp"
docker rm -f "$NAME" >/dev/null 2>&1 || true

docker run -d --name "$NAME" \
  -e "KONG_ROLE=data_plane" \
  -e "KONG_DATABASE=off" \
  -e "KONG_VITALS=off" \
  -e "KONG_CLUSTER_MTLS=pki" \
  -e "KONG_CLUSTER_CONTROL_PLANE=${KONG_CLUSTER_CONTROL_PLANE}" \
  -e "KONG_CLUSTER_SERVER_NAME=${KONG_CLUSTER_SERVER_NAME}" \
  -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=${KONG_CLUSTER_TELEMETRY_ENDPOINT}" \
  -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=${KONG_CLUSTER_TELEMETRY_SERVER_NAME}" \
  -e "KONG_CLUSTER_CERT=${KONG_CLUSTER_CERT}" \
  -e "KONG_CLUSTER_CERT_KEY=${KONG_CLUSTER_CERT_KEY}" \
  -e "KONG_LUA_SSL_TRUSTED_CERTIFICATE=system" \
  -e "KONG_TLS_CERTIFICATE_VERIFY=off" \
  -e "KONG_KONNECT_MODE=on" \
  -e "KONG_ROUTER_FLAVOR=expressions" \
  -e "KONG_PLUGINS=bundled,straiker" \
  -p 8000:8000 \
  -p 8443:8443 \
  straiker-konnect-dp:0.6.0

echo "Container started. Tailing logs..."
docker logs -f "$NAME"
