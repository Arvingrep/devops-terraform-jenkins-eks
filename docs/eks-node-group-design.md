# EKS 节点组设计(Node Group Design)

**状态:** 未开始——必须在独立 PR 中完成,且必须先于 `modules/eks` 的实现落地(见 `docs/migration-plan.md` 阶段 4a,门禁阶段 4b)。本文档目前只是占位。

## 本文档需要定义的内容

- 每个节点组(见 `docs/eks-capacity-plan.md` 的容量规划)的 `capacity_type`(on-demand vs spot)与机型/规格选择。
- labels、taints、tolerations 方案,确保 Deployment 与 StatefulSet 被正确隔离到各自该在的节点组上,不会被随意调度到错误的节点类型上(例如 StatefulSet 绝不能落到 spot 节点组)。
- 节点层面的伸缩归属:由 Karpenter 或 Cluster Autoscaler 管理节点数量——这不是 HPA/VPA 的职责,HPA/VPA 只管 Pod 层面(见 `docs/eks-scheduling-standard.md`)。
- Karpenter 与 Cluster Autoscaler 的选型结论,以及理由。

## 依赖

- `docs/eks-capacity-plan.md`(节点组集合本身)
- `docs/eks-scheduling-standard.md`(taints/tolerations 与调度标准要对齐)

详见 `docs/migration-plan.md` 阶段 4a 的完整要求。
