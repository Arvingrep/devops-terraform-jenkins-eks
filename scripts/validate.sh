#!/usr/bin/env bash
# validate.sh — static checks only. No AWS credentials required, no state
# touched. Mirrors what .github/workflows/terraform-check.yml runs in CI, so
# it can be run locally before opening a PR (requirements §10.1).
#
# Same legacy/new split as CI: failures under LEGACY_DIRS are printed but
# never fail this script's exit code (known pre-existing debt, see
# docs/current-state-assessment.md); failures under NEW_DIRS do fail it.
# Don't read a clean exit code here as "all Terraform in this repo is
# clean" — read the per-check output.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

LEGACY_DIRS=(
  "part1-jenkins-from-terraform"
  "part2-cluster-from-terraform-and-jenkins/terraform-for-cluster"
)
NEW_TOP_DIRS=("modules" "environments" "bootstrap")

is_legacy_dir() {
  local d="$1"
  for legacy in "${LEGACY_DIRS[@]}"; do
    [[ "$d" == "$legacy" ]] && return 0
  done
  return 1
}

echo "==> terraform fmt -check -recursive"
terraform fmt -check -recursive -diff

status=0

dirs="$(find . -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; | sort -u)"

while IFS= read -r dir; do
  [[ -n "$dir" ]] || continue
  dir="${dir#./}"
  legacy_tag=""
  is_legacy_dir "$dir" && legacy_tag=" [legacy, non-blocking]"
  echo
  echo "==> terraform validate:${legacy_tag} ${dir}"
  init_out="$(cd "$dir" && terraform init -backend=false -input=false 2>&1)" && init_rc=0 || init_rc=$?
  if [[ $init_rc -ne 0 ]]; then
    if grep -q "Unsupported Terraform Core version" <<<"$init_out"; then
      echo "skipped: local $(terraform version | head -1) does not satisfy this directory's required_version. CI uses the pinned version from .terraform-version instead."
    else
      echo "$init_out" >&2
      is_legacy_dir "$dir" || status=1
    fi
    continue
  fi
  if ! (cd "$dir" && terraform validate); then
    is_legacy_dir "$dir" || status=1
  fi
done <<<"$dirs"

if command -v tflint >/dev/null 2>&1; then
  echo
  echo "==> tflint [new, blocking]: ${NEW_TOP_DIRS[*]}"
  for d in "${NEW_TOP_DIRS[@]}"; do
    tflint --recursive --chdir="$d" --config="$repo_root/.tflint.hcl" || status=1
  done
  echo
  echo "==> tflint [legacy, non-blocking]: ${LEGACY_DIRS[*]}"
  for d in "${LEGACY_DIRS[@]}"; do
    tflint --chdir="$d" --config="$repo_root/.tflint.hcl" || true
  done
else
  echo
  echo "==> tflint not installed locally, skipping (CI still runs it)"
fi

if command -v tfsec >/dev/null 2>&1; then
  echo
  echo "==> tfsec [new, blocking on HIGH/CRITICAL]: ${NEW_TOP_DIRS[*]}"
  for d in "${NEW_TOP_DIRS[@]}"; do
    tfsec "$d" --minimum-severity HIGH --no-color || status=1
  done
  echo
  echo "==> tfsec [legacy, non-blocking]: ${LEGACY_DIRS[*]}"
  for d in "${LEGACY_DIRS[@]}"; do
    tfsec "$d" --no-color || true
  done
else
  echo
  echo "==> tfsec not installed locally, skipping (CI still runs it)"
fi

exit $status
