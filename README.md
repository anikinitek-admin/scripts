# Anikinitek Admin - Setup Scripts

## `setup-argocd-standalone.sh`

Brings up K3s + ArgoCD from scratch on any target node via SSH.

```bash
curl -fsSL https://raw.githubusercontent.com/anikinitek-admin/scripts/main/setup-argocd-standalone.sh | \
  TARGET_NODE=164.52.205.18 \
  SSH_KEY=~/.ssh/e2e \
  GH_TOKEN=ghp_xxx \
  bash
```

Full documentation in the script comments.
