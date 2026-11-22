#!/usr/bin/env bash
# Runs browser/auth.spec.mjs in a Playwright pod inside the kind cluster.
# Needs: Gjallar installed with auth.issuer pointing at gjallar-helm/keycloak/keycloak-dev.yaml,
# users admin/viewer with non-temporary passwords (ADMIN=user:pw, VIEWER=user:pw),
# and the web URL allowed as a redirect URI on client gjallar-web.
set -euo pipefail
cd "$(dirname "$0")/.."
CORE=$(realpath "${CORE:-../gjallar}")   # github.com/heimdallr-dev/gjallar
PW_VERSION=1.49.1
OUT=${OUT:-browser/out}
mkdir -p "$OUT"
if command -v go >/dev/null; then
  (cd "$CORE" && CGO_ENABLED=0 go build -mod=vendor -o "$OLDPWD/$OUT/gjallar" ./cmd/gjallar)
else # no Go toolchain: build in a container (containerd via nerdctl, or Docker)
  C=$(command -v docker || echo "sudo -n nerdctl --namespace default")
  $C run --rm -v "$CORE:/src:ro" -v "$(realpath "$OUT"):/out" -w /src -e CGO_ENABLED=0 -e GOFLAGS=-mod=vendor \
    golang:1.26.11 go build -buildvcs=false -o /out/gjallar ./cmd/gjallar
fi

kubectl -n gjallar delete pod pwtest --ignore-not-found --wait >/dev/null
kubectl -n gjallar run pwtest --restart=Never --image="mcr.microsoft.com/playwright:v${PW_VERSION}-noble" \
  --command -- sleep 1800 >/dev/null
kubectl -n gjallar wait --for=condition=Ready pod/pwtest --timeout=15m >/dev/null
trap 'kubectl -n gjallar delete pod pwtest --wait=false >/dev/null' EXIT
kubectl -n gjallar exec pwtest -- mkdir -p /work/out
kubectl -n gjallar cp browser/auth.spec.mjs pwtest:/work/auth.spec.mjs
kubectl -n gjallar cp "$OUT/gjallar" pwtest:/work/gjallar
kubectl -n gjallar exec pwtest -- sh -c "chmod +x /work/gjallar && cd /work && npm i --silent --no-audit --no-fund playwright@${PW_VERSION} >/dev/null"
kubectl -n gjallar exec pwtest -- env ADMIN="${ADMIN:-admin:test-admin}" VIEWER="${VIEWER:-viewer:test-viewer}" \
  sh -c "cd /work && node auth.spec.mjs"
for f in web-signed-in.png device-approved.png; do kubectl -n gjallar cp "pwtest:/work/out/$f" "$OUT/$f" >/dev/null 2>&1 || true; done
echo "screenshots in $OUT"
