#!/usr/bin/env bash
# smoke-test.sh — post-apply smoke checks for a given environment, invoked
# from the future lab-apply.yml workflow (requirements §10.2).
#
# Usage:
#   ./scripts/smoke-test.sh <lab|staging|prod>

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "Usage: $0 <lab|staging|prod>" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
env="$1"

case "$env" in
  lab)
    echo "==> EKS smoke test (modules/eks, Phase 4b-1)"
    "$repo_root/tests/smoke/eks-lab-smoke-test.sh"
    echo
    echo "==> Jenkins smoke test: not yet implemented — modules/jenkins hasn't landed (docs/migration-plan.md Phase 3)." >&2
    ;;
  staging|prod)
    echo "smoke-test.sh: not yet implemented for '$env' — no deployed resources to check yet." >&2
    exit 1
    ;;
  *)
    echo "error: unknown environment '$env' (expected lab, staging, or prod)" >&2
    exit 1
    ;;
esac
