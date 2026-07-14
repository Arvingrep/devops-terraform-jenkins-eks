# environments/lab/k8s/jenkins

Kubernetes-layer objects for the Lab's Jenkins controller — applied via `kubectl` directly, **not** Terraform.

## Why not Terraform

HCP Terraform's remote runners can't reliably reach this cluster's private-only API endpoint (`endpoint_public_access=false` in `modules/eks`). A real apply attempt failed with `dial tcp ...: connect: network is unreachable`. The AWS-layer resources these manifests depend on (EFS filesystem, mount targets, Fargate profile, IAM) *are* Terraform-managed, in `modules/jenkins` — only the Kubernetes API objects themselves are applied this way, from an environment with real VPC/cluster network access.

## Apply order

```bash
kubectl apply -f 00-namespaces.yaml
kubectl apply -f 01-storage.yaml       # PV references the real EFS filesystem ID — update it if modules/jenkins is ever re-applied to a fresh filesystem
kubectl apply -f 02-rbac.yaml

# Admin credentials — generated here, never committed:
kubectl -n jenkins create secret generic jenkins-admin-credentials \
  --from-literal=username=admin \
  --from-literal=password="$(openssl rand -base64 24)"
# Save the password shown by:
kubectl -n jenkins get secret jenkins-admin-credentials -o jsonpath='{.data.password}' | base64 -d; echo

kubectl apply -f 03-casc-config.yaml
kubectl apply -f 04-plugins.yaml
kubectl apply -f 05-deployment.yaml

kubectl -n jenkins rollout status deployment/jenkins --timeout=5m

# Optional: public access (see 06-public-service.yaml)
kubectl apply -f 06-public-service.yaml
```

## Access

Internal (always available), via port-forward:

```bash
kubectl -n jenkins port-forward svc/jenkins 8080:8080
# http://localhost:8080
```

Public (optional, `06-public-service.yaml`): a `LoadBalancer` Service provisions a real AWS ELB. This Lab was reached at `jenkins.dfdfs.me` via an externally-managed CNAME pointed at the ELB's hostname — HTTP only, no TLS yet (flagged as a follow-up in that manifest's comments). No Route53 zone exists in this account for that domain, so the CNAME is created outside Terraform by whoever controls it.

## Architecture

- **Controller**: `jenkins/jenkins:lts-jdk17`, one replica, on the regular EKS system node group (same taint/toleration as every other system-pool workload) — needs to always be up whenever the Lab is on, and needs the EFS PVC.
- **Jenkins Home**: EFS-backed PV/PVC, `reclaimPolicy: Retain` — deleting the PVC/PV never deletes the underlying EFS filesystem (Terraform's `modules/jenkins` owns that lifecycle). This is the one thing in this Lab that's meant to survive a full teardown (AWS Lab OS v2 §3/§5).
- **Plugins**: an `install-plugins` initContainer in `05-deployment.yaml` runs `jenkins-plugin-cli` against `04-plugins.yaml`'s `plugins.txt` on every Pod start, installing directly into `$JENKINS_HOME/plugins` (the EFS volume). Found via a real deployment attempt that the official `jenkins/jenkins` image no longer auto-installs from a mounted `plugins.txt` on its own — this replaces that removed mechanism. The cli is idempotent, so already-installed plugins persisting on EFS aren't re-downloaded.
- **Configuration**: JCasC (`03-casc-config.yaml`) defines the security realm (single local admin user, credentials from the Secret above) and the Kubernetes Cloud (Fargate agent template, `jenkins-agents` namespace) — no manual UI setup needed.
- **Agents**: dynamically provisioned by the Kubernetes plugin into `jenkins-agents`, which `modules/jenkins`'s Fargate profile selects — ephemeral, zero idle cost, no persistence.

## Recovery

If the controller Pod is deleted/recreated (node replacement, `kubectl rollout restart`, etc.), it re-mounts the same EFS-backed PV and resumes with all prior configuration, credentials, job history, and plugins intact — nothing here needs to be re-applied except in this exact order if the whole namespace is deleted.
