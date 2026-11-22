# gjallar-e2e

Cluster-level end-to-end suites for [Gjallar](https://github.com/heimdallr-dev/gjallar).
The fast, process-level e2e (`make e2e`: real binaries + NATS + Postgres +
DuckDB, fake scanners) lives in the core repo because it uses core packages;
this repo exercises a **real Kubernetes cluster** with every add-on.

| Path | What |
|---|---|
| `kind/setup-all.sh` | From "WSL just restarted" to kind + Gjallar + Kyverno + KEDA + dev Keycloak + Inspektor Gadget + test registry/webhook, every feature on |
| `kind/values-full.yaml` | Helm values with every optional feature enabled |
| `kind/test-infra.yaml` | Plain-HTTP registry (Copa/cosign target) and an echo webhook (notification target) |
| `browser/` | Playwright: web UI login with PKCE and the CLI device flow, in a pod inside the cluster |

## Run

```bash
# sibling checkouts
git clone https://github.com/heimdallr-dev/gjallar
git clone https://github.com/heimdallr-dev/gjallar-helm
git clone https://github.com/heimdallr-dev/gjallar-e2e
(cd gjallar && make images BUILDER=nerdctl)        # or BUILDER=docker
cd gjallar-e2e
kind/setup-all.sh              # CORE=../gjallar HELM_REPO=../gjallar-helm by default
browser/run-in-kind.sh         # PASS lines + screenshots in browser/out/
```

Needs: kind, helm, kubectl, kubectl-gadget, nerdctl (or Docker), and private
env files for Harbor and S3 (see the header of `kind/setup-all.sh`). Plan on
**≥ 16 GB RAM**: the full stack restarted an 11 GB WSL VM three times.

Results so far: [verification reports](https://github.com/heimdallr-dev/gjallar-docs/tree/main/docs).

Apache-2.0.
