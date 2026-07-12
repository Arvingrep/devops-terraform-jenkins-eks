#!/usr/bin/env bash
# eks-lab-smoke-test.sh — post-apply smoke test for the Lab EKS foundation
# (docs/migration-plan.md Phase 4b-1). Exercises the real, already-applied
# cluster: API reachability, node/addon health, then a full dynamic
# provisioning round trip on the gp3 StorageClass (create PVC, mount, write,
# read, delete) and confirms the underlying EBS volume is actually gone —
# not just that the Kubernetes objects were deleted
# (docs/eks-storage-design.md §6: reclaimPolicy=Delete is not a guarantee).
#
# Requires: kubectl configured against the lab cluster (see
# docs/eks-lab-deployment.md), aws CLI with credentials for the same
# account/region, jq not required.
#
# This script never runs terraform. It only reads cluster/AWS state and
# creates/deletes a disposable namespace, Pod, and PVC that it owns.

set -euo pipefail

NAMESPACE="${SMOKE_TEST_NAMESPACE:-smoke-test}"
POD_NAME="smoke-test-pod"
PVC_NAME="smoke-test-pvc"
STORAGE_CLASS="gp3"
TEST_FILE="/data/smoke-test.txt"
TEST_CONTENT="wcd-eks-lab-smoke-test-$(date +%s)"
WAIT_TIMEOUT="180s"
POLL_ATTEMPTS=30
POLL_INTERVAL=5

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
  echo "==> cleanup: deleting namespace ${NAMESPACE} (best effort, does not block the check results above)"
  kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# Fails unless every pod matching the selector in the namespace is Running.
check_all_running() {
  local ns="$1" selector="$2" desc="$3" statuses
  statuses="$(kubectl -n "$ns" get pods -l "$selector" --no-headers 2>/dev/null | awk '{print $3}')"
  [[ -n "$statuses" ]] || fail "$desc: no matching pods found (namespace=$ns selector=$selector)"
  if grep -qv '^Running$' <<<"$statuses"; then
    fail "$desc: not all matching pods are Running -> $(kubectl -n "$ns" get pods -l "$selector" --no-headers)"
  fi
  pass "$desc"
}

echo "==> 1. EKS API reachable"
kubectl cluster-info >/dev/null || fail "kubectl cluster-info failed — API server not reachable"
pass "EKS API reachable"

echo "==> 2. all nodes Ready"
node_lines="$(kubectl get nodes --no-headers)"
[[ -n "$node_lines" ]] || fail "no nodes found"
not_ready="$(awk '$2 != "Ready" {print $1}' <<<"$node_lines")"
[[ -z "$not_ready" ]] || fail "node(s) not Ready: $not_ready"
pass "all nodes Ready"

echo "==> 3. CoreDNS Running"
check_all_running kube-system "k8s-app=kube-dns" "CoreDNS"

echo "==> 4. VPC CNI healthy"
check_all_running kube-system "k8s-app=aws-node" "VPC CNI (aws-node)"

echo "==> 5. EBS CSI controller Running"
check_all_running kube-system "app=ebs-csi-controller" "EBS CSI controller"

echo "==> 6. EBS CSI node pods Running"
check_all_running kube-system "app=ebs-csi-node" "EBS CSI node pods"

trap cleanup EXIT

echo "==> setup: namespace ${NAMESPACE}"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> 8. create PVC on StorageClass=${STORAGE_CLASS}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: 1Gi
EOF

echo "==> 7. deploy minimal test Pod (not a real business app — busybox, mounts the PVC)"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
spec:
  nodeSelector:
    dedicated: system
  tolerations:
    - key: dedicated
      operator: Equal
      value: system
      effect: NoSchedule
  containers:
    - name: smoke
      image: public.ecr.aws/docker/library/busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
  restartPolicy: Never
EOF

echo "==> 9. wait for PVC Bound"
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Bound "pvc/${PVC_NAME}" --timeout="$WAIT_TIMEOUT" \
  || fail "PVC did not reach Bound within ${WAIT_TIMEOUT}"
pass "PVC Bound"

echo "==> 10. wait for Pod Ready (implies the PVC actually mounted)"
kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/${POD_NAME}" --timeout="$WAIT_TIMEOUT" \
  || fail "Pod did not become Ready within ${WAIT_TIMEOUT}"
pass "Pod Running with PVC mounted"

echo "==> 11. write test file"
kubectl -n "$NAMESPACE" exec "$POD_NAME" -- sh -c "echo '${TEST_CONTENT}' > ${TEST_FILE}" \
  || fail "failed to write ${TEST_FILE} in pod"
pass "wrote test file"

echo "==> 12. read test file back"
read_back="$(kubectl -n "$NAMESPACE" exec "$POD_NAME" -- cat "$TEST_FILE")"
[[ "$read_back" == "$TEST_CONTENT" ]] || fail "read-back content mismatch: got '${read_back}', want '${TEST_CONTENT}'"
pass "read test file back, content matches what was written"

echo "==> resolving underlying EBS volume ID before deleting anything"
pv_name="$(kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" -o jsonpath='{.spec.volumeName}')"
[[ -n "$pv_name" ]] || fail "could not determine PV name from PVC ${PVC_NAME}"
volume_id="$(kubectl get pv "$pv_name" -o jsonpath='{.spec.csi.volumeHandle}')"
[[ -n "$volume_id" ]] || fail "could not determine EBS volume ID from PV ${pv_name}"
echo "    PV=${pv_name} EBS volume=${volume_id}"

echo "==> 13. delete Pod and PVC"
kubectl -n "$NAMESPACE" delete pod "$POD_NAME" --wait=true --timeout="$WAIT_TIMEOUT"
kubectl -n "$NAMESPACE" delete pvc "$PVC_NAME" --wait=true --timeout="$WAIT_TIMEOUT"
pass "Pod and PVC deleted"

echo "==> 14. confirm PV deleted (reclaimPolicy=Delete on gp3)"
pv_deleted=false
for ((i = 1; i <= POLL_ATTEMPTS; i++)); do
  if ! kubectl get pv "$pv_name" >/dev/null 2>&1; then
    pv_deleted=true
    break
  fi
  sleep "$POLL_INTERVAL"
done
[[ "$pv_deleted" == true ]] || fail "PV ${pv_name} still present after $((POLL_ATTEMPTS * POLL_INTERVAL))s — reclaim did not complete"
pass "PV ${pv_name} deleted"

echo "==> 15. confirm underlying EBS volume deleted (the actual orphan check, not just the K8s object)"
volume_deleted=false
for ((i = 1; i <= POLL_ATTEMPTS; i++)); do
  state="$(aws ec2 describe-volumes --volume-ids "$volume_id" --query 'Volumes[0].State' --output text 2>/dev/null || echo "gone")"
  if [[ "$state" == "gone" ]]; then
    volume_deleted=true
    break
  fi
  sleep "$POLL_INTERVAL"
done
if [[ "$volume_deleted" != true ]]; then
  fail "EBS volume ${volume_id} still exists after $((POLL_ATTEMPTS * POLL_INTERVAL))s — see docs/eks-storage-design.md §6: reclaimPolicy=Delete does not guarantee no residue, this check exists precisely to catch that"
fi
pass "EBS volume ${volume_id} deleted"

echo
echo "All smoke test checks passed."
