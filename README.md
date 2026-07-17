# kuberik rollout demo

A self-contained demo of [kuberik](https://github.com/kuberik) progressive
delivery on a single local [kind](https://kind.sigs.k8s.io/) cluster.

Push a git tag → GitHub Actions publishes a container image → Flux notices the
new release → the kuberik **Rollout** health-checks, bakes, and promotes it —
all GitOps, no manual `kubectl set image`.

```
 git tag v1.0.1
      │
      ▼
 GitHub Actions ──push──▶ ghcr.io/<owner>/kuberik-rollout-demo:1.0.1
      │                                   │
      │                          Flux ImageRepository/ImagePolicy (scan tags)
      │                                   │
      ▼                                   ▼
 GitRepository (this repo) ─▶ Flux Kustomization ◀── kuberik Rollout
      k8s/app manifests          (APP_VERSION substituted)   (gates ▸ health ▸ bake ▸ promote)
                                        │
                                        ▼
                                  Deployment `demo`  →  pods running v1.0.1
```

## Prerequisites

`kind`, `kubectl`, `flux`, `docker`, and `envsubst` on your `PATH`. To publish
images you also need a GitHub repo (fork this one) with Actions enabled.

## Quick start

```bash
# 1. Fork/clone this repo and push it to your own GitHub account.
# 2. Cut the first release so an image exists to roll out:
git tag v1.0.0 && git push origin v1.0.0     # GitHub Actions builds & pushes the image

# 3. (first time only) make the ghcr package public so the cluster can pull it:
#    GitHub ▸ your profile ▸ Packages ▸ kuberik-rollout-demo ▸ Package settings ▸ Change visibility ▸ Public

# 4. Bring up the cluster and deploy the demo:
./scripts/setup.sh
```

`setup.sh` auto-detects your GitHub owner and repo URL from `gh`/`git remote`.
Override with `GITHUB_OWNER`, `REPO_URL`, `GITHUB_BRANCH` env vars if needed.

### Watch it roll

The **dashboard UI** shows rollouts, history, gates, and health checks:

```bash
kubectl -n kuberik-system port-forward svc/rollout-dashboard 8081:80
open http://localhost:8081
```

Or from the CLI:

```bash
kubectl -n demo get rollout demo -w      # rollout phases
kubectl -n demo get pods -L version      # pods labelled with the running version
kubectl -n demo port-forward svc/demo 8080:80
open http://localhost:8080               # the page shows the deployed version
```

### Ship a new version

```bash
git tag v1.0.1 && git push origin v1.0.1
```

Within ~a minute Flux picks up the new image, the Rollout runs it through its
health check + bake time, and promotes it. The browser page flips to `v1.0.1`.

## What's in here

| Path | Purpose |
|------|---------|
| `app/` | the demo web app (shows its baked-in version) + `Dockerfile` |
| `.github/workflows/release.yml` | build & push `ghcr.io/<owner>/kuberik-rollout-demo:<semver>` on tag `v*` |
| `k8s/app/` | app manifests Flux renders (`${APP_VERSION}` filled in by the Rollout) |
| `k8s/platform/` | GitOps source, image scanning, the kuberik `Rollout`, and the dashboard UI |
| `rollout-controller/install.yaml` | pinned kuberik rollout-controller (`ghcr.io/kuberik/rollout-controller:v0.8.0`) |
| `scripts/setup.sh` / `teardown.sh` | one-command cluster up / down |

## How the rollout works

- **`ImageRepository` + `ImagePolicy`** (Flux) scan ghcr and expose the newest
  semver tag.
- **`Rollout`** (kuberik) reads that policy, evaluates gates + `HealthCheck`s,
  waits out `bakeTime`, then patches the Flux **`Kustomization`**'s
  `APP_VERSION` substitution to promote the release.
- **`GitRepository` + `Kustomization`** (Flux) render `k8s/app` with the
  promoted `APP_VERSION` and apply the `Deployment`.
- **`HealthCheck`** (`class: kustomization`) ties rollout success to the Flux
  Kustomization actually reconciling healthy.

## Private package?

If you keep the ghcr package private, pass a PAT with `read:packages` so the
cluster can pull and scan it, and uncomment the `secretRef` in
`k8s/platform/image.yaml`:

```bash
GHCR_TOKEN=ghp_xxx ./scripts/setup.sh
```

## Tear down

```bash
./scripts/teardown.sh
```
