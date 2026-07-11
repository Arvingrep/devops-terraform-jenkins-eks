# EKS 节点组设计(Node Group Design)

**状态:** 设计已完成,待业务确认 `docs/eks-capacity-plan.md` 里的工作负载假设后再进入 `modules/eks` 实现(阶段 4b)。本文档只做设计,不产生任何 Terraform 代码或 AWS 资源。

节点池集合、容量计算过程见 `docs/eks-capacity-plan.md`;调度策略(HPA/VPA/Karpenter 职责边界、四条禁止项)见 `docs/eks-scheduling-standard.md`。本文档是三者之间"具体怎么配"的落地规格。

---

## 0. 节点编排方式选型:Managed Node Group + Karpenter 混合架构

### 结论

- `system-on-demand`、`stateful-on-demand`(Lab)、`stateful-az-a/b/c`(Prod)——使用 **EKS Managed Node Group**(ASG 语义)。
- `stateless-on-demand`、`stateless-spot`、`batch-spot`——使用 **Karpenter NodePool**。

### 理由

1. **Karpenter 没有传统 ASG 的 min/desired 概念**——它是反应式的:有 Pending Pod 就按 NodePool 的 `requirements` 选型下单,空闲节点按 `consolidationPolicy` 主动回收。这对弹性池(stateless-spot/batch-spot)是优点,但对"必须始终有 N 个节点常驻"的需求(system 组件、stateful 数据类负载)不直接适用,需要额外的 workaround(比如占位 Pod、`karpenter.sh/do-not-disrupt` 注解、禁用 consolidation 的特定 NodePool),反而更复杂、更脆弱。
2. Managed Node Group 原生支持 `min_size`/`desired_size`/`max_size`,并且可以直接把 ASG 绑定到单一可用区子网——这正是 `stateful-az-*` 需要的强 AZ 绑定能力,不需要额外 hack。
3. 用 Managed Node Group 承载 `system-on-demand`,同时天然解决了"Karpenter Controller 不能跑在自己管理的临时节点上"这个问题(见 `docs/eks-scheduling-standard.md` 禁止项 4)——因为 Karpenter Controller 就调度在 Managed Node Group 上,结构上不可能落在它自己创建的 Karpenter 节点上。
4. 弹性池(`stateless-on-demand`/`stateless-spot`/`batch-spot`)用 Karpenter 的价值最大:多机型/多可用区 diversification 降低 Spot 中断相关性、bin-packing 效率高、缩容到 0 是原生能力,不需要额外配置。

### Karpenter vs Cluster Autoscaler

选 **Karpenter**,作为 Karpenter NodePool 管理的三个池子(`stateless-on-demand`/`stateless-spot`/`batch-spot`)的节点层伸缩器。理由:
- 直接对接 EC2 Fleet API,扩容延迟通常比 Cluster Autoscaler(依赖预定义 ASG)更低。
- 原生支持机型多样化(一个 NodePool 可以声明多个 instance family/size,自动挑当前最优/最便宜的),不需要像 CA 那样为每种机型建一个独立 ASG。
- 原生的 Spot 中断处理(通过 EC2 Metadata + Interruption Queue),不强制额外部署 `aws-node-termination-handler`(仍建议部署作为兜底)。
- Cluster Autoscaler 仅作为**备选/回退方案**记录:如果未来 Karpenter 出现无法接受的稳定性问题,`stateless-*`/`batch-spot` 三个池子可以退回到"每种机型一个 Managed Node Group + Cluster Autoscaler"的传统模式,`system-on-demand`/`stateful-*` 不受影响(它们本来就是 Managed Node Group)。

---

## 1. `system-on-demand`

| 项目 | Lab | Production |
|---|---|---|
| 作用 | 集群关键组件:CoreDNS、metrics-server、aws-load-balancer-controller、EBS CSI controller、**Karpenter controller**、ingress controller | 同左 |
| 编排方式 | EKS Managed Node Group | EKS Managed Node Group |
| 实例规格候选 | `m7g.large`(首选)/ `m6i.large`(x86 备选) | 同左 |
| min / desired / max | 1 / 1 / 2 | 3 / 3 / 5 |
| Capacity Type | On-Demand(唯一) | On-Demand(唯一) |
| Labels | `workload-class=system`, `node-lifecycle=on-demand` | 同左 |
| Taints | `dedicated=system:NoSchedule` | 同左 |
| Tolerations(允许调度到此池的工作负载需携带) | `dedicated=system` | 同左 |
| AZ | 单可用区(成本优先) | 三个可用区各至少 1 节点(min=3 天然保证) |
| EBS root volume | 20GiB gp3,加密 | 20GiB gp3,加密 |
| 成本估算 | 1×$59.57/月 ≈ $60/月 | 3×$59.57/月 ≈ $179/月(desired) |
| 故障行为 | 节点故障后 Managed Node Group 自动补充;system 组件的 Deployment 必须配置 `PodDisruptionBudget`(建议 `minAvailable=1`)防止滚动/节点替换时短暂全灭 | 同左,3 节点分布在 3 个可用区,单可用区故障不影响其余两个 |
| 适用工作负载 | CoreDNS、metrics-server、LB controller、EBS CSI controller、ingress controller、**Karpenter controller 本身** | 同左 |

---

## 2. `stateless-on-demand`

| 项目 | Lab | Production |
|---|---|---|
| 作用 | 需要稳定性的无状态负载基线(延迟敏感、启动成本高、不适合被 Spot 中断打断) | 同左 |
| 编排方式 | Karpenter NodePool | Karpenter NodePool |
| 实例规格候选 | `m7g.xlarge`(首选)/ `c7g.xlarge`(计算密集备选)/ `m6i.xlarge`(x86 备选) | 同左 |
| min / desired / max | 0 / 0 / 3 | 1 / 2 / 8 |
| Capacity Type | On-Demand(唯一) | On-Demand(唯一) |
| Labels | `workload-class=stateless`, `node-lifecycle=on-demand` | 同左 |
| Taints | `dedicated=stateless-on-demand:NoSchedule` | 同左 |
| Tolerations | `dedicated=stateless-on-demand` | 同左 |
| AZ | 不绑定,由 Karpenter 按 topology spread 自由分布 | 同左,建议配合 `topologySpreadConstraints` 尽量摊平到多可用区 |
| EBS root volume | 20GiB gp3,加密 | 20GiB gp3,加密 |
| 成本估算 | 通常 $0(min=0,按需触发) | 2×$119.14/月 ≈ $238/月(desired) |
| 故障行为 | 节点丢失后 Pod 在其余节点/新节点重建;无 PV 挂载顾虑 | 同左;min=1 保证故障时至少 1 节点常驻,避免完全冷启动 |
| 适用工作负载 | 对启动延迟/中断敏感、但本身无持久化状态的服务 | 同左 |

---

## 3. `stateless-spot`

| 项目 | Lab | Production |
|---|---|---|
| 作用 | 承载大部分无状态计算与 HPA 弹性峰值,容忍中断 | 同左 |
| 编排方式 | Karpenter NodePool | Karpenter NodePool |
| 实例规格候选(机型多样化,降低 Spot 中断相关性) | `m7g.large/xlarge`、`c7g.large/xlarge`、`m6g.large/xlarge` 混合声明 | 同左,规模更大时再加 `.2xlarge` |
| min / desired / max | 0 / 0 / 5 | 0 / 2 / 8 |
| Capacity Type | Spot(唯一) | Spot(唯一) |
| Labels | `workload-class=stateless`, `node-lifecycle=spot` | 同左 |
| Taints | `dedicated=stateless-spot:NoSchedule` | 同左 |
| Tolerations | `dedicated=stateless-spot` | 同左 |
| AZ | 不绑定,尽量分散以扩大可用 Spot 容量池 | 同左 |
| EBS root volume | 20GiB gp3,加密 | 20GiB gp3,加密 |
| 成本估算 | 通常 $0 | 2×$41.72/月(spot 价)≈ $83/月(desired) |
| 故障行为 | Spot 2 分钟中断通知;工作负载需配置 `PodDisruptionBudget` 与优雅终止(`preStop`/`terminationGracePeriodSeconds`);建议部署 `aws-node-termination-handler` 作为 Karpenter 原生中断处理的兜底 | 同左 |
| 适用工作负载 | 可容忍随时被打断、有多副本冗余的无状态服务;非关键 API;预览/测试流量 | 同左 |

---

## 4. `stateful-on-demand`(Lab)/ `stateful-az-a` `stateful-az-b` `stateful-az-c`(Production)

Production 拆分为 AZ 的评估结论见 `docs/eks-capacity-plan.md` §2。

| 项目 | Lab:`stateful-on-demand`(单池,跨 AZ) | Production:`stateful-az-a`/`-b`/`-c`(三个独立池,每池数值对称) |
|---|---|---|
| 作用 | 承载带 PVC 的有状态负载(数据库、消息队列等) | 同左,但每个池只服务绑定在对应可用区的 PV |
| 编排方式 | EKS Managed Node Group | EKS Managed Node Group ×3(每个池独立 ASG) |
| 实例规格候选 | `r7g.xlarge`(内存优化,首选)/ `m7g.xlarge`(通用备选)/ `r6i.xlarge`(x86 备选) | 同左 |
| min / desired / max | 1 / 1 / 2 | 每池 1 / 1 / 3(三池合计 3 / 3 / 9) |
| Capacity Type | **On-Demand(强制,禁止 Spot)** | **On-Demand(强制,禁止 Spot)** |
| Labels | `workload-class=stateful`, `node-lifecycle=on-demand` | `workload-class=stateful`, `node-lifecycle=on-demand`, `topology.kubernetes.io/zone=<对应可用区>` |
| Taints | `dedicated=stateful-on-demand:NoSchedule` | `dedicated=stateful-az-a:NoSchedule`(`-b`/`-c` 同理) |
| Tolerations | `dedicated=stateful-on-demand`,且**不**携带任何 spot 相关 toleration | `dedicated=stateful-az-<x>`,且**不**携带任何 spot 相关 toleration |
| AZ | 不强制绑定(Lab 接受偶发的 AZ 不匹配风险,见 capacity-plan §2) | **每个池硬绑定单一可用区**(ASG 子网只包含该可用区),从结构上保证补充节点永远落在正确可用区 |
| EBS root volume | 50GiB gp3,加密(比其他池更大,预留数据类工作负载的本地临时/日志空间) | 同左 |
| 成本估算 | 1×$147.17/月 ≈ $147/月 | 每池 1×$147.17/月,三池合计 desired ≈ $441/月 |
| 故障行为 | 节点故障后,若替换节点落在错误可用区,对应 Pod 会卡在 `Pending`,需人工介入(接受的已知风险,见 capacity-plan §2) | 因 AZ 硬绑定,替换节点必然落在正确可用区,Pod 可自动恢复;跨 AZ 的其余两个 stateful 副本(如果应用层做了跨 AZ 复制)不受影响 |
| 适用工作负载 | 任何带 PVC 的 StatefulSet:自建数据库、Kafka/Redis 等 | 同左 |

**结构性禁止 Spot:** 三个 stateful 相关池子都不声明任何 `capacity-type=spot` 的 NodePool/ASG,且对应 StatefulSet 的 tolerations 里绝不出现 spot 相关 taint 的容忍——即使运维误操作也无法把 StatefulSet 调度到 spot 节点上。

---

## 5. `batch-spot`

| 项目 | Lab | Production |
|---|---|---|
| 作用 | 批处理、定时任务、CI/ML 训练等可重试/可中断负载 | 同左 |
| 编排方式 | Karpenter NodePool | Karpenter NodePool |
| 实例规格候选 | `m7g.2xlarge`、`c7g.2xlarge` 混合声明 | 同左,规模更大时再加 `.4xlarge` |
| min / desired / max | 0 / 0 / 2 | 0 / 0 / 6 |
| Capacity Type | Spot(唯一) | Spot(唯一) |
| Labels | `workload-class=batch`, `node-lifecycle=spot` | 同左 |
| Taints | `dedicated=batch-spot:NoSchedule` | 同左 |
| Tolerations | `dedicated=batch-spot` | 同左 |
| AZ | 不绑定 | 同左 |
| EBS root volume | 30GiB gp3,加密 | 30GiB gp3,加密 |
| 成本估算 | 通常 $0 | 通常 $0(desired=0,纯按需) |
| 故障行为 | 依赖 Kubernetes Job 的 `backoffLimit` 重试;长任务建议实现 checkpoint,避免中断后从头重跑 | 同左 |
| 适用工作负载 | 夜间 ETL、报表生成、CI 测试 runner、可重跑的批处理/训练任务 | 同左 |

---

## 6. labels/taints/tolerations 速查表

| 节点池 | Label(`dedicated=`) | Taint | 允许调度的工作负载类型 |
|---|---|---|---|
| `system-on-demand` | `system` | `dedicated=system:NoSchedule` | 集群组件 Deployment |
| `stateless-on-demand` | `stateless-on-demand` | `dedicated=stateless-on-demand:NoSchedule` | 稳定性优先的 Deployment |
| `stateless-spot` | `stateless-spot` | `dedicated=stateless-spot:NoSchedule` | 容忍中断的 Deployment |
| `stateful-on-demand` / `stateful-az-*` | `stateful-on-demand` / `stateful-az-a` / `-b` / `-c` | 对应 `:NoSchedule` | StatefulSet(带 PVC) |
| `batch-spot` | `batch-spot` | `dedicated=batch-spot:NoSchedule` | Job/CronJob |

设计原则:**每个池都打 taint,每个工作负载都必须显式携带对应 toleration + nodeSelector/nodeAffinity**——不依赖"默认落到某个池"的隐式行为,保证调度结果可预测、成本可按池归因、容量计算(`docs/eks-capacity-plan.md`)里"负载 vs 节点池"的对应关系始终成立。
