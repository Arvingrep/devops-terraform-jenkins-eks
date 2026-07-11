#!/usr/bin/env bash
# infra.sh — thin, guarded wrapper around Terraform for a given environment.
#
# Usage:
#   ./scripts/infra.sh <lab|staging|prod> <plan|apply|destroy>
#
# This script never runs `apply` or `destroy` without a human present:
#   - `apply` always runs as a normal (non -auto-approve) apply.
#   - `destroy` always shows a plan first and requires typing the exact
#     confirmation phrase before proceeding (requirements §10.3).
# It refuses to run against an environment directory that has no real
# Terraform content yet, instead of failing with a confusing init error.

set -euo pipefail

usage() {
  echo "Usage: $0 <lab|staging|prod> <plan|apply|destroy>" >&2
  exit 1
}

[[ $# -eq 2 ]] || usage

env="$1"
action="$2"

case "$env" in
  lab|staging|prod) ;;
  *) echo "error: unknown environment '$env' (expected lab, staging, or prod)" >&2; exit 1 ;;
esac

case "$action" in
  plan|apply|destroy) ;;
  *) echo "error: unknown action '$action' (expected plan, apply, or destroy)" >&2; exit 1 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_dir="$repo_root/environments/$env"

if [[ ! -d "$env_dir" ]]; then
  echo "error: $env_dir does not exist yet." >&2
  exit 1
fi

if [[ ! -f "$env_dir/main.tf" ]] || ! grep -qE '^\s*module\s+"' "$env_dir/main.tf" 2>/dev/null; then
  cat >&2 <<EOF
error: environments/$env has no module calls wired up yet (main.tf is a
placeholder). There is nothing real to $action.

See docs/migration-plan.md for which phase populates this environment.
EOF
  exit 1
fi

if [[ ! -f "$env_dir/terraform.tfvars" ]]; then
  echo "error: environments/$env/terraform.tfvars not found." >&2
  echo "Copy terraform.tfvars.example to terraform.tfvars and fill in real values first." >&2
  exit 1
fi

cd "$env_dir"

if [[ "$env" == "prod" && "$action" != "plan" ]]; then
  cat >&2 <<'EOF'
error: this script only ever runs `plan` for environments/prod.
Production apply/destroy is a human-approved action outside this script
(requirements §10.4) — see docs/deployment.md.
EOF
  exit 1
fi

terraform init

case "$action" in
  plan)
    terraform plan
    ;;
  apply)
    terraform plan -out=tfplan
    terraform apply tfplan
    rm -f tfplan
    ;;
  destroy)
    echo "==> Generating destroy plan for '$env' ..."
    terraform plan -destroy
    echo
    read -r -p "Type 'destroy-${env}' to confirm you want to destroy this environment: " confirm
    if [[ "$confirm" != "destroy-${env}" ]]; then
      echo "Confirmation did not match. Aborting, nothing was destroyed." >&2
      exit 1
    fi
    terraform destroy
    ;;
esac
