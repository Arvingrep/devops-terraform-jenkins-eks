# smoke tests

**Status:** `eks-lab-smoke-test.sh` implemented (Migration Plan Phase 4b-1). Jenkins smoke checks remain not yet implemented (Phase 3, `modules/jenkins`).

## eks-lab-smoke-test.sh

Post-apply check for the Lab EKS foundation. Requires `kubectl` configured against the lab cluster and `aws` CLI credentials for the same account/region (neither is available in this development environment — this script has been written and syntax-checked but **not run against a real cluster**, since none has been applied). Covers, in order:

1. EKS API reachable
2. All nodes Ready
3. CoreDNS Running
4. VPC CNI healthy
5. EBS CSI controller Running
6. EBS CSI node pods Running
7. Deploy a minimal test Pod (busybox, not a real application)
8. Create a PVC on the `gp3` StorageClass
9. PVC reaches Bound
10. Pod reaches Ready (implies the PVC actually mounted)
11. Write a test file
12. Read the test file back, verify content matches
13. Delete the Pod and PVC
14. Confirm the PV was deleted
15. Confirm the underlying EBS volume was actually deleted (not just the Kubernetes object — `docs/eks-storage-design.md` §6)

Invoke directly: `./tests/smoke/eks-lab-smoke-test.sh`. `scripts/smoke-test.sh` calls this for `lab`; Jenkins smoke checks there remain a placeholder until `modules/jenkins` lands.
