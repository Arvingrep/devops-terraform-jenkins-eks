# eks module

**Status:** not yet implemented.

Wraps `terraform-aws-modules/eks/aws` with a supported Kubernetes version, IRSA/OIDC, restricted endpoint CIDRs, control-plane logging, selectable node `capacity_type`. Landed in Migration Plan Phase 4b.

**Blocked on Phase 4a:** no code lands here until `docs/eks-capacity-plan.md`, `docs/eks-node-group-design.md`, `docs/eks-scheduling-standard.md`, and `docs/eks-storage-design.md` are merged (currently placeholders). Node group set, HPA/VPA/Karpenter boundaries, Deployment/StatefulSet isolation, and storage class defaults must come from those docs, not be decided ad hoc during implementation.

See `docs/migration-plan.md` for when this is populated and `docs/target-architecture.md` for its intended interface.
