#!/usr/bin/env bash
# validate.sh — static checks only. No AWS credentials required, no state
# touched. Mirrors what .github/workflows/terraform-check.yml runs in CI, so
# it can be run locally before opening a PR (requirements §10.1).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "==> terraform fmt -check -recursive"
terraform fmt -check -recursive -diff

status=0

dirs="$(find . -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; | sort -u)"

while IFS= read -r dir; do
  [[ -n "$dir" ]] || continue
  echo
  echo "==> terraform validate: ${dir#./}"
  init_out="$(cd "$dir" && terraform init -backend=false -input=false 2>&1)" && init_rc=0 || init_rc=$?
  if [[ $init_rc -ne 0 ]]; then
    if grep -q "Unsupported Terraform Core version" <<<"$init_out"; then
      echo "skipped: local $(terraform version | head -1) does not satisfy this directory's required_version. CI uses the pinned version from .terraform-version instead."
    else
      echo "$init_out" >&2
      status=1
    fi
    continue
  fi
  (cd "$dir" && terraform validate) || status=1
done <<<"$dirs"

if command -v tflint >/dev/null 2>&1; then
  echo
  echo "==> tflint"
  tflint --recursive || status=1
else
  echo
  echo "==> tflint not installed locally, skipping (CI still runs it)"
fi

if command -v tfsec >/dev/null 2>&1; then
  echo
  echo "==> tfsec"
  tfsec . --no-color || true
else
  echo
  echo "==> tfsec not installed locally, skipping (CI still runs it)"
fi

exit $status
