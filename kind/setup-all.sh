#!/usr/bin/env bash
# One command from "WSL just restarted" to a kind cluster with Gjallar and
# every add-on used in gjallar-docs verification reports:
#   Kyverno, KEDA, dev Keycloak, Inspektor Gadget, test registry + webhook,
#   DuckLake on S3 (Ceph RGW), Harbor discovery, Copa, cosign, regolibrary.
# Small host (< 16 GB)? LIGHT=1 skips Kyverno, KEDA and Inspektor Gadget;
# REUSE_CLUSTER=1 keeps a running cluster; PATCH_TARGET=harbor.example.org/proj/patched
# sends Copa's patched images to a real registry (credentials from harbor.env).
# Needs: make images BUILDER=nerdctl, the NOPASSWD nerdctl rule, kind, helm,
# kubectl-gadget, and private env files:
#   ~/.config/gjallar/harbor.env   HARBOR_URL, HARBOR_USER, HARBOR_PASSWORD
#   ~/.config/gjallar/ceph-s3.env  GJALLAR_S3_ENDPOINT, _REGION, _ACCESS_KEY, _SECRET_KEY
set -euo pipefail
cd "$(dirname "$0")/.."
# Sibling checkouts: github.com/heimdallr-dev/gjallar and gjallar-helm.
CORE=$(realpath "${CORE:-../gjallar}")
HELM_REPO=$(realpath "${HELM_REPO:-../gjallar-helm}")
N="sudo -n nerdctl"
K="kubectl"

# Inspektor Gadget on kind needs more inotify instances (resets on reboot).
$N run --rm --privileged busybox:1.36 sysctl -w fs.inotify.max_user_instances=512 >/dev/null

[ "${REUSE_CLUSTER:-}" = 1 ] || HELM_REPO="$HELM_REPO" "$CORE/scripts/kind-dev.sh" up --set auth.issuer=http://keycloak.keycloak.svc:8080/realms/gjallar >/dev/null

EXTRA=()
if [ "${LIGHT:-}" = 1 ]; then
  EXTRA+=(--set keda.enabled=false --set agent.runtime.enabled=false)
else
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update kyverno kedacore >/dev/null
helm upgrade --install kyverno kyverno/kyverno --version 3.10.0 -n kyverno --create-namespace \
  --set admissionController.replicas=1 --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 --set reportsController.replicas=1 --wait --timeout 15m >/dev/null
helm upgrade --install keda kedacore/keda --version 2.21.1 -n keda --create-namespace --wait --timeout 15m >/dev/null
fi
[ -z "${PATCH_TARGET:-}" ] || EXTRA+=(--set workers.patch.targetRepository="$PATCH_TARGET")

# Dev Keycloak with the realm; test users get fixed passwords and the CLI
# client allows password grants (this throwaway instance only).
$K create ns keycloak --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n keycloak create configmap gjallar-realm --from-file="$HELM_REPO/keycloak/gjallar-realm.json" --dry-run=client -o yaml | $K apply -f - >/dev/null
$K apply -f "$HELM_REPO/keycloak/keycloak-dev.yaml" >/dev/null
$K -n keycloak rollout status deploy/keycloak --timeout=15m >/dev/null
$K -n gjallar run kc-setup --rm -i --restart=Never --pod-running-timeout=10m --image=alpine:3.22 -- sh -s <<'KC' >/dev/null
apk add -q --no-cache curl jq >/dev/null; KC=http://keycloak.keycloak.svc:8080
# Ready is reported before the admin API answers: retry the admin token.
for i in $(seq 60); do
  T=$(curl -s -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin $KC/realms/master/protocol/openid-connect/token | jq -r .access_token 2>/dev/null)
  [ -n "$T" ] && [ "$T" != null ] && break; sleep 5
done
H="Authorization: Bearer $T"
put() { curl -sf -X PUT -H "$H" -H 'Content-Type: application/json' -d @- "$KC/admin/realms/gjallar/$1"; }
cid() { curl -s -H "$H" "$KC/admin/realms/gjallar/clients?clientId=$1" | jq -r '.[0].id'; }
curl -s -H "$H" "$KC/admin/realms/gjallar/clients/$(cid gjallar-cli)" | jq '.directAccessGrantsEnabled=true' | put "clients/$(cid gjallar-cli)"
curl -s -H "$H" "$KC/admin/realms/gjallar/clients/$(cid gjallar-web)" | jq '.redirectUris += ["http://gjallar-web.gjallar.svc:8083/*"]' | put "clients/$(cid gjallar-web)"
curl -sf -X POST -H "$H" -H 'Content-Type: application/json' -d '{"name":"team-demo"}' $KC/admin/realms/gjallar/groups || true
GID=$(curl -s -H "$H" "$KC/admin/realms/gjallar/groups" | jq -r '.[] | select(.name=="team-demo") | .id')
for u in admin viewer; do
  UID_=$(curl -s -H "$H" "$KC/admin/realms/gjallar/users?username=$u&exact=true" | jq -r '.[0].id')
  echo "{\"type\":\"password\",\"value\":\"test-$u\",\"temporary\":false}" | put "users/$UID_/reset-password"
  curl -s -H "$H" "$KC/admin/realms/gjallar/users/$UID_" | jq '.requiredActions=[]' | put "users/$UID_"
done
VID=$(curl -s -H "$H" "$KC/admin/realms/gjallar/users?username=viewer&exact=true" | jq -r '.[0].id')
curl -sf -X PUT -H "$H" "$KC/admin/realms/gjallar/users/$VID/groups/$GID"
KC

[ "${LIGHT:-}" = 1 ] || kubectl gadget deploy --timeout 10m >/dev/null
$K apply -f kind/test-infra.yaml >/dev/null

# Secrets from the private env files (values never printed).
set -a; . ~/.config/gjallar/harbor.env; . ~/.config/gjallar/ceph-s3.env; set +a
$K -n gjallar create secret docker-registry harbor-gjallar --docker-server="$HARBOR_URL" --docker-username="$HARBOR_USER" --docker-password="$HARBOR_PASSWORD" --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n gjallar create secret generic harbor-discovery --from-literal=username="$HARBOR_USER" --from-literal=password="$HARBOR_PASSWORD" --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n gjallar create secret generic lake-s3 --from-literal=access-key="$GJALLAR_S3_ACCESS_KEY" --from-literal=secret-key="$GJALLAR_S3_SECRET_KEY" --dry-run=client -o yaml | $K apply -f - >/dev/null
$K -n gjallar create secret generic gjallar-notify --dry-run=client -o yaml --from-literal=GJALLAR_NOTIFY='[
 {"name":"team-demo","url":"http://webhook.gjallar-test.svc/hook","format":"slack","namespaces":["demo"],"min_band":"urgent","kev":true},
 {"name":"secops","url":"http://webhook.gjallar-test.svc/teams","format":"teams","min_band":"high"}]' | $K apply -f - >/dev/null
if ! $K -n gjallar get secret cosign-key >/dev/null 2>&1; then
  d=$(mktemp -d); pw=$(head -c 24 /dev/urandom | base64)
  $N run --rm -v "$d:/k" -w /k -e COSIGN_PASSWORD="$pw" --entrypoint cosign ghcr.io/heimdallr-dev/gjallar-worker-sbom:0.3.0 generate-key-pair >/dev/null 2>&1
  $N run --rm -v "$d:/k" busybox:1.36 chmod 644 /k/cosign.key /k/cosign.pub
  $K -n gjallar create secret generic cosign-key --from-file=cosign.key="$d/cosign.key" --from-file=cosign.pub="$d/cosign.pub" --from-literal=cosign.password="$pw" >/dev/null
  $N run --rm -v "$d:/k" busybox:1.36 rm -f /k/cosign.key /k/cosign.pub; rmdir "$d"
fi

helm upgrade gjallar "$HELM_REPO/charts/gjallar" -n gjallar -f "$HELM_REPO/charts/gjallar/values-kind.yaml" -f kind/values-full.yaml \
  --set image.tag=0.3.0 --set cluster.name=kind --set discovery.harbor.url="https://$HARBOR_URL" \
  --set analytics.mode=ducklake --set analytics.s3.dataPath=s3://gjallar-lake/ \
  --set analytics.s3.endpoint="$GJALLAR_S3_ENDPOINT" --set analytics.s3.region="$GJALLAR_S3_REGION" --set analytics.s3.existingSecret=lake-s3 \
  "${EXTRA[@]}" --wait --timeout 15m >/dev/null
[ "${LIGHT:-}" = 1 ] || $K apply -f "$HELM_REPO/policies/kyverno/" >/dev/null
$K -n gjallar get pods
