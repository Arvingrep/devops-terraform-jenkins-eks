# EKS 容量规划(Capacity Plan)

**状态:** 未开始——必须在独立 PR 中完成,且必须先于 `modules/eks` 的实现落地(见 `docs/migration-plan.md` 阶段 4a,门禁阶段 4b)。本文档目前只是占位。

## 本文档需要定义的内容

- 节点组集合,至少包括:
  - `system-on-demand`
  - `stateless-on-demand`
  - `stateless-spot`
  - `stateful-on-demand`
  - `batch-spot`
- Production 环境的 Stateful 节点是否需要按可用区拆分为 `stateful-az-a`/`stateful-az-b`/`stateful-az-c`——需要给出评估结论(是/否,以及为什么),不能默认照抄 Lab 的方案。
- 每类节点组大致的规模范围(min/max/desired)、成本量级,按 Lab/Prod 分别给出。

## 依赖

- `docs/eks-node-group-design.md`(节点组具体规格、labels/taints/tolerations)
- `docs/eks-scheduling-standard.md`(谁负责节点层伸缩)

详见 `docs/migration-plan.md` 阶段 4a 的完整要求。
