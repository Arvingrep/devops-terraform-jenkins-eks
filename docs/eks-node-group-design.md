# EKS 节点组设计(Node Group Design)

**状态:** 设计已完成,待业务确认 `docs/eks-capacity-plan.md` 里的工作负载假设后再进入 `modules/eks` 实现(阶段 4b)。本文档只做设计,不产生任何 Terraform 代码或 AWS 资源。

节点池集合、容量计算过程见 `docs/eks-capacity-plan.md`;调度策略(HPA/VPA/Karpenter 职责边界、四条禁止项)见 `docs/eks-scheduling-standard.md`。本文档是三者之间"具体怎么配"的落地规格。

> **本轮修订说明:** (1)Karpenter NodePool(`stateless-on-demand`/`stateless-spot`/`batch-spot`)不再使用 `min/desired/max`,改用 `cpu_limit`/`memory_limit`/`instance_types`/`instance_categories`/`capacity_type`/`availability_zones`/`consolidation_policy`/`consolidate_after`/`expire_after`/`disruption_budget`;只有 Managed Node Group(`system-on-demand`、若启用的 `stateful-*`)保留 `min_size`/`desired_size`/`max_size`。(2)`stateful-*` 新增 `enable_stateful_node_groups` 开关,默认 `false`,具体形态(A/B/C/D)见 `docs/eks-capacity-plan.md` §2。(3)新增架构(`architecture=arm64|amd64`)维度和对应调度示例(§7)。

---

## 0. 节点编排方式选型:Managed Node Group + Karpenter 混合架构

### 结论

- `system-on-demand`、若启用的 `stateful-*`——使用 **EKS Managed Node Group**(`min_size`/`desired_size`/`max_size`,ASG 语义)。
- `stateless-on-demand`、`stateless-spot`、`batch-spot`——使用 **Karpenter NodePool**(`cpu_limit`/`memory_limit` 等资源上限语义,见 §2)。

`stateful-*` 具体是不是 Managed Node Group、是一个池子还是三个,取决于 `docs/eks-capacity-plan.md` §2 的方案 A/B/C/D 评估结果——本文档 §4 按方案 B(三个单 AZ Managed Node Group)给出示例规格,方案 A/C 的差异点在 §4 末尾单独说明。

### 理由

1. **Karpenter 没有传统 ASG 的 min/desired 概念**——它是反应式的:有 Pending Pod 就按 NodePool 的 `requirements` 选型下单,空闲/低利用率节点按 `consolidationPolicy` 主动回收。这对弹性池(`stateless-spot`/`batch-spot`)是优点,但对"必须始终有 N 个节点常驻"的需求(system 组件)不直接适用。本设计不再尝试用 Karpenter 模拟 ASG 的 min 语义(用占位 Pod 等 workaround),而是老老实实地:需要硬性常驻底线的池子用 Managed Node Group,不需要的池子用 Karpenter 并通过 §2 描述的应用层机制(minReplicas/PDB/PriorityClass)保证业务连续性。
2. Managed Node Group 可以直接把 ASG 绑定到单一可用区子网——如果 `stateful-*` 最终选方案 B,这正是它需要的强 AZ 绑定能力。
3. 用 Managed Node Group 承载 `system-on-demand`,同时天然解决了"Karpenter Controller 不能跑在自己管理的临时节点上"这个问题(见 `docs/eks-scheduling-standard.md` 禁止项 4)——因为 Karpenter Controller 就调度在 Managed Node Group 上,结构上不可能落在它自己创建的 Karpenter 节点上。
4. 弹性池(`stateless-on-demand`/`stateless-spot`/`batch-spot`)用 Karpenter 的价值最大:多机型/多可用区 diversification 降低 Spot 中断相关性、bin-packing 效率高、缩容到 0 是原生能力,不需要额外配置。

### Karpenter vs Cluster Autoscaler

选 **Karpenter**,作为 Karpenter NodePool 管理的三个池子(`stateless-on-demand`/`stateless-spot`/`batch-spot`)的节点层伸缩器。理由:
- 直接对接 EC2 Fleet API,扩容延迟通常比 Cluster Autoscaler(依赖预定义 ASG)更低。
- 原生支持机型多样化(一个 NodePool 可以声明多个 instance family/size,自动挑当前最优/最便宜的),不需要像 CA 那样为每种机型建一个独立 ASG。
- 原生的 Spot 中断处理(通过 EC2 Metadata + Interruption Queue),不强制额外部署 `aws-node-termination-handler`(仍建议部署作为兜底)。
- Cluster Autoscaler 仅作为**备选/回退方案**记录:如果未来 Karpenter 出现无法接受的稳定性问题,`stateless-*`/`batch-spot` 三个池子可以退回到"每种机型一个 Managed Node Group + Cluster Autoscaler"的传统模式,`system-on-demand` 不受影响(它本来就是 Managed Node Group)。

---

## 1. `system-on-demand`(Managed Node Group)

| 项目 | Lab | Production |
|---|---|---|
| 作用 | 集群关键组件:CoreDNS、metrics-server、aws-load-balancer-controller、EBS CSI controller、**Karpenter controller**、ingress controller | 同左 |
| 编排方式 | EKS Managed Node Group | EKS Managed Node Group |
| 架构 | `arm64` 优先,见 §7 逐组件兼容性要求 | 同左 |
| 实例规格候选 | `m7g.large`(arm64,首选)/ `m6i.large`(amd64,§7 验证不通过时的调度目标,不是"写写就算") | 同左 |
| `min_size` / `desired_size` / `max_size` | 1 / 1 / 2 | 3 / 3 / 5 |
| Capacity Type | On-Demand(唯一) | On-Demand(唯一) |
| Labels | `workload-class=system`, `node-lifecycle=on-demand`, `kubernetes.io/arch=<arm64\|amd64>` | 同左 |
| Taints | `dedicated=system:NoSchedule` | 同左 |
| Tolerations(允许调度到此池的工作负载需携带) | `dedicated=system` | 同左 |
| AZ | 单可用区(成本优先) | 三个可用区各至少 1 节点(`min_size=3` 天然保证) |
| EBS root volume | 20GiB gp3,加密 | 20GiB gp3,加密 |
| 成本估算 | 1×$59.57/月 ≈ $60/月 | 3×$59.57/月 ≈ $179/月(desired) |
| 故障行为 | 节点故障后 Managed Node Group 自动补充;system 组件的 Deployment 必须配置 `PodDisruptionBudget`(建议 `minAvailable=1`)防止滚动/节点替换时短暂全灭 | 同左,3 节点分布在 3 个可用区,单可用区故障不影响其余两个 |
| 适用工作负载 | CoreDNS、metrics-server、LB controller、EBS CSI controller、ingress controller、**Karpenter controller 本身** | 同左 |

---

## 2. `stateless-on-demand`(Karpenter NodePool)

| 项目 | Lab | Production |
|---|---|---|
| 作用 | 需要稳定性的无状态负载基线(延迟敏感、启动成本高、不适合被 Spot 中断打断) | 同左 |
| 编排方式 | Karpenter NodePool | Karpenter NodePool |
| 架构 | `arm64` 优先;需要 `arm64` 不支持的镜像时用同名 `-amd64` 变体(见 §7) | 同左 |
| 实例规格候选(`instance_types`) | `m7g.xlarge`(首选)、`c7g.xlarge`(计算密集) | 同左 |
| `instance_categories` | `["m", "c"]` | 同左 |
| `capacity_type` | `on-demand`(唯一) | `on-demand`(唯一) |
| `cpu_limit` / `memory_limit` | `7000m` / `29000Mi` | `18800m` / `77400Mi` |
| `availability_zones` | 不绑定,全部可用区 | 同左,建议配合 `topologySpreadConstraints` 尽量摊平到多可用区 |
| `consolidation_policy` | `WhenEmpty`(保守——这个池子的定位就是"稳定",不做激进 bin-packing) | 同左 |
| `consolidate_after` | `5m` | 同左 |
| `expire_after` | `720h`(30 天强制刷新) | 同左 |
| `disruption_budget` | `nodes: "1"`(同一时间最多打断 1 个节点) | 同左 |
| Labels | `workload-class=stateless`, `node-lifecycle=on-demand`, `kubernetes.io/arch=<arm64\|amd64>` | 同左 |
| Taints | `dedicated=stateless-on-demand:NoSchedule` | 同左 |
| Tolerations | `dedicated=stateless-on-demand` | 同左 |
| EBS root volume | 20GiB gp3,加密 | 20GiB gp3,加密 |
| 成本估算 | 通常 $0(稳态占用为 0,`cpu_limit`/`memory_limit` 只是上限) | 稳态约 2 节点等价 ≈ $238/月 |
| 故障行为 | 节点丢失后 Pod 在其余节点/新节点重建;无 PV 挂载顾虑 | 同左;业务基线容量由 `docs/eks-capacity-plan.md` §3.4 描述的 minReplicas+PDB+PriorityClass 机制保证,不是 NodePool 层面的 min |
| 适用工作负载 | 对启动延迟/中断敏感、但本身无持久化状态的服务 | 同左 |

---

## 3. `stateless-spot`(Karpenter NodePool)

| 项目 | Lab | Production |
|---|---|---|
| 作用 | 承载大部分无状态计算与 HPA 弹性峰值,容忍中断 | 同左 |
| 编排方式 | Karpenter NodePool | Karpenter NodePool |
| 架构 | `arm64` 优先;`-amd64` 变体同 §2 | 同左 |
| 实例规格候选(`instance_types`,机型多样化降低 Spot 中断相关性) | `m7g.large/xlarge`、`c7g.large/xlarge`、`m6g.large/xlarge` 混合声明 | 同左,规模更大时再加 `.2xlarge` |
| `instance_categories` | `["m", "c"]` | 同左 |
| `capacity_type` | `spot`(唯一) | `spot`(唯一) |
| `cpu_limit` / `memory_limit` | `11700m` / `48400Mi` | `18800m` / `77400Mi` |
| `availability_zones` | 不绑定,尽量分散以扩大可用 Spot 容量池 | 同左 |
| `consolidation_policy` | `WhenEmptyOrUnderutilized`(积极——这个池子本来就是容忍中断的,尽量压缩成本) | 同左 |
| `consolidate_after` | `30s` | 同左 |
| `expire_after` | `720h` | 同左 |
| `disruption_budget` | `nodes: "50%"` | 同左 |
| Labels | `workload-class=stateless`, `node-lifecycle=spot`, `kubernetes.io/arch=<arm64\|amd64>` | 同左 |
| Taints | `dedicated=stateless-spot:NoSchedule` | 同左 |
| Tolerations | `dedicated=stateless-spot` | 同左 |
| EBS root volume | 20GiB gp3,加密 | 20GiB gp3,加密 |
| 成本估算 | 通常 $0 | 稳态约 2 节点等价(spot 价)≈ $83/月 |
| 故障行为 | Spot 2 分钟中断通知;工作负载需配置 `PodDisruptionBudget` 与优雅终止(`preStop`/`terminationGracePeriodSeconds`);建议部署 `aws-node-termination-handler` 作为 Karpenter 原生中断处理的兜底 | 同左 |
| 适用工作负载 | 可容忍随时被打断、有多副本冗余的无状态服务;非关键 API;预览/测试流量 | 同左 |

---

## 4. `stateful-*`(默认关闭,`enable_stateful_node_groups=false`)

**默认关闭。** 当前没有真实 StatefulSet/PVC 需求,不预先常驻任何 stateful 节点组。启用条件、具体选哪个方案(A/B/C/D),见 `docs/eks-capacity-plan.md` §2 的正式对比。下表按**方案 B**(三个单 AZ Managed Node Group)给出示例规格,启用时先确认这确实是最终选定的方案。

| 项目 | Lab:`stateful-on-demand`(方案 A,单池跨 AZ,仅测试时临时启用) | Production:`stateful-az-a`/`-b`/`-c`(方案 B 示例,三个独立池,每池数值对称) |
|---|---|---|
| 启用开关 | `enable_stateful_node_groups=false`(默认),测试时手动置 `true` | `enable_stateful_node_groups=false`(默认),真实工作负载确认后置 `true` |
| 作用 | 承载带 PVC 的有状态负载(数据库、消息队列等) | 同左,但每个池只服务绑定在对应可用区的 PV |
| 编排方式 | EKS Managed Node Group | EKS Managed Node Group ×3(每个池独立 ASG) |
| 架构 | `arm64` 优先,数据库类镜像需逐个验证 arm64 支持(§7) | 同左 |
| 实例规格候选 | `r7g.xlarge`(内存优化,arm64,首选)/ `r6i.xlarge`(amd64,§7 验证不通过时使用) | 同左 |
| `min_size` / `desired_size` / `max_size` | 0(平时) / 1(测试时手动调整) / 2 | 每池:`desired_size=1` / `max_size=3`;`min_size` **待 RTO 确认后填 0 或 1**(见 capacity-plan §2 方案 B 的"每 AZ min=0 评估"),不预设 |
| Capacity Type | **On-Demand(强制,禁止 Spot)** | **On-Demand(强制,禁止 Spot)** |
| Labels | `workload-class=stateful`, `node-lifecycle=on-demand` | `workload-class=stateful`, `node-lifecycle=on-demand`, `topology.kubernetes.io/zone=<对应可用区>` |
| Taints | `dedicated=stateful-on-demand:NoSchedule` | `dedicated=stateful-az-a:NoSchedule`(`-b`/`-c` 同理) |
| Tolerations | `dedicated=stateful-on-demand`,且**不**携带任何 spot 相关 toleration | `dedicated=stateful-az-<x>`,且**不**携带任何 spot 相关 toleration |
| AZ | 不强制绑定——存在方案 A 的已知风险(见 capacity-plan §2,已改为风险+验证项表述,不是绝对结论) | **每个池硬绑定单一可用区**(ASG 子网只包含该可用区) |
| EBS root volume | 50GiB gp3,加密 | 同左 |
| 成本估算 | 启用时 1×$147.17/月(测试期间按小时折算,测试结束应关闭) | 每池 1×$147.17/月,三池合计 desired ≈ $441/月(仅在 `enable_stateful_node_groups=true` 后产生) |
| 故障行为 | 节点故障后,若替换节点落在错误可用区,对应 Pod 可能卡在 `Pending`,需人工介入(已知风险,严重程度待验证,见 capacity-plan §2) | 因 AZ 硬绑定,替换节点必然落在正确可用区,Pod 可自动恢复 |
| 适用工作负载 | 任何带 PVC 的 StatefulSet:自建数据库、Kafka/Redis 等 | 同左 |

**方案 A(Lab)/方案 C 的差异点:** 方案 A 就是上表 Lab 列本身;方案 C(topology-aware Karpenter Stateful NodePool)如果 Lab 验证通过并被 Production 采纳,则 Production 列会从"三个 Managed Node Group"变成"一个 Karpenter NodePool,`requirements` 里允许全部三个可用区",容量参数随之改用 §2/§3 的 `cpu_limit`/`memory_limit` 语义而不是这里的 `min/desired/max`——这个替换只有在 capacity-plan §5 的验证项完成、结论是"Karpenter 拓扑感知可靠"之后才会发生,本文档暂不展开具体参数。

**结构性禁止 Spot(与方案无关,A/B/C 都适用):** stateful 相关节点池都不声明任何 `capacity-type=spot`,且对应 StatefulSet 的 tolerations 里绝不出现 spot 相关 taint 的容忍——即使运维误操作也无法把 StatefulSet 调度到 spot 节点上。

---

## 5. `batch-spot`(Karpenter NodePool)

| 项目 | Lab | Production |
|---|---|---|
| 作用 | 批处理、定时任务、CI/ML 训练等可重试/可中断负载 | 同左 |
| 编排方式 | Karpenter NodePool | Karpenter NodePool |
| 架构 | `arm64` 优先;ML/训练类任务若依赖 x86 专属工具链(如特定 AVX 指令集优化),用 `-amd64` 变体 | 同左 |
| 实例规格候选(`instance_types`) | `m7g.2xlarge`、`c7g.2xlarge` 混合声明 | 同左,规模更大时再加 `.4xlarge` |
| `instance_categories` | `["m", "c"]` | 同左 |
| `capacity_type` | `spot`(唯一) | `spot`(唯一) |
| `cpu_limit` / `memory_limit` | `10100m` / `40600Mi` | `30200m` / `121700Mi` |
| `availability_zones` | 不绑定 | 同左 |
| `consolidation_policy` | `WhenEmptyOrUnderutilized` | 同左 |
| `consolidate_after` | `30s` | 同左 |
| `expire_after` | `720h` | 同左 |
| `disruption_budget` | `nodes: "50%"` | 同左 |
| Labels | `workload-class=batch`, `node-lifecycle=spot`, `kubernetes.io/arch=<arm64\|amd64>` | 同左 |
| Taints | `dedicated=batch-spot:NoSchedule` | 同左 |
| Tolerations | `dedicated=batch-spot` | 同左 |
| EBS root volume | 30GiB gp3,加密 | 30GiB gp3,加密 |
| 成本估算 | 通常 $0 | 通常 $0(稳态占用为 0,纯按需) |
| 故障行为 | 依赖 Kubernetes Job 的 `backoffLimit` 重试;长任务建议实现 checkpoint,避免中断后从头重跑 | 同左 |
| 适用工作负载 | 夜间 ETL、报表生成、CI 测试 runner、可重跑的批处理/训练任务 | 同左 |

---

## 6. labels/taints/tolerations 速查表

| 节点池 | Label(`dedicated=`) | Taint | 编排方式 | 容量参数语义 |
|---|---|---|---|---|
| `system-on-demand` | `system` | `dedicated=system:NoSchedule` | Managed Node Group | `min/desired/max` |
| `stateless-on-demand` | `stateless-on-demand` | `dedicated=stateless-on-demand:NoSchedule` | Karpenter NodePool | `cpu_limit`/`memory_limit` |
| `stateless-spot` | `stateless-spot` | `dedicated=stateless-spot:NoSchedule` | Karpenter NodePool | `cpu_limit`/`memory_limit` |
| `stateful-*`(默认关闭) | `stateful-on-demand` / `stateful-az-a` / `-b` / `-c` | 对应 `:NoSchedule` | Managed Node Group(方案 B)或 Karpenter(方案 C,待验证) | `min/desired/max`(方案 A/B)或 `cpu_limit`/`memory_limit`(方案 C) |
| `batch-spot` | `batch-spot` | `dedicated=batch-spot:NoSchedule` | Karpenter NodePool | `cpu_limit`/`memory_limit` |

设计原则:**每个池都打 taint,每个工作负载都必须显式携带对应 toleration + nodeSelector/nodeAffinity**——不依赖"默认落到某个池"的隐式行为,保证调度结果可预测、成本可按池归因、容量计算(`docs/eks-capacity-plan.md`)里"负载 vs 节点池"的对应关系始终成立。

---

## 7. 架构兼容性门禁(ARM64/AMD64)

Graviton(arm64)是成本优先的默认选择,但**"写 x86 备选"不等于"有调度实现"**——本节明确架构必须作为每个节点池、每个工作负载的显式字段,并给出真正能落地的调度机制。

### 7.1 规则

1. 每个节点池(Managed Node Group 或 Karpenter NodePool)必须声明 `architecture = arm64 | amd64`,作为调度约束的依据——Managed Node Group 依赖 kubelet 在每个节点上自动设置的 `kubernetes.io/arch` label(EKS `CreateNodegroup` API 拒绝显式传入任何 `kubernetes.io/`、`k8s.io/`、`eks.amazonaws.com/` 前缀的 label,这一点由一次真实 apply 的 `InvalidParameterException` 确认,而非仅凭文档假设);Karpenter NodePool 走 `requirements` 字段——不允许一个池子里混杂两种架构的节点(避免 Pod 因为没有架构亲和配置而被调度到不兼容的架构上导致 `exec format error`)。
2. **所有进入 arm64 节点池的镜像,必须确认支持 `linux/arm64`**——这是部署前置条件,不是"大概率没问题"。
3. 不支持 ARM 的工作负载,必须显式调度到对应池子的 `-amd64` 变体(见 §7.2),不能靠"反正调度器会兜底"的隐式假设。
4. **Jenkins、监控(VictoriaMetrics 等)、安全组件(tfsec/扫描类工具的容器化版本,若未来上 EKS)、中间件(Kafka/Redis 等)——每一项都需要单独确认其容器镜像是否有官方/可信的 arm64 构建,不能整体假设"都支持"或"都不支持"。**当前 Jenkins 运行在 EC2(`part1-jenkins-from-terraform`),不在本设计范围内;如果未来 Jenkins Agent 或流水线组件容器化并调度到 EKS,同样需要走这里的兼容性确认流程。
5. **CI 应当构建并检查 multi-arch 镜像**——即镜像构建流程(`docker buildx build --platform linux/amd64,linux/arm64`)产出多架构 manifest,并在部署前校验目标镜像确实包含目标节点池所需的架构。这是对未来 CI/CD 工作流(`lab-apply.yml` 等,阶段 5)的要求,本 PR 不实现。

### 7.2 池子命名与架构变体

每个工作负载类节点池默认是 arm64 主力池;确认某类工作负载的镜像不支持 arm64 后,建立同名 `-amd64` 后缀的兄弟池子,复用同一套 `dedicated`(taint/label 基础 key 不变,只是多一个架构维度),预期规模远小于 arm64 主力池(体量取决于实际有多少工作负载真的需要 x86,不预先大规模预留):

- `stateless-on-demand`(arm64,主力)/ `stateless-on-demand-amd64`(x86 兜底)
- `stateless-spot`(arm64,主力)/ `stateless-spot-amd64`(x86 兜底)
- `batch-spot`(arm64,主力)/ `batch-spot-amd64`(x86 兜底)
- `system-on-demand`:优先 arm64,如果某个关键组件(§7.1 第 4 条)缺 arm64 支持,**在同一个池子里通过 amd64 备用机型覆盖**而不是拆池子(system 组件数量少、体量小,拆两个池子反而增加常驻成本,直接在 Managed Node Group 层面纳入 amd64 机型作为 Karpenter/ASG 的补充选择即可)。
- `stateful-*`:同 system,优先在同一组 Managed Node Group 内以 amd64 机型作为兜底,而不是拆独立池子(除非某个具体数据库组件明确需要独立的 amd64 专属节点组)。

### 7.3 调度示例

**Deployment 调度到 arm64 主力池(`stateless-on-demand`):**

```yaml
spec:
  template:
    spec:
      nodeSelector:
        dedicated: stateless-on-demand
        kubernetes.io/arch: arm64
      tolerations:
        - key: dedicated
          operator: Equal
          value: stateless-on-demand
          effect: NoSchedule
```

**Deployment 调度到 amd64 兜底池(镜像不支持 arm64 时):**

```yaml
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/arch
                    operator: In
                    values: ["amd64"]
                  - key: dedicated
                    operator: In
                    values: ["stateless-on-demand-amd64"]
      tolerations:
        - key: dedicated
          operator: Equal
          value: stateless-on-demand-amd64
          effect: NoSchedule
```

**Karpenter NodePool `requirements`(arm64 主力池示例):**

```yaml
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["m", "c"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: dedicated
          operator: In
          values: ["stateless-on-demand"]
      taints:
        - key: dedicated
          value: stateless-on-demand
          effect: NoSchedule
```

`-amd64` 变体的 NodePool 结构相同,只需把 `kubernetes.io/arch` 的 values 换成 `["amd64"]`,`dedicated` 换成对应的 `-amd64` 池名。
