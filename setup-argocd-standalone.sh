#!/bin/bash
set -euo pipefail

#==============================================================================
# ArgoCD Standalone Setup Script
# Reusable script to bring up K3s + ArgoCD from scratch on any target node
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/anikinitek-admin/scripts/main/setup-argocd-standalone.sh | \
#     TARGET_NODE=<IP> SSH_KEY=~/.ssh/e2e GH_TOKEN=<PAT> bash
#
# Prerequisites:
#   - Ubuntu/Debian target node with SSH access
#   - GitHub PAT with repo scope
#   - Docker pre-installed on target node
#==============================================================================

TARGET_NODE="${TARGET_NODE:-}"
SSH_KEY="${SSH_KEY:-~/.ssh/e2e}"
GH_TOKEN="${GH_TOKEN:-}"
GITOPS_REPO="anikinitek-admin/amscams-gitops"
ARGOCD_NAMESPACE="argocd"
ARGOCD_VERSION="v2.12.3"
K3S_VERSION="v1.34.6+k3s1"
KUBECONFIG_REMOTE="/etc/rancher/k3s/k3s.yaml"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --target)      TARGET_NODE="$2"; shift 2 ;;
    --ssh-key)    SSH_KEY="$2"; shift 2 ;;
    --gh-token)   GH_TOKEN="$2"; shift 2 ;;
    --skip-k3s)   SKIP_K3S=1; shift ;;
    --skip-argocd) SKIP_ARGOCD=1; shift ;;
    --skip-gitops) SKIP_GITOPS=1; shift ;;
    --help)
      echo "Usage: $0 --target <IP> --ssh-key <path> --gh-token <PAT>"
      echo "All options as env vars: TARGET_NODE, SSH_KEY, GH_TOKEN"
      exit 0 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$TARGET_NODE" ]] && { error "TARGET_NODE required"; exit 1; }
[[ -z "$GH_TOKEN" ]]   && { error "GH_TOKEN required";   exit 1; }
[[ ! -f "$SSH_KEY" ]]  && { error "SSH key not found: $SSH_KEY"; exit 1; }

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i $SSH_KEY"
run() { ssh $SSH_OPTS "root@${TARGET_NODE}" "$@"; }
wait_for() {
  local desc=$1; local timeout=${2:-120}; local interval=${3:-5}; local cmd=$4
  local elapsed=0
  while ! eval "$cmd" &>/dev/null; do
    elapsed=$((elapsed + interval))
    if ((elapsed >= timeout)); then error "$desc timed out"; return 1; fi
    sleep "$interval"
  done
  return 0
}

main() {
  echo ""
  echo "=========================================="
  echo " ArgoCD Standalone Setup"
  echo " Target: $TARGET_NODE"
  echo "=========================================="
  echo ""

  info "Checking SSH connectivity..."
  run "echo ok" | grep -q ok && success "SSH OK" || { error "Cannot SSH to $TARGET_NODE"; exit 1; }

  # K3s
  if [[ "${SKIP_K3S:-}" != "1" ]]; then
    info "Checking existing K3s..."
    if run "[[ -f /usr/local/bin/k3s ]] && [[ -f $KUBECONFIG_REMOTE ]]" 2>/dev/null; then
      STATUS=$(run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl get nodes -o jsonpath='{.items[0].status.phase}'" 2>/dev/null || echo "notready")
      if [[ "$STATUS" == "Ready" ]]; then
        success "K3s already running, skipping"
        SKIP_K3S=1
      fi
    fi
  fi

  if [[ "${SKIP_K3S:-}" != "1" ]]; then
    info "Installing K3s $K3S_VERSION..."
    run "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - server --cluster-init --tls-san $TARGET_NODE --disable traefik --disable servicelb --node-label node=primary"
    wait_for "K3s API" 120 "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl get nodes -o jsonpath='{.items[0].status.phase}' | grep -q Ready"
    success "K3s cluster up"
  fi

  # kubeconfig
  info "Saving kubeconfig to ~/.kube/config..."
  mkdir -p ~/.kube
  run "cat $KUBECONFIG_REMOTE" > ~/.kube/config
  success "kubeconfig saved"

  # ArgoCD
  if [[ "${SKIP_ARGOCD:-}" != "1" ]]; then
    info "Checking ArgoCD..."
    if run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl get ns $ARGOCD_NAMESPACE -o jsonpath='{.metadata.name}'" 2>/dev/null | grep -q "^$ARGOCD_NAMESPACE$"; then
      if run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl get pods -n $ARGOCD_NAMESPACE -o jsonpath='{.items[*].status.phase}'" 2>/dev/null | grep -q Running; then
        success "ArgoCD already healthy"
        SKIP_ARGOCD=1
      fi
    fi
  fi

  if [[ "${SKIP_ARGOCD:-}" != "1" ]]; then
    info "Installing ArgoCD $ARGOCD_VERSION..."
    run "curl -fsSL -o /tmp/argocd-install.yaml https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
    run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl create ns $ARGOCD_NAMESPACE 2>/dev/null || true"
    run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl apply -f /tmp/argocd-install.yaml -n $ARGOCD_NAMESPACE"
    run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl patch svc argocd-server -n $ARGOCD_NAMESPACE -p '{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":443,\"targetPort\":8080,\"nodePort\":30080}]}}' 2>/dev/null || true"
    wait_for "ArgoCD pods" 180 "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl get pods -n $ARGOCD_NAMESPACE -o jsonpath='{.items[*].status.phase}' | grep -q 'Running.*Running.*Running.*Running.*Running.*Running.*Running'"
    success "ArgoCD up"
  fi

  # ArgoCD GitHub repo connection
  info "Connecting ArgoCD to GitHub..."
  run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl create secret generic github-creds -n $ARGOCD_NAMESPACE --from-literal=username=anikinitek-admin --from-literal=password=$GH_TOKEN --type=Opaque 2>/dev/null || true"
  run "curl -fsSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64 && chmod +x /usr/local/bin/argocd"
  wait_for "ArgoCD API" 60 "curl -sk https://localhost:30080/info 2>/dev/null | grep -q version"
  ARGOCD_PWD=$(run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d")
  run "/usr/local/bin/argocd login localhost:30080 --username admin --password $ARGOCD_PWD --insecure --grpc-web 2>/dev/null || true"
  run "/usr/local/bin/argocd repo add https://github.com/${GITOPS_REPO}.git --username anikinitek-admin --password $GH_TOKEN --insecure --grpc-web 2>/dev/null || true"
  success "GitHub repo connected"

  # ArgoCD Application
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
  sleep 5
  SYNC_STATUS=$(run "export KUBECONFIG=$KUBECONFIG_REMOTE; kubectl get application amscams -n argocd -o jsonpath='{.status.sync.status}'" 2>/dev/null || echo "Unknown")
  success "Application created (sync: $SYNC_STATUS)"

  echo ""
  echo "=========================================="
  echo " Setup Complete!"
  echo "=========================================="
  echo " ArgoCD UI:  https://${TARGET_NODE}:30080"
  echo " Kubeconfig: ~/.kube/config"
  echo " Password:   $ARGOCD_PWD"
  echo ""
}

main "$@"
