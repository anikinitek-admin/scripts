#!/bin/bash
#==============================================================================
# ArgoCD Standalone Setup Script
# Reusable script to bring up K3s + ArgoCD from scratch on any target node
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/anikinitek-admin/scripts/main/setup-argocd-standalone.sh | \
#     TARGET_NODE=<IP> SSH_KEY=~/.ssh/e2e GH_TOKEN=<PAT> bash
#
# Or copy this file and run locally:
#   bash setup-argocd-standalone.sh --target 164.52.205.18 --ssh-key ~/.ssh/e2e --gh-token ghp_xxx
#
# Prerequisites:
#   - Ubuntu/Debian target node with SSH access (root or sudo user)
#   - GitHub PAT with repo and admin:org scope
#   - Docker pre-installed on target node (for building)
#==============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Defaults
#-------------------------------------------------------------------------------
TARGET_NODE="${TARGET_NODE:-}"
SSH_KEY="${SSH_KEY:-~/.ssh/e2e}"
GH_TOKEN="${GH_TOKEN:-}"
GITOPS_REPO="anikinitek-admin/amscams-gitops"
APP_REPO="anikinitek-admin/amscams"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.12.3}"
K3S_VERSION="${K3S_VERSION:-v1.34.6+k3s1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_REMOTE="/etc/rancher/k3s/k3s.yaml"

#-------------------------------------------------------------------------------
# Colour output
#-------------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }

#-------------------------------------------------------------------------------
# Argument parsing
#-------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --target)      TARGET_NODE="$2"; shift 2 ;;
    --ssh-key)     SSH_KEY="$2"; shift 2 ;;
    --gh-token)    GH_TOKEN="$2"; shift 2 ;;
    --skip-k3s)    SKIP_K3S=1; shift ;;
    --skip-argocd) SKIP_ARGOCD=1; shift ;;
    --skip-gitops) SKIP_GITOPS=1; shift ;;
    --help)
      cat << 'EOF'
Usage: setup-argocd-standalone.sh [OPTIONS]

Options:
  --target     <IP>      Target node IP (required, or set TARGET_NODE env var)
  --ssh-key    <path>    Path to SSH private key (default: ~/.ssh/e2e)
  --gh-token   <token>   GitHub PAT (required, or set GH_TOKEN env var)
  --skip-k3s             Skip K3s installation (use existing cluster)
  --skip-argocd           Skip ArgoCD installation
  --skip-gitops           Skip GitOps repo setup
  --help                  Show this help

All options can be set via environment variables:
  TARGET_NODE, SSH_KEY, GH_TOKEN
EOF
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

#-------------------------------------------------------------------------------
# Validation
#-------------------------------------------------------------------------------
[[ -z "$TARGET_NODE" ]] && { error "TARGET_NODE is required. Set --target or TARGET_NODE env var."; exit 1; }
[[ -z "$GH_TOKEN" ]] && { error "GH_TOKEN is required. Set --gh-token or GH_TOKEN env var."; exit 1; }
[[ ! -f "$SSH_KEY" ]] && { error "SSH key not found: $SSH_KEY"; exit 1; }

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i $SSH_KEY"

#-------------------------------------------------------------------------------
# Remote execution helper
#-------------------------------------------------------------------------------
run() {
  ssh $SSH_OPTS "root@${TARGET_NODE}" "$@"
}

#-------------------------------------------------------------------------------
# Wait for command success with timeout
#-------------------------------------------------------------------------------
wait_for() {
  local desc="$1"
  local timeout="${2:-120}"
  local interval="${3:-5}"
  local cmd="$4"
  local elapsed=0
  while ! eval "$cmd" &>/dev/null; do
    elapsed=$((elapsed + interval))
    if ((elapsed >= timeout)); then
      error "$desc timed out after ${timeout}s"
      return 1
    fi
    sleep "$interval"
  done
  return 0
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
  echo ""
  echo "=========================================="
  echo " ArgoCD Standalone Setup"
  echo " Target: $TARGET_NODE"
  echo " K3s:    $K3S_VERSION"
  echo " ArgoCD: $ARGOCD_VERSION"
  echo "=========================================="
  echo ""

  #---- Check connectivity ----------------------------------------
  info "Checking SSH connectivity to $TARGET_NODE..."
  if run "echo ok" 2>/dev/null | grep -q ok; then
    success "SSH connection verified"
  else
    error "Cannot SSH to $TARGET_NODE"
    exit 1
  fi

  #---- K3s Installation ----------------------------------------
  if [[ "${SKIP_K3S:-}" != "1" ]]; then
    info "Checking existing K3s installation..."
    if run "[[ -f /usr/local/bin/k3s ]] && [[ -f $KUBECONFIG_REMOTE ]]" 2>/dev/null; then
      CLUSTER_UP=$(run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl get nodes -o jsonpath='{.items[0].status.phase}' 2>/dev/null" || echo "notready")
      if [[ "$CLUSTER_UP" == "Ready" ]]; then
        success "K3s cluster already running"
        SKIP_K3S=1
      fi
    fi
  fi

  if [[ "${SKIP_K3S:-}" != "1" ]]; then
    info "Installing K3s $K3S_VERSION on $TARGET_NODE..."

    run "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - \
      server --cluster-init --tls-san $TARGET_NODE \
      --disable traefik --disable servicelb \
      --node-label node=primary" || {
        error "K3s install failed"
        exit 1
      }

    info "Waiting for K3s API to be ready..."
    wait_for "K3s API" 120 \
      "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl get nodes -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Ready"

    success "K3s cluster is up"
  fi

  #---- Update kubeconfig locally --------------------------------
  info "Fetching kubeconfig to ~/.kube/config..."
  mkdir -p ~/.kube
  run "cat $KUBECONFIG_REMOTE" > ~/.kube/config 2>/dev/null || true
  success "kubeconfig saved to ~/.kube/config"
  echo "  Run: export KUBECONFIG=~/.kube/config"

  #---- ArgoCD Installation -------------------------------------
  if [[ "${SKIP_ARGOCD:-}" != "1" ]]; then
    info "Checking ArgoCD installation..."
    ARGOCD_INSTALLED=$(run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl get ns $ARGOCD_NAMESPACE -o jsonpath='{.metadata.name}' 2>/dev/null" || echo "")
    if [[ "$ARGOCD_INSTALLED" == "$ARGOCD_NAMESPACE" ]]; then
      PODS=$(run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl get pods -n $ARGOCD_NAMESPACE --no-headers 2>/dev/null | awk '{print \$3}' | sort -u | xargs")
      if echo "$PODS" | grep -q "Running"; then
        success "ArgoCD already installed and healthy"
        SKIP_ARGOCD=1
      fi
    fi
  fi

  if [[ "${SKIP_ARGOCD:-}" != "1" ]]; then
    info "Setting up ArgoCD $ARGOCD_VERSION..."

    # Download install manifest
    run "curl -fsSL -o /tmp/argocd-install.yaml https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

    # Create namespace first to avoid landing in default
    run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl create ns $ARGOCD_NAMESPACE 2>/dev/null || true"

    # Apply ArgoCD
    run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl apply -f /tmp/argocd-install.yaml -n $ARGOCD_NAMESPACE"

    # Patch server to NodePort
    run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl patch svc argocd-server -n $ARGOCD_NAMESPACE -p '{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":443,\"targetPort\":8080,\"nodePort\":30080}]}}' 2>/dev/null || true"

    info "Waiting for ArgoCD pods to be ready..."
    wait_for "ArgoCD pods" 180 \
      "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl get pods -n $ARGOCD_NAMESPACE -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q 'Running.*Running.*Running.*Running.*Running.*Running.*Running'"

    success "ArgoCD is up and running"
  fi

  #---- ArgoCD GitHub Repo Connection ---------------------------
  info "Connecting ArgoCD to GitHub..."

  # Create GitHub credentials secret in ArgoCD namespace
  run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl create secret generic github-creds -n $ARGOCD_NAMESPACE \
    --from-literal=username=anikinitek-admin \
    --from-literal=password=$GH_TOKEN \
    --type=Opaque 2>/dev/null || true"

  # Install argocd CLI on the remote node
  run "curl -fsSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64 && chmod +x /usr/local/bin/argocd"

  # Wait for ArgoCD server to be ready before CLI login
  info "Waiting for ArgoCD server API..."
  wait_for "ArgoCD API" 60 \
    "curl -sk https://localhost:30080/info 2>/dev/null | grep -q version"

  # Login to ArgoCD CLI
  ARGOCD_PWD=$(run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d")
  run "/usr/local/bin/argocd login localhost:30080 --username admin --password $ARGOCD_PWD --insecure --grpc-web"

  # Add GitHub repo
  run "/usr/local/bin/argocd repo add https://github.com/${GITOPS_REPO}.git --username anikinitek-admin --password $GH_TOKEN --insecure --grpc-web 2>/dev/null || true"

  success "ArgoCD connected to GitHub"
  echo "  ArgoCD URL: https://${TARGET_NODE}:30080"
  echo "  Admin password: $ARGOCD_PWD"

  #---- ArgoCD Application --------------------------------------
  info "Creating ArgoCD Application 'amscams'..."
  run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl apply -f - << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: amscams
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/anikinitek-admin/amscams-gitops.git
    targetRevision: main
    path: amscams
  destination:
    server: https://kubernetes.default.svc
    namespace: amscams
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagation=foreground
      - PruneLast=true
EOF"

  # Wait for app to sync
  sleep 5
  APP_SYNC=$(run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl get application amscams -n $ARGOCD_NAMESPACE -o jsonpath='{.status.sync.status}' 2>/dev/null" || echo "Unknown")
  success "ArgoCD Application 'amscams' created (sync: $APP_SYNC)"

  echo ""
  echo "=========================================="
  echo " Setup Complete!"
  echo "=========================================="
  echo ""
  echo " ArgoCD UI:       https://${TARGET_NODE}:30080"
  echo " GitOps repo:     https://github.com/${GITOPS_REPO}"
  echo " Kubeconfig:      ~/.kube/config"
  echo ""
  echo " Next steps:"
  echo "  1. Log into ArgoCD UI and verify the 'amscams' app is Synced"
  echo "  2. Push a new image to GHCR to trigger ArgoCD auto-sync"
  echo ""
}

main "$@"
