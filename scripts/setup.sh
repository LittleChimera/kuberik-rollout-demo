#!/usr/bin/env bash
# Set up the kuberik multi-environment rollout demo on a single kind cluster.
#
#   1. create a kind cluster (host ports mapped to each env's app + dashboard)
#   2. install Flux (+ image-reflector-controller)
#   3. install the kuberik rollout-controller and environment-controller
#   4. wire up dev / staging / prod, each with TWO rollouts:
#        • demo-manifests — promotes the packaged manifests (OCIRepository tag)
#        • demo-app       — promotes the app image (Kustomization substitution)
#      dev -> staging -> prod promotion is gated by Environment resources.
#
# Config via environment variables (all optional):
#   CLUSTER_NAME     kind cluster name              (default: kuberik-demo)
#   GITHUB_OWNER     ghcr / GitHub owner            (default: from `gh`/git remote)
#   REPO_URL         https git URL                  (default: from git remote)
#   REPO_PROJECT     owner/repo for GitHub backend  (default: from git remote)
#   GITHUB_BRANCH    branch / ref                   (default: main)
#   GITHUB_TOKEN     token for ghcr pull + backend  (default: `gh auth token`)
#   BASE_PORT        first host port                (default: 8080)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

CLUSTER_NAME="${CLUSTER_NAME:-kuberik-demo}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
BASE_PORT="${BASE_PORT:-8080}"
ENVIRONMENTS="dev staging prod"

# Host ports derived from BASE_PORT (dev / dashboard / staging / prod).
DEV_PORT="$BASE_PORT"
DASH_PORT="$((BASE_PORT + 1))"
STAGING_PORT="$((BASE_PORT + 2))"
PROD_PORT="$((BASE_PORT + 3))"
export DEV_PORT DASH_PORT STAGING_PORT PROD_PORT

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
for tool in kind kubectl flux docker envsubst gh; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found in PATH"
done

# --- resolve owner / repo / token --------------------------------------------
if [ -z "${GITHUB_OWNER:-}" ] && gh auth status >/dev/null 2>&1; then
  GITHUB_OWNER="$(gh api user --jq .login 2>/dev/null || true)"
fi
if [ -z "${GITHUB_OWNER:-}" ] && git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
  GITHUB_OWNER="$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#.*[:/]([^/]+)/[^/]+$#\1#')"
fi
[ -n "${GITHUB_OWNER:-}" ] || die "could not determine GITHUB_OWNER; set it explicitly"

if [ -z "${REPO_PROJECT:-}" ] && git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
  REPO_PROJECT="$(git -C "$REPO_ROOT" remote get-url origin \
    | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')"
fi
REPO_PROJECT="${REPO_PROJECT:-${GITHUB_OWNER}/kuberik-rollout-demo}"

# ghcr repository names must be lowercase; GitHub API project is case-insensitive.
GITHUB_OWNER="$(printf '%s' "$GITHUB_OWNER" | tr '[:upper:]' '[:lower:]')"
export GITHUB_OWNER

GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
[ -n "$GITHUB_TOKEN" ] || die "no GITHUB_TOKEN and 'gh auth token' failed"

log "owner=${GITHUB_OWNER}  project=${REPO_PROJECT}  ports=${DEV_PORT}/${DASH_PORT}/${STAGING_PORT}/${PROD_PORT}"

# --- 1. kind cluster ---------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '${CLUSTER_NAME}' already exists"
else
  log "creating kind cluster '${CLUSTER_NAME}'"
  envsubst '${DEV_PORT} ${DASH_PORT} ${STAGING_PORT} ${PROD_PORT}' < "${REPO_ROOT}/kind-config.yaml" \
    | kind create cluster --name "$CLUSTER_NAME" --config -
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# --- 2. Flux -----------------------------------------------------------------
log "installing Flux (+ image-reflector-controller)"
flux install --components-extra=image-reflector-controller

# --- 3. controllers ----------------------------------------------------------
log "installing kuberik rollout-controller"
kubectl apply --server-side -f "${REPO_ROOT}/rollout-controller/install.yaml"
log "installing kuberik environment-controller"
kubectl apply --server-side -f "${REPO_ROOT}/environment-controller/install.yaml"
kubectl -n kuberik-system rollout status deploy/rollout-controller-controller-manager --timeout=180s
kubectl -n kuberik-system rollout status deploy/environment-controller-manager --timeout=180s

# --- 4. per-environment wiring ----------------------------------------------
apply_environment() {
  # $1 = env, $2 = upstream env ("" for the root/dev environment)
  local env="$1" upstream="$2" rel=""
  if [ -n "$upstream" ]; then
    rel=$'\n  relationship:\n    environment: '"${upstream}"$'\n    type: After'
  fi
  kubectl apply --server-side -f - <<EOF
apiVersion: environments.kuberik.com/v1alpha1
kind: Environment
metadata:
  name: demo-app
  namespace: demo-${env}
spec:
  rolloutRef:
    name: demo-app
  name: "demo-${env}"
  environment: "${env}"
  backend:
    type: "github"
    project: "${REPO_PROJECT}"
    secret: "github-token"${rel}
EOF
}

upstream=""
for env in $ENVIRONMENTS; do
  log "wiring environment '${env}'"
  ENV="$env" envsubst '${ENV} ${GITHUB_OWNER}' < "${REPO_ROOT}/k8s/platform/env-template.yaml" \
    | kubectl apply --server-side --force-conflicts -f -

  # ghcr pull creds (private manifests packages) + backend token, per namespace.
  kubectl -n "demo-${env}" create secret docker-registry github-registry-credentials \
    --docker-server=ghcr.io --docker-username="$GITHUB_OWNER" --docker-password="$GITHUB_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "demo-${env}" create secret generic github-token \
    --from-literal=token="$GITHUB_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "demo-${env}" patch serviceaccount default \
    -p '{"imagePullSecrets":[{"name":"github-registry-credentials"}]}'

  apply_environment "$env" "$upstream"
  upstream="$env"
done

# --- 5. dashboard ------------------------------------------------------------
log "installing the rollout dashboard UI"
kubectl apply -f "${REPO_ROOT}/k8s/platform/dashboard.yaml"
kubectl -n kuberik-system rollout status deploy/rollout-dashboard --timeout=120s || true

cat <<EOF

$(printf '\033[1;32m✔ setup complete\033[0m')

  Dashboard UI:   http://localhost:${DASH_PORT}
  dev app:        http://localhost:${DEV_PORT}
  staging app:    http://localhost:${STAGING_PORT}
  prod app:       http://localhost:${PROD_PORT}

  Watch the two rollouts per env:
    kubectl -n demo-dev get rollout
    kubectl get rollout -A -w

  Publish releases (two independent streams):
    git tag app-v1.0.1       && git push origin app-v1.0.1        # new image
    git tag manifests-v1.0.1 && git push origin manifests-v1.0.1  # new manifests

  Promotion is gated dev -> staging -> prod by the Environment resources.
EOF
