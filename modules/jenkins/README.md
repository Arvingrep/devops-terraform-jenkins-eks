# jenkins module

**Status:** not yet implemented.

Will replace `part1-jenkins-from-terraform/*`. Fixes required before this lands: no public SSH/8080, IMDSv2, encrypted EBS (root + dedicated data volume), scoped IAM instance profile, no plaintext secrets in user-data. Landed in Migration Plan Phase 3.

See `docs/migration-plan.md` for when this is populated and `docs/target-architecture.md` for its intended interface.
