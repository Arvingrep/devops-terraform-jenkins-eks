# EKS 调度标准(Scheduling Standard)

**状态:** 未开始——必须在独立 PR 中完成,且必须先于 `modules/eks` 的实现落地(见 `docs/migration-plan.md` 阶段 4a,门禁阶段 4b)。本文档目前只是占位。

## 本文档需要定义的内容

- HPA(Horizontal Pod Autoscaler)负责管理 Pod 副本数量——这是 Pod 层面的伸缩标准。
- VPA(Vertical Pod Autoscaler)第一阶段只开启 Recommendation 模式,不做自动生效(不自动重启/调整 Pod 资源请求)。
- 节点层面的伸缩由 Karpenter 或 Cluster Autoscaler 负责(见 `docs/eks-node-group-design.md`),不属于本文档范围,但调度策略必须和节点组的 taints/tolerations 对齐。
- Deployment 与 StatefulSet 之间的调度隔离标准:用 labels、taints、tolerations 实现,具体取值和 `docs/eks-node-group-design.md` 保持一致。

## 依赖

- `docs/eks-node-group-design.md`(taints/tolerations 的具体取值来源)
- `docs/eks-capacity-plan.md`(节点组集合)

详见 `docs/migration-plan.md` 阶段 4a 的完整要求。
