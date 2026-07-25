# GitOps

## Overview

A self-managing Kubernetes platform, defined entirely in Git. Argo CD runs inside the cluster
and continuously reconciles its state to match this repository, so application workloads, TLS,
secrets and the supporting controllers are all pulled from Git rather than applied by hand.

The reference workload is [Linkding](https://github.com/sissbruecker/linkding), a self-hosted
bookmark manager, deployed with persistence, a sealed secret and HTTPS.

Concretely, that means:

- **GitOps delivery**: an Argo CD app-of-apps setup, so the cluster reconstructs itself from this repo.
- **Declarative platform**: ingress, TLS issuance and secret management are resources in Git, not manual steps.
- **Encrypted secrets in Git**: Sealed Secrets commits credentials in encrypted form with no plaintext in the repo.
- **Reproducibility**: one bootstrap script and [one documented manual step](#sealed-secrets-on-a-fresh-cluster) rebuild the whole platform on a fresh cluster.

## Architecture

![Architecture](https://raw.githubusercontent.com/arjnbli/project-media/refs/heads/main/gitops/architecture.png)

## Repository Layout

```
bootstrap/   root Application + bootstrap script
argocd/      child Application manifests (one per platform component/app)
apps/        application workloads
```

## Platform Components

| Component | Role | Why |
|---|---|---|
| **k3d** | Local Kubernetes (k3s in Docker) | Lightweight, multi-node, ingress-friendly and closer to real k8s than Minikube |
| **Argo CD** | GitOps continuous delivery | Pull-based in-cluster reconciliation |
| **Kustomize** | Manifest management | Base/overlay model maps cleanly to per-environment differences |
| **Traefik** | Ingress controller | Ships with k3d and is actively maintained, unlike ingress-nginx, which was [retired in 2025](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/) |
| **cert-manager** | TLS certificate automation | Declarative issuance and renewal |
| **Sealed Secrets** | Secret encryption for Git | Commits credentials in encrypted form, decrypted in-cluster by a controller |

## Prerequisites

Local CLI tools: `k3d`, `helm`, `kubectl`, `kubeseal`.

## Operating the Platform

### Bootstrap

```bash
./bootstrap/init.sh
```

This idempotent script sets up the platform in three steps:

1. Creates the k3d cluster (host ports 80/443 mapped to the loadbalancer) if it does not exist.
2. Installs Argo CD if it is not already present.
3. Applies the root Application, which in turn creates the child applications.

Argo CD then brings the platform up in dependency order. Sealed Secrets and cert-manager carry
sync wave `-1` so they are healthy before Linkding, which syncs on wave `0`. This ordering is
necessary because Linkding's `SealedSecret` and `Issuer` resources depend on CRDs those two
controllers install.

### Sealed Secrets on a Fresh Cluster

The committed `sealed-secret.yaml` is encrypted against a specific cluster's Sealed Secrets
key, which does not survive cluster deletion. On a fresh cluster the uncommitted plaintext
secret has to be re-sealed against the new key:

```bash
kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets \
  --format yaml \
  < apps/linkding/overlays/local/secret.yaml \
  > apps/linkding/overlays/local/sealed-secret.yaml
git commit -am "chore: re-seal secret for new cluster key" && git push
```

Argo CD then reconciles the new sealed value and Linkding starts. `secret.yaml` (the plaintext
source) is gitignored, and `secret.example.yaml` documents its shape.

### Access

Argo CD UI:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Linkding: `https://linkding.localhost` (self-signed certificate, so the browser warning is
expected locally).

### Rebuilding From Scratch

Destroying the cluster and pointing a new one at this repository reproduces the same platform,
in line with GitOps principles.

```bash
k3d cluster delete gitops        # destroy everything
./bootstrap/init.sh              # cluster + Argo CD + root app
# re-seal the secret against the new cluster key, see above
```

The controllers, Linkding, its TLS certificate and its ingress route all return without further
intervention, because none of them were ever created by hand.

## Decisions and Tradeoffs

### Single Replica and Durability

The Linkding image defaults to SQLite, so its state lives in a single database file on disk.
As a single-user bookmark manager, it needs that file persisted but has no need for concurrent
access or high availability. Given these requirements, the default is kept and the app runs as
a single replica backed by a `local-path` volume.

A `local-path` volume ties the data to a node's disk, so it does not survive the node being
lost. An EBS-backed volume, being durable and snapshottable, would keep the bookmarks across
node failure and allow backups, with the single-replica setup otherwise unchanged. That is
left for the [roadmap](#roadmap).

### Config vs. State: What Git Reproduces and What It Doesn't

Git holds the desired configuration: Deployments, Services, the PVC request and the sealed
credential. It does not hold application state. The bookmarks and users written to Linkding's
database live in the volume, and the volume's contents never enter Git.

A rebuild therefore brings back an identical, empty Linkding. The bootstrap superuser is
recreated from the sealed credential, but the bookmarks are not, because they were never in
Git to begin with. This is the intended boundary. Reproducing the setup and preserving the
data are separate problems, and carrying data across rebuilds is left for the [roadmap](#roadmap).

### The Secret-Bootstrap Problem

Under GitOps every piece of cluster state is meant to come from Git, and secret management is
where that breaks down. A credential cannot be committed in plaintext, so it needs to reach
the cluster some other way. Sealed Secrets fits a local, self-contained cluster. It needs
nothing outside the cluster to work, encrypting the credential into a form safe to commit and
decrypting it back with a controller that runs alongside everything else.

That controller owns a key pair, created when it is installed and gone when the cluster is.
The encrypting half produces the committed secret. The decrypting half never leaves the
cluster. On a rebuild the key pair is new, so Deployments, Services and the rest of the state
return from Git while the credential does not, and it has to be re-sealed against the fresh
key before Linkding can read it.

A rebuild that comes entirely from Git, with no re-sealing, is achievable with External
Secrets Operator. The secret lives in a managed store such as AWS Secrets Manager, Git holds
only a reference to it, and a controller fetches it into the cluster. That is left for the
[roadmap](#roadmap).

## Roadmap

Upgrades being explored:

- [ ] Secrets via External Secrets Operator (AWS Secrets Manager) instead of Sealed Secrets, so a rebuild needs no re-sealing.
- [ ] An EKS cluster provisioned with Terraform, with a real domain and a Let's Encrypt issuer.
- [ ] An EBS-backed volume in place of `local-path`, durable and snapshottable so data survives node loss and, with a `Retain` reclaim policy, can be carried across rebuilds.
