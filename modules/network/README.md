# network module

**Status:** not yet implemented.

Will replace both hand-rolled VPC blocks in `part1-jenkins-from-terraform/vpc.tf` and `part2-cluster-from-terraform-and-jenkins/terraform-for-cluster/vpc.tf`. Interface: `enable_nat_gateway`, `single_nat_gateway`, `enable_vpc_flow_logs`, `availability_zones`, `public_subnet_cidrs`, `private_subnet_cidrs`. Landed in Migration Plan Phase 2.

See `docs/migration-plan.md` for when this is populated and `docs/target-architecture.md` for its intended interface.
