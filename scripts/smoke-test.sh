#!/usr/bin/env bash
# smoke-test.sh — placeholder.
#
# Will check Jenkins reachability and EKS API/node readiness after a lab
# apply (requirements §10.2), invoked from the future lab-apply.yml
# workflow. Nothing to smoke-test until modules/jenkins and modules/eks
# land (docs/migration-plan.md Phase 3/4).

set -euo pipefail
echo "smoke-test.sh: not yet implemented — no deployed lab resources to check yet." >&2
exit 1
