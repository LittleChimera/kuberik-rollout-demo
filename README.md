# kuberik rollout demo

A self-contained demo of [kuberik](https://github.com/kuberik) progressive
delivery on a single local [kind](https://kind.sigs.k8s.io/) cluster, with a
**dev → staging → prod** promotion pipeline and **two independent rollouts** per
environment.

Two version streams, published by GitHub Actions and rolled out by kuberik:

- **image** — the app container (`app-v*` tags) → promoted by the `demo-app` Rollout
- **manifests** — the packaged k8s manifests (`manifests-v*` tags) → promoted by the `demo-manifests` Rollout

```
 app-v1.0.1 ─▶ Actions ─▶ ghcr…/kuberik-rollout-demo:1.0.1 ─▶ ImagePolicy demo-app ─┐
                                                                                    ▼
 manifests-v1.0.0 ─▶ Actions ─▶ ghcr…/<env>/manifests:1.0.0 ─▶ ImagePolicy demo-manifests
                                                                                    │
   per env (dev, staging, prod):                                                    ▼
     demo-manifests Rollout ──patches──▶ OCIRepository.tag ─┐                 demo-app Rollout
     demo-app       Rollout ──patches──▶ Kustomization APP_VERSION            ──patches──▶ …
                                                            ▼
                                                     Flux Kustomization ─▶ Deployment `demo`
                                                            │
                            HealthCheck (kustomization) ◀───┘   gate ▸ bake ▸ promote

   Environment resources gate the app rollout:  dev ──After──▶ staging ──After──▶ prod
```

## Prerequisites

`kind`, `kubectl`, `flux`, `docker`, `envsubst`, and `gh` (authenticated) on
your `PATH`. Fork this repo to your own GitHub account so Actions can publish to
your ghcr.

## Quick start

```bash
# 1. Fork/clone and push to your GitHub account.
# 2. Publish the first image + manifests so there's something to roll out:
git tag app-v1.0.0        && git push origin app-v1.0.0
git tag manifests-v1.0.0  && git push origin manifests-v1.0.0
# 3. Bring up the cluster + full pipeline:
./scripts/setup.sh
```

`setup.sh` auto-detects your owner/repo from `gh`/`git remote` and uses
`gh auth token` for ghcr pulls and the GitHub Deployments backend.

### Access (no port-forward — kind maps the ports)

| URL | What |
|-----|------|
| <http://localhost:8081> | dashboard UI (envs, rollouts, history, gates) |
| <http://localhost:8080> | dev app |
| <http://localhost:8082> | staging app |
| <http://localhost:8083> | prod app |

If those ports are taken, run `BASE_PORT=8090 ./scripts/setup.sh` (uses 8090–8093).

### Watch it roll

```bash
kubectl get rollout -A -w              # both rollouts, every env
kubectl -n demo-dev get pods -L version
```

### Ship a new version

```bash
git tag app-v1.0.1       && git push origin app-v1.0.1        # image only
git tag manifests-v1.0.1 && git push origin manifests-v1.0.1  # manifests only
```

The matching Rollout in **dev** promotes first; **staging** only accepts a
version once **dev** has deployed it, and **prod** once **staging** has — enforced
by the `Environment` resources (RolloutGates created by the environment-controller,
with status reported to the repo's GitHub Deployments).

## What's in here

| Path | Purpose |
|------|---------|
| `app/` | the demo web app + `Dockerfile` |
| `.github/workflows/app-release.yml` | `app-v*` → push app image |
| `.github/workflows/manifests-release.yml` | `manifests-v*` → push per-env manifests OCI artifacts |
| `k8s/app/base` + `k8s/app/envs/{dev,staging,prod}` | app manifests + per-env overlays |
| `k8s/platform/env-template.yaml` | per-env wiring: 2 image policies, OCIRepository, Kustomization, 2 Rollouts, HealthCheck |
| `k8s/platform/dashboard.yaml` | dashboard UI + read RBAC |
| `rollout-controller/install.yaml` | pinned `ghcr.io/kuberik/rollout-controller:v0.8.0` |
| `environment-controller/install.yaml` | pinned `ghcr.io/kuberik/environment-controller:v0.1.5` |
| `scripts/setup.sh` / `teardown.sh` | cluster up / down |

## The two rollouts

Per environment there are two kuberik `Rollout`s, each reading a different
`ImagePolicy` and driving a different thing — so a manifest change and an image
change promote independently:

- **`demo-manifests`** scans `…/<env>/manifests` and patches the
  **`OCIRepository`** tag (which packaged manifests version Flux applies).
- **`demo-app`** scans `…/kuberik-rollout-demo` and patches the Flux
  **`Kustomization`**'s `APP_VERSION` substitution (which image the Deployment runs).

Both gate on the same kuberik `HealthCheck` (`class: kustomization`), which ties
rollout success to the Flux Kustomization reconciling healthy.

## Tear down

```bash
./scripts/teardown.sh
```
