#!/usr/bin/env bash
# Set up a single kind cluster running the kuberik rollout demo.
#
#   1. create a kind cluster
#   2. install Flux (+ image-reflector-controller)
#   3. install the kuberik rollout-controller
#   4. wire up the demo app (GitOps source + Rollout + image scanning)
#
# Config via environment variables (all optional):
#   CLUSTER_NAME     kind cluster name              (default: kuberik-demo)
#   GITHUB_OWNER     ghcr / GitHub owner            (default: from `gh`/git remote)
#   REPO_URL         https git URL Flux clones      (default: from git remote)
#   GITHUB_BRANCH    branch Flux tracks             (default: main)
#   GHCR_TOKEN       PAT for a PRIVATE ghcr package (default: empty = public package)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

CLUSTER_NAME="${CLUSTER_NAME:-kuberik-demo}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
ROLLOUT_CONTROLLER_MANIFEST="${REPO_ROOT}/rollout-controller/install.yaml"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
for tool in kind kubectl flux docker envsubst; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found in PATH"
done

# --- resolve owner / repo ----------------------------------------------------
if [ -z "${GITHUB_OWNER:-}" ]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    GITHUB_OWNER="$(gh api user --jq .login 2>/dev/null || true)"
  fi
  if [ -z "${GITHUB_OWNER:-}" ] && git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
    GITHUB_OWNER="$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#.*[:/]([^/]+)/[^/]+$#\1#')"
  fi
fi
[ -n "${GITHUB_OWNER:-}" ] || die "could not determine GITHUB_OWNER; set it explicitly"
GITHUB_OWNER="$(printf '%s' "$GITHUB_OWNER" | tr '[:upper:]' '[:lower:]')"

if [ -z "${REPO_URL:-}" ]; then
  if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
    REPO_URL="$(git -C "$REPO_ROOT" remote get-url origin \
      | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##').git"
  else
    REPO_URL="https://github.com/${GITHUB_OWNER}/kuberik-rollout-demo.git"
  fi
fi

export GITHUB_OWNER REPO_URL GITHUB_BRANCH

log "owner=${GITHUB_OWNER}  repo=${REPO_URL}  branch=${GITHUB_BRANCH}"

# --- 1. kind cluster ---------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '${CLUSTER_NAME}' already exists"
else
  log "creating kind cluster '${CLUSTER_NAME}'"
  kind create cluster --name "$CLUSTER_NAME" --config "${REPO_ROOT}/kind-config.yaml"
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# --- 2. Flux -----------------------------------------------------------------
log "installing Flux (+ image-reflector-controller)"
flux install --components-extra=image-reflector-controller

# --- 3. rollout-controller ---------------------------------------------------
log "installing kuberik rollout-controller"
kubectl apply --server-side -f "$ROLLOUT_CONTROLLER_MANIFEST"
kubectl -n kuberik-system rollout status deploy/rollout-controller-controller-manager --timeout=180s

# --- 4. demo app -------------------------------------------------------------
log "applying demo namespace + platform wiring"
kubectl apply -f "${REPO_ROOT}/k8s/platform/namespace.yaml"

# Optional pull/scan secret for a PRIVATE ghcr package.
if [ -n "${GHCR_TOKEN:-}" ]; then
  log "creating ghcr auth secret (private package mode)"
  kubectl -n demo create secret docker-registry ghcr-auth \
    --docker-server=ghcr.io --docker-username="$GITHUB_OWNER" --docker-password="$GHCR_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# Server-side apply so re-running setup.sh never clobbers the APP_VERSION that
# the Rollout owns on the Kustomization (a different field manager).
for f in image.yaml source.yaml rollout.yaml; do
  envsubst '${GITHUB_OWNER} ${REPO_URL} ${GITHUB_BRANCH}' \
    < "${REPO_ROOT}/k8s/platform/${f}" \
    | kubectl apply --server-side --force-conflicts -f -
done

# Read-only web UI (published kuberik dashboard image, into kuberik-system).
log "installing the rollout dashboard UI"
kubectl apply -f "${REPO_ROOT}/k8s/platform/dashboard.yaml"

log "waiting for the Rollout to promote the first release..."
if ! kubectl -n demo wait --for=create deploy/demo --timeout=180s 2>/dev/null; then
  log "deployment not created yet — the Rollout is still selecting/gating a release"
fi
kubectl -n demo rollout status deploy/demo --timeout=240s || true
kubectl -n kuberik-system rollout status deploy/rollout-dashboard --timeout=120s || true

cat <<EOF

$(printf '\033[1;32m✔ setup complete\033[0m')

  Watch the rollout:
    kubectl -n demo get rollout demo -w
    kubectl -n demo get imagepolicy demo
    kubectl -n demo get pods -L version

  Dashboard UI:  http://localhost:8081
  Demo app:      http://localhost:8080
  (mapped straight through kind — no port-forward needed)

  Promote a new version: push a git tag (v1.0.1) — CI publishes the image,
  Flux detects it, and the Rollout rolls it out automatically.
EOF
