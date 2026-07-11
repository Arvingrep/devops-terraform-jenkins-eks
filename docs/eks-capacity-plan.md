# EKS 容量规划(Capacity Plan)

**状态:** 设计已完成,待业务确认具体工作负载数据后再进入 `modules/eks` 实现(阶段 4b)。本文档只做规划,不产生任何 Terraform 代码或 AWS 资源。

本文档、`docs/eks-node-group-design.md`、`docs/eks-scheduling-standard.md`、`docs/eks-storage-design.md` 四份共同构成阶段 4a 的交付物,互相引用,请配合阅读。

> **本轮修订说明:** 相比上一版,本次修订(1)不再对 Karpenter 管理的池子使用 `min/desired/max`(Karpenter 没有这个语义,详见 §3);(2)Stateful 节点组默认关闭(`enable_stateful_node_groups=false`),Production 的 AZ 策略改成四个方案的正式对比,而不是单一结论;(3)Lab 成本重新表述为"基础常驻成本"与"按需的 Stateful 测试成本"两部分,不再把含 Stateful 的配置当作日常推荐。

---

## 1. 节点池集合(Lab / Prod 共用命名,取值不同)

| 节点池 | 作用 | 编排方式 | Lab 是否启用 | Prod 是否启用 |
|---|---|---|---|---|
| `system-on-demand` | 集群关键组件(CoreDNS、metrics-server、Load Balancer Controller、EBS CSI controller、Karpenter controller、ingress controller) | Managed Node Group | ✅ | ✅ |
| `stateless-on-demand` | 需要稳定性的无状态负载(延迟敏感、启动成本高、不适合被随时打断) | Karpenter NodePool | ✅(可缩容到 0) | ✅ |
| `stateless-spot` | 大部分无状态计算,容忍中断 | Karpenter NodePool | ✅(可缩容到 0) | ✅ |
| `stateful-*`(自建有状态负载,形态见 §2) | 有状态负载(带 PVC) | Managed Node Group 或 Karpenter(取决于 §2 选型) | `enable_stateful_node_groups=false`(默认关闭,仅测试时临时启用) | `enable_stateful_node_groups=false`(默认关闭,真实 StatefulSet 需求确认后才启用) |
| `batch-spot` | 批处理、定时任务、CI/ML 训练等可重试负载 | Karpenter NodePool | ✅(可缩容到 0) | ✅ |

具体每个节点池的实例规格、容量参数、labels/taints/tolerations、EBS root volume、故障行为、适用工作负载,见 `docs/eks-node-group-design.md`。本文档聚焦"为什么这样分"和"容量怎么算出来的"。

**关于 `enable_stateful_node_groups` 默认 `false`:** 当前集群没有任何真实的 StatefulSet/PVC 需求(只有 nginx 冒烟测试)。在真实有状态工作负载确定之前,不默认在 Production 常驻三台(或任意数量)高成本的内存优化实例。是否启用、启用哪种形态,由 §2 的方案评估决定,且必须等到有真实工作负载要上线时才打开。

---

## 2. Stateful 节点组策略——四种方案对比(不预设唯一答案)

是否需要在 EKS 里自建有状态节点组、需要几个、要不要按 AZ 拆分,取决于**具体的有状态工作负载是什么、需要多少副本、RPO/RTO 要求是什么**——这些现在都还不知道(§5 待确认清单)。下面给出四个候选方案的对比和各自的适用条件,而不是直接认定某一个"永远正确"。

### 方案 A:单个跨 AZ Stateful Managed Node Group(不绑定 AZ)

- **做法:** 一个 Managed Node Group,子网覆盖全部可用区,不做 AZ 绑定。
- **优点:** 配置最简单;容量可以在可用区之间共享,不需要每个可用区都单独预留常驰节点,成本最低。
- **风险(不是必然发生,是需要验证的风险点):** EBS 卷按可用区绑定;如果某个可用区节点故障、ASG 在另一个可用区补充了替换节点,绑定了原可用区 EBS 卷的 Pod 有可能调度失败、卡在 `Pending`,直到人工介入(手动缩容错误可用区的节点、等待 ASG 重试,或手动 cordon/taint 引导它重新在正确可用区补节点)。这个风险是否会实际发生、发生频率如何,取决于 ASG 的可用区再平衡行为、子网权重配置等细节,**必须通过验证项(见下)实测确认,不能假定它一定会/一定不会发生**。
- **适用条件:** Lab(数据非关键,`AutoDestroy=true`,偶发人工介入可接受);或者 Production 里有状态副本数极少(比如只有 1 个非关键缓存实例)、且团队接受偶发人工介入的场景;或成本敏感度极高、愿意用监控告警(对 stateful Pod 的 `Pending` 状态告警)作为主要缓解手段的阶段。

### 方案 B:三个单 AZ Stateful Managed Node Group(每个可用区一个,即 `stateful-az-a/b/c`)

- **做法:** 三个独立 Managed Node Group,每个的子网只包含一个可用区,`min_size`/`desired_size`/`max_size` 各自独立配置。
- **优点:** 从结构上消除方案 A 的 AZ 不匹配风险——每个池子的补充节点**只能**落在配置好的那个可用区(由 ASG 子网列表保证,这一点本身不需要额外验证,是 Managed Node Group 的原生保证)。
- **缺点:** 无法跨可用区共享容量;哪怕利用率很低,常驻成本也可能是方案 A 的 2-3 倍(取决于每池 `min_size` 取值,见下面的"每 AZ min=0 评估")。配置复杂度是方案 A 的三倍(三套独立的节点组定义)。
- **每 AZ `min_size=0` 的评估:** 不是必须每个 AZ 都常驻 ≥1 节点。如果业务能接受"首次调度到某可用区时有一次冷启动延迟"(ASG 需要先拉起节点,通常几十秒到几分钟),三个池子都可以 `min_size=0`,只在真正有 Pod 调度过去时才拉起节点,大幅降低常驻成本;如果 RTO 要求故障后近乎瞬时恢复(不能接受冷启动延迟),则需要对应可用区 `min_size≥1` 保持热备。**这个取舍必须由实际的 RPO/RTO 目标决定,不是默认选项。**
- **适用条件:** 已经确认有真实的多可用区有状态工作负载(例如 Postgres 主备跨可用区部署、Kafka 多可用区 broker),且 AZ 级别的高可用性对业务有实质意义时的默认目标方案。

### 方案 C:Topology-aware Karpenter Stateful NodePool

- **做法:** 用一个(而不是三个)Karpenter NodePool 承载 stateful 负载,`requirements` 里声明允许全部三个可用区,依赖 Karpenter 原生的 PVC/拓扑感知能力——Karpenter 在为一个引用了已存在 PV(或有明确拓扑要求的 PVC)的 Pending Pod 决策节点时,设计上会读取该 PV 的 `nodeAffinity`/可用区要求,在**正确的可用区**下单新节点。
- **优点:** 兼具方案 B 的正确性(理论上)和方案 A 的简洁性/弹性(单一 NodePool、原生缩容到 0、不需要为每个可用区预留常驻容量)。
- **风险(必须验证,不能假定):** 这个方案的正确性完全依赖"Karpenter 在这套 EBS CSI + `WaitForFirstConsumer` 组合下,是否真的每次都能正确识别 PV 拓扑要求并在对应可用区下单"——这是需要专门验证项(在 Lab 里实测:故意让某可用区节点故障,观察 Karpenter 补充节点的可用区是否总是正确)才能下结论的事情,不能直接假定它总是正确工作。此外,Karpenter 反应式扩容意味着无法像 ASG `min_size≥1` 那样提供"始终热备"的容量,如果 RTO 要求不允许冷启动延迟,这个方案不满足要求。
- **适用条件:** 值得作为**降低方案 B 运维复杂度**的候选方向,在 Lab 里先做验证 spike(见 §5),确认拓扑感知行为可靠、且 RTO 容忍冷启动延迟之后,再考虑在 Production 采用,替代方案 B。

### 方案 D:使用 AWS 托管数据库/消息服务,不在 EKS 自建

- **做法:** 常见有状态组件优先使用对应的 AWS 托管服务而不是自建 StatefulSet——关系型数据库 → RDS/Aurora;Kafka → MSK;缓存 → ElastiCache;Elasticsearch/OpenSearch → Amazon OpenSearch Service。
- **优点:** 直接消除方案 A/B/C 要解决的全部问题——多可用区复制、故障转移、备份、打补丁都由 AWS 托管,不需要 `stateful-*` 节点组、不需要本文档讨论的 AZ 绑定问题。对于有成熟托管等价物的组件,通常应该是**默认优先选项**,而不是"退而求其次"的选项。
- **缺点:** 小规模场景下托管服务的直接费用可能高于自建;灵活性较低(比如 RDS 不一定支持所有自建 Postgres 才有的插件);并非所有组件都有托管等价物——比如 **VictoriaMetrics 目前没有对应的 AWS 托管服务**,这一类组件无论如何都需要走方案 A/B/C 之一。
- **适用条件:** **每个有状态组件应该单独评估**,而不是整个平台一刀切。有成熟托管等价物、且没有明确的成本/功能/合规理由必须自建的组件(典型:关系型数据库、Kafka、缓存),默认应该优先选方案 D;没有托管等价物、或有明确自建理由的组件(典型:VictoriaMetrics),再从方案 A/B/C 中选。

### 决策方式

不预设"所有有状态负载都用同一个方案"。当真实工作负载清单确定后(见 §5),按组件逐个评估:先问"有没有合适的 AWS 托管服务(方案 D)",没有的话再从 A(Lab/低风险场景)、B(需要确定性 AZ 隔离的 Production 默认目标)、C(愿意先验证、想降低运维复杂度)中选,并且 `enable_stateful_node_groups` 在评估完成、真正有工作负载要部署之前保持 `false`。

---

## 3. 容量计算模型

容量计算方法本身对 Managed Node Group 和 Karpenter NodePool 是共通的(先算出"每个节点净可用多少"),但**产出的参数不同**——这是本轮修订的核心修正点。

### 3.1 单节点净可用容量——计算公式(两种编排方式通用)

```
Allocatable = Instance_Capacity - Reserved(kube-reserved + system-reserved) - Eviction_Threshold
Usable      = Allocatable × Target_Utilization(65%~70%,本设计统一取中值 67.5%)
Net         = Usable - DaemonSet_Overhead
```

**CPU 预留公式(标准 Kubernetes/EKS 推荐值):**
- 第 1 个核心:6%
- 第 2 个核心:1%
- 第 3–4 个核心:各 0.5%
- 第 4 个核心以上:各 0.25%

**内存预留公式(AWS EKS 官方 bootstrap 推荐值):**
- 首 4GiB:11%
- 次 4GiB(4–8GiB 区间):6%
- 次 8GiB(8–16GiB 区间):5%
- 次 112GiB(16–128GiB 区间):4%
- 128GiB 以上:2.5%
- 另加 eviction-hard 默认预留 100MiB

**DaemonSet 开销(估算值,待接入可观测性栈后用真实数据校正):** 每个节点统一按 **300m CPU / 400MiB 内存** 估算,覆盖 VPC CNI(aws-node)、kube-proxy、EBS CSI node 插件、日志采集(Fluent Bit)、节点监控(node-exporter)。这是一个待实测确认的假设值,见 §5。

### 3.2 各候选机型的净可用容量(计算结果,us-east-1,Graviton/arm64 优先,x86/amd64 备选见 `docs/eks-node-group-design.md` 的架构小节)

| 机型 | 架构 | vCPU / 内存 | CPU 预留 | Mem 预留 | Allocatable | Usable(×67.5%) | DaemonSet 开销 | **净可用 / 节点** |
|---|---|---|---|---|---|---|---|---|
| m7g.large | arm64 | 2 vCPU / 8GiB | 70m | 951MiB+100MiB=1051MiB | 1930m / 7141MiB | 1303m / 4820MiB | 300m / 400MiB | **1003m / 4420MiB** |
| m7g.xlarge | arm64 | 4 vCPU / 16GiB | 80m | 1361MiB+100MiB=1461MiB | 3920m / 14923MiB | 2646m / 10073MiB | 300m / 400MiB | **2346m / 9673MiB** |
| r7g.xlarge | arm64 | 4 vCPU / 32GiB | 80m | 2016MiB+100MiB=2116MiB | 3920m / 30652MiB | 2646m / 20690MiB | 300m / 400MiB | **2346m / 20290MiB** |
| m7g.2xlarge | arm64 | 8 vCPU / 32GiB | 90m | 2016MiB+100MiB=2116MiB | 7910m / 30652MiB | 5339m / 20690MiB | 300m / 400MiB | **5039m / 20290MiB** |
| m6i.large | amd64 | 2 vCPU / 8GiB | 70m | 951MiB+100MiB=1051MiB | 1930m / 7141MiB | 1303m / 4820MiB | 300m / 400MiB | **1003m / 4420MiB**(近似,单价高 10-15%) |
| m6i.xlarge | amd64 | 4 vCPU / 16GiB | 80m | 1361MiB+100MiB=1461MiB | 3920m / 14923MiB | 2646m / 10073MiB | 300m / 400MiB | **2346m / 9673MiB**(近似,单价高 10-15%) |

**架构不是"备选写写就行"——每个池子最终必须能说清楚它调度的是 arm64 还是 amd64、通过什么机制保证,见 `docs/eks-node-group-design.md` 新增的架构章节和调度示例。**

### 3.3 Managed Node Group 池子(`system-on-demand`,以及若启用的 `stateful-*`)——沿用 min/desired/max 语义

这两类池子使用 EKS Managed Node Group(ASG 语义),`min_size`/`desired_size`/`max_size` 是字面意义上的常驻值,计算方式:需求 ÷ 净可用容量 = 节点数,向上取整,再叠加单节点故障冗余。

**system-on-demand(使用 m7g.large,净可用 1003m / 4420MiB):**

| 组件 | Prod 副本数 × 单副本请求 | Lab 副本数 × 单副本请求 |
|---|---|---|
| CoreDNS | 2 × 100m/70MiB | 1 × 100m/70MiB |
| metrics-server | 1 × 100m/200MiB | 1 × 100m/200MiB |
| aws-load-balancer-controller | 2 × 100m/128MiB | 1 × 100m/128MiB |
| EBS CSI controller | 2 × 100m/256MiB | 1 × 100m/256MiB |
| Karpenter controller | 2 × 500m/512MiB | 1 × 500m/512MiB |
| ingress controller | 2 × 200m/256MiB | (Lab 不启用) |
| **合计** | **2100m / 2644MiB** | **900m / 1166MiB** |

- Prod:CPU 主导,`ceil(2100/1003)=3` 节点;内存 `ceil(2644/4420)=1` 节点 → 取 3。三个可用区各一个,天然满足 HA。→ **`min_size=3` / `desired_size=3` / `max_size=5`**
- Lab:`ceil(900/1003)=1` 节点;`ceil(1166/4420)=1` 节点 → 取 1。→ **`min_size=1` / `desired_size=1` / `max_size=2`**

**`stateful-*`(若按 §2 方案 B 启用,使用 r7g.xlarge,净可用 2346m / 20290MiB;`enable_stateful_node_groups=true` 之后才适用):**

- Prod 假设(每个可用区独立计算,对称,方案 B):1 个数据类工作负载副本 × 1000m/4096MiB → `ceil(1000/2346)=1`,`ceil(4096/20290)=1` → 每个可用区理论上 1 节点即可满足负载。**是否配 `min_size=1`(热备)还是 `min_size=0`(冷启动可接受)由 RTO 要求决定**,见 §2 方案 B 的"每 AZ min=0 评估"。→ 每池 **`desired_size=1` / `max_size=3`**,`min_size` 待 RTO 确认后填(0 或 1)。
- Lab 假设(方案 A,测试时临时启用):1 个数据类工作负载副本 × 500m/2048MiB → 1 节点。→ **`min_size=0`(平时关闭)/ `desired_size=1`(测试期间手动调为 1)/ `max_size=2`**。

### 3.4 Karpenter NodePool 池子(`stateless-on-demand`/`stateless-spot`/`batch-spot`)——不使用 min/desired/max

Karpenter NodePool 没有 ASG 的 `min_size`/`desired_size`/`max_size` 语义:它是反应式的,根据 Pending Pod 触发扩容,按 `consolidationPolicy` 主动回收空闲/低利用率节点。给这类池子的容量参数是:

| 参数 | 含义 |
|---|---|
| `cpu_limit` / `memory_limit` | 这个 NodePool 能扩容到的资源总量上限(`spec.limits`),防止失控扩容;**这是唯一真正意义上的容量上限参数**,替代原来的"max 节点数" |
| `instance_types` / `instance_categories` | 允许 Karpenter 选择的机型清单/机型大类(如 `["m","c"]`),多样化机型降低 Spot 中断相关性、提升 bin-packing 效率 |
| `capacity_type` | `on-demand` 或 `spot`,决定这个池子只用哪种计费类型 |
| `availability_zones` | 允许提供节点的可用区集合(弹性池通常允许全部可用区,以扩大可调度容量) |
| `consolidation_policy` | `WhenEmpty`(保守,只回收完全空闲节点)或 `WhenEmptyOrUnderutilized`(积极,连低利用率节点也回收) |
| `consolidate_after` | 触发回收前的等待时间,避免刚扩容就被回收造成抖动 |
| `expire_after` | 节点强制回收的最大生命周期(即使一直繁忙也会被替换),用于定期刷新 AMI/安全补丁 |
| `disruption_budget` | 同一时间允许被 Karpenter 主动打断(回收/替换)的节点数量上限,保护可用性 |

**业务基线容量(原来靠 `min` 保证的"总有一点常驻容量")现在通过以下机制保证,而不是 NodePool 的字面参数:**

1. **Deployment `minReplicas`**(配合 HPA):保证 Pod 副本数量有下限,Pod 数量下限 + 调度约束自然会让 Karpenter 保持对应的节点容量。
2. **PodDisruptionBudget**:防止 Karpenter 的 consolidation 把仍在承载最低副本数的节点回收掉。
3. **PriorityClass**:保证基线/关键 Pod 在容量竞争时优先获得调度和保留,不被更低优先级的负载挤占或在缩容时优先驱逐。
4. **On-Demand NodePool 的调度约束(即 `stateless-on-demand` 本身)**:需要"稳定基线"的工作负载,通过 taint/toleration + nodeSelector 固定调度到 `stateless-on-demand`(On-Demand 专用池,`consolidation_policy` 配置更保守),不会被随意打断,充当事实上的"稳定层"。

**参数取值(在原有节点数估算的基础上转换为资源上限,不再是节点数):**

**stateless-on-demand(使用 m7g.xlarge,净可用 2346m / 9673MiB;这个池子只承载"稳定基线",不是 HPA 峰值——峰值弹性交给 stateless-spot):**

- 负载假设(同前):Prod 2 个延迟敏感服务 × 基线 2 副本 × 500m/512MiB = 2000m/2048MiB;Lab 通常为 0。
- Prod:按"允许扩到约 8 节点等价规模"设上限 → `cpu_limit ≈ 8×2346m ≈ 18800m`,`memory_limit ≈ 8×9673MiB ≈ 77400MiB`。实际稳态占用远低于此上限(约 1-2 节点等价,`≈2346-4700m` / `≈9700-19300MiB`),上限只是防止失控扩容的安全阀。
- Lab:`cpu_limit ≈ 3×2346m ≈ 7000m`,`memory_limit ≈ 3×9673MiB ≈ 29000MiB`(允许突发测试用,平时占用应为 0)。

**stateless-spot(使用 m7g.xlarge/c7g.xlarge/m6g.xlarge 等多机型,净可用按 m7g.xlarge 口径 2346m / 9673MiB;这个池子承载 HPA 峰值弹性):**

- 负载假设(同前):Prod 5 个服务 × 基线 3 副本、HPA 上限 6 副本 × 250m/256MiB → HPA 峰值需求 7500m/7680MiB(约等价 4 节点);Lab 通常为 0。
- Prod:`cpu_limit ≈ 8×2346m ≈ 18800m`,`memory_limit ≈ 8×9673MiB ≈ 77400MiB`(覆盖峰值 4 节点等价 + 增长余量)。
- Lab:`cpu_limit ≈ 5×2346m ≈ 11700m`,`memory_limit ≈ 5×9673MiB ≈ 48400MiB`。

**batch-spot(使用 m7g.2xlarge/c7g.2xlarge,净可用 5039m / 20290MiB):**

- 负载假设(同前):Prod 峰值并发 4 个大批处理 Pod × 2000m/4096MiB = 8000m/16384MiB(约等价 2 节点);Lab 峰值 2000m/4096MiB。
- Prod:`cpu_limit ≈ 6×5039m ≈ 30200m`,`memory_limit ≈ 6×20290MiB ≈ 121700MiB`。
- Lab:`cpu_limit ≈ 2×5039m ≈ 10100m`,`memory_limit ≈ 2×20290MiB ≈ 40600MiB`。

---

## 4. 成本估算

**免责声明:** 以下单价为 us-east-1、Linux、Graviton(arm64)机型的**近似值**,仅用于数量级判断,正式预算前必须用 Infracost(`scripts/cost-check.sh`,目前是占位)或 AWS Pricing Calculator 核实当前实际价格。EKS 控制面固定收费 **$0.10/小时 ≈ $73/月**,Lab、Prod 都要付,与节点数量无关。

近似 On-Demand 时价(us-east-1):`m7g.large≈$0.0816/hr`、`m7g.xlarge≈$0.1632/hr`、`r7g.xlarge≈$0.2016/hr`、`m7g.2xlarge≈$0.3264/hr`。Spot 按 On-Demand 的 ~35% 估算(即约 65% 折扣,实际折扣随可用区/机型实时波动)。

### 4.1 Lab——基础常驻成本与 Stateful 测试成本分开表述

**Lab 基础常驻成本(日常推荐,不含 Stateful):**

组成:EKS Control Plane + `system-on-demand`(1×m7g.large)。`stateless-on-demand`/`stateless-spot`/`batch-spot` 三个 Karpenter 池子平时占用应为 0(cpu_limit/memory_limit 只是上限,不是常驻占用)。

> 控制面 $73 + system 1×$59.57 ≈ **$133/月**,这是 Lab 日常应该维持的成本量级,**不是** ~$280/月。

**Lab Stateful 测试成本(仅测试期间临时启用):**

`stateful-*` 默认 `enable_stateful_node_groups=false`,不产生任何成本。需要测试有状态工作负载时手动启用(方案 A,1×r7g.xlarge),按小时计:

> r7g.xlarge ≈ **$0.2016/小时**——测试完成后必须手动关闭该节点组(或直接销毁整个 Lab EKS),不应让它常驻计费。

**Lab 完全不用时:** 直接销毁整个 Lab EKS 集群(`make lab-destroy`),不需要长期维持哪怕 $133/月的基础成本——Lab 的定位就是可以随时销毁、随时重建。

### 4.2 Production

Production 的存储/节点组成本表基于 §2 方案 B(三个单 AZ Stateful Managed Node Group,`desired_size=1`/池)作为示例基准——如果最终按组件评估后选择方案 D(托管服务)覆盖大部分 stateful 组件,这部分成本会大幅下降(转移到 RDS/MSK 等服务自身的账单,不在本表内);如果选方案 A,stateful 部分成本可降至约 1/3(共享一个跨 AZ 池而不是三个独立池)。

| 版本 | 组成(取各池 min/desired,stateful 部分按方案 B、`desired_size=1`/池 估算) | 月度计算成本估算 |
|---|---|---|
| **最小可用版本** | system(min=3)×m7g.large + stateless-on-demand(稳态最低,近似 1 节点等价)×m7g.xlarge + stateful-az-*(若已启用,方案 B,每池 1 节点)×r7g.xlarge + 控制面 | 3×$59.57+1×$119.14+3×$147.17+$73 ≈ **$812/月** |
| **推荐版本(稳态典型占用)** | system 3 + stateless-on-demand 稳态约 2 节点等价 + stateless-spot 稳态约 2 节点等价(spot 价)+ stateful-az-*(若已启用)3 + 控制面 | 3×$59.57+2×$119.14+2×$41.72+3×$147.17+$73 ≈ **$1,015/月** |
| **峰值上限(各 Karpenter 池打满 cpu_limit/memory_limit,Managed Node Group 打满 max_size,极端情况,不应长期维持)** | system 5 + stateless-on-demand 上限约 8 节点等价 + stateless-spot 上限约 8 节点等价(spot)+ stateful-az-* 每池 max_size=3(共 9)+ batch-spot 上限约 6 节点等价(spot)+ 控制面 | ≈ **$3,482/月** |

**Production 月度成本区间:约 $812 – $3,482/月(计算资源部分,假设 stateful 走方案 B),推荐版本基线约 $1,015/月;若 stateful 部分改走方案 D,对应约 $441/月的 stateful 节点成本会替换成托管服务账单,需单独核算。** 另需加上 EBS 存储成本(见 `docs/eks-storage-design.md`)和已有 network 模块的 NAT/流量成本(见 `docs/target-architecture.md` §5)。

### 4.3 主要费用来源

按占比从高到低(假设 stateful 走方案 B):`stateful-az-*`(r7g.xlarge 单价最高,且强制 On-Demand、不能上 Spot)> `stateless-on-demand` 稳态占用 > `system-on-demand`(必须 On-Demand,但机型较小)> `stateless-spot`/`batch-spot`(Spot 折扣后单价最低,且 cpu_limit/memory_limit 只是上限不是常驻占用)> EKS 控制面固定成本。

### 4.4 可以关闭 / 不能缩容到 0 的资源

- **可以缩容到 0:** `stateless-spot`、`batch-spot`(始终可以,Karpenter 原生支持);Lab 的 `stateless-on-demand`(稳态占用应为 0);**`stateful-*` 默认整体关闭**(`enable_stateful_node_groups=false`)。
- **不能缩容到 0:** `system-on-demand`(Lab min_size=1,Prod min_size=3——集群关键组件必须有地方跑,这是唯一保留字面 `min` 语义的强制底线);Prod 的 `stateful-az-*`(一旦启用且有负载调度上去,对应 AZ 池的 `desired_size` 必须 ≥1,是否需要 `min_size≥1` 常驻热备由 RTO 决定,见 §2);Prod 的 `stateless-on-demand`(靠 Deployment `minReplicas`+PDB+PriorityClass 保证事实上的基线占用,不是 NodePool 字面 min)。

---

## 5. 待业务/待实测确认清单

- 本文档 §3 里的所有工作负载假设(服务数量、副本数、CPU/内存 request、HPA 上限)都是占位数字,真实服务清单确定后必须重新代入 §3.1/§3.2 的公式复算。
- DaemonSet 开销假设(300m CPU / 400MiB 内存/节点)需要在接入真实可观测性栈(日志/监控 agent 选型)后用实测数据校正。
- 成本估算里的单价需要在实现前用 Infracost 或 AWS Pricing Calculator 核实当前实际价格(尤其 Spot 折扣率会实时波动)。
- **真实有状态工作负载清单**——每个组件是否有合适的 AWS 托管等价物(§2 方案 D)、副本数要求、RPO/RTO 目标——决定 §2 最终选哪个方案、`stateful-*` 是否/何时启用。
- **验证项(建议在 Lab 里先做,不等真实业务需求就可以启动):** 方案 A/C 的可用区拓扑正确性——故意让某可用区的节点故障,观察 Managed Node Group(方案 A)或 Karpenter(方案 C)补充的节点是否总是落在 PV 所在的正确可用区,用实测结果而不是假设来决定 Production 最终选 A/B/C 中的哪一个。
- Stateful 负载的真实规格(CPU/内存/磁盘 IO 特征)决定了 `docs/eks-storage-design.md` 里 `gp3` vs `gp3-performance` 的选择,目前按"数据库类工作负载"的通用假设估算。
