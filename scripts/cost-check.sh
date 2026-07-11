#!/usr/bin/env bash
# cost-check.sh — placeholder for Infracost integration (requirements §9).
#
# Per requirements: "建议集成 Infracost，但不能因为 Infracost 不可用而阻塞基础
# Terraform 验证" — this script must never be a hard CI gate. It's a no-op
# until an environment has real module calls to estimate.

set -euo pipefail

if ! command -v infracost >/dev/null 2>&1; then
  echo "cost-check.sh: infracost not installed locally — skipping (non-blocking)." >&2
  exit 0
fi

echo "cost-check.sh: no environment has real module calls yet, nothing to estimate." >&2
exit 0
