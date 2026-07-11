# EKS 存储设计(Storage Design)

**状态:** 未开始——必须在独立 PR 中完成,且必须先于 `modules/eks` 的实现落地(见 `docs/migration-plan.md` 阶段 4a,门禁阶段 4b)。本文档目前只是占位。

## 本文档需要定义的内容

- PVC 默认 StorageClass 使用 `gp3`。
- Production 环境的重要数据,回收策略(reclaim policy)使用 `Retain`(避免 PVC/PV 被删除时数据跟着丢失)。
- EBS StorageClass 的 `volumeBindingMode` 使用 `WaitForFirstConsumer`(避免 Pod 还没调度、卷就已经绑定到错误可用区)。
- 启用 EBS CSI driver、Volume Expansion、加密(EBS 卷本身的静态加密)。
- StatefulSet 禁止运行在 Spot 节点上——存储设计必须和 `docs/eks-node-group-design.md`/`docs/eks-capacity-plan.md` 的 `stateful-on-demand`(以及可能的 `stateful-az-*`)节点组保持一致。

## 依赖

- `docs/eks-capacity-plan.md`(哪些节点组承载 stateful 工作负载)
- `docs/eks-node-group-design.md`(taints/tolerations,确保 StatefulSet 只会落到允许的节点组)

详见 `docs/migration-plan.md` 阶段 4a 的完整要求。
