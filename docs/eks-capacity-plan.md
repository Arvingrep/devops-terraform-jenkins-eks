# EKS 容量规划(Capacity Plan)

**状态:** 设计已完成,待业务确认具体工作负载数据后再进入 `modules/eks` 实现(阶段 4b)。本文档只做规划,不产生任何 Terraform 代码或 AWS 资源。

本文档、`docs/eks-node-group-design.md`、`docs/eks-scheduling-standard.md`、`docs/eks-storage-design.md` 四份共同构成阶段 4a 的交付物,互相引用,请配合阅读。

---

## 1. 节点池集合(Lab / Prod 共用命名,取值不同)

| 节点池 | 作用 | Lab 是否启用 | Prod 是否启用 |
|---|---|---|---|
| `system-on-demand` | 集群关键组件(CoreDNS、metrics-server、Load Balancer Controller、EBS CSI controller、Karpenter controller、ingress controller) | ✅ | ✅ |
| `stateless-on-demand` | 需要稳定性的无状态负载(延迟敏感、启动成本高、不适合被随时打断) | ✅(可缩容到 0) | ✅ |
| `stateless-spot` | 大部分无状态计算,容忍中断 | ✅(可缩容到 0) | ✅ |
| `stateful-on-demand` | 有状态负载(带 PVC),单一节点池,跨 AZ | ✅(Lab 专用形态) | ❌(Prod 改用下面的按 AZ 拆分形态) |
| `stateful-az-a` / `stateful-az-b` / `stateful-az-c` | 有状态负载,按可用区拆分 | ❌ | ✅(Prod 专用形态) |
| `batch-spot` | 批处理、定时任务、CI/ML 训练等可重试负载 | ✅(可缩容到 0) | ✅ |

具体每个节点池的实例规格、min/desired/max、labels/taints/tolerations、EBS root volume、故障行为、适用工作负载,见 `docs/eks-node-group-design.md`。本文档聚焦"为什么这样分"和"容量怎么算出来的"。

---

## 2. Production 是否按 AZ 拆分 Stateful 节点池——评估结论:**是,拆分**

### 结论

Production 采用 `stateful-az-a`/`stateful-az-b`/`stateful-az-c` 三个独立节点池,而不是一个跨 AZ 的 `stateful-on-demand`。Lab 保留单一跨 AZ 的 `stateful-on-demand`,不拆分。

### 理由

1. EBS 卷是**按可用区绑定**的资源——一个 gp3 PV 只能挂载到同一可用区内的节点上。
2. 如果 stateful 节点来自同一个跨多可用区的节点池/ASG,当某个可用区的节点故障、Karpenter/Cluster Autoscaler 补充新节点时,补充的节点完全可能落在**错误的可用区**——这会导致 Pod 永久卡在 `Pending`,因为它绑定的 PV 所在可用区没有可用节点,需要人工介入才能恢复。
3. 把 stateful 节点拆成三个独立、每个都**硬性绑定单一可用区**(`topology.kubernetes.io/zone` 作为节点池的强制 Karpenter/ASG 约束)的节点池,可以从结构上彻底消除这个故障模式——每个池子的补充节点永远落在正确的可用区。
4. 代价:三个独立池子意味着无法互相"借用"容量(A 可用区忙、B 可用区闲时不能自动平衡),而且哪怕利用率很低,也需要三个可用区各保留至少 1 个节点常驻(而不是一个池子里共享 1 个节点就够)——这会推高 Production 的最低常驻成本(见 §4 成本部分)。考虑到 Production 的 stateful 负载数量通常不多但关键性高,这个取舍是值得的。
5. Lab 不拆分:Lab 的 stateful 负载(如果有的话)本来就是非关键、可随时销毁的(环境标签强制 `AutoDestroy=true`),就算某次节点故障后 Pod 短暂卡在 Pending,人工 `kubectl` 介入或者干脆重新 apply 就能解决——不值得为此在 Lab 多付三倍的常驻节点成本。

---

## 3. 容量计算模型

容量计算分三步:①算出每种机型"每个节点实际能装多少 Pod"(净可用容量);②算出每个节点池的"负载需求";③用需求除以净可用容量,并叠加单节点故障冗余,得到 min/desired/max。

### 3.1 单节点净可用容量——计算公式

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

**DaemonSet 开销(估算值,待接入可观测性栈后用真实数据校正):** 每个节点统一按 **300m CPU / 400MiB 内存** 估算,覆盖 VPC CNI(aws-node)、kube-proxy、EBS CSI node 插件、日志采集(Fluent Bit)、节点监控(node-exporter)。这是一个待实测确认的假设值,见文末"待业务/待实测确认清单"。

### 3.2 各候选机型的净可用容量(计算结果,us-east-1,Graviton 优先)

| 机型 | vCPU / 内存 | CPU 预留 | Mem 预留 | Allocatable | Usable(×67.5%) | DaemonSet 开销 | **净可用 / 节点** |
|---|---|---|---|---|---|---|---|
| m7g.large | 2 vCPU / 8GiB | 70m | 951MiB+100MiB=1051MiB | 1930m / 7141MiB | 1303m / 4820MiB | 300m / 400MiB | **1003m / 4420MiB** |
| m7g.xlarge | 4 vCPU / 16GiB | 80m | 1361MiB+100MiB=1461MiB | 3920m / 14923MiB | 2646m / 10073MiB | 300m / 400MiB | **2346m / 9673MiB** |
| r7g.xlarge | 4 vCPU / 32GiB | 80m | 2016MiB+100MiB=2116MiB | 3920m / 30652MiB | 2646m / 20690MiB | 300m / 400MiB | **2346m / 20290MiB** |
| m7g.2xlarge | 8 vCPU / 32GiB | 90m | 2016MiB+100MiB=2116MiB | 7910m / 30652MiB | 5339m / 20690MiB | 300m / 400MiB | **5039m / 20290MiB** |

x86 备选(部分镜像/软件尚不支持 ARM 时使用):`m6i.large`/`m6i.xlarge`/`r6i.xlarge`/`m6i.2xlarge`,预留比例计算方式相同,净可用容量数值接近(x86 单价通常比 Graviton 高 10–15%)。

### 3.3 每个节点池的需求计算(工作示例,输入数据均为**待业务确认的占位假设**)

> 当前集群只有 `part2-cluster-from-terraform-and-jenkins/kubernetes` 里的 nginx 冒烟测试负载,还没有真实的业务服务清单。下面的负载假设是为了把计算方法跑通、给出可信的 min/desired/max **数量级**,不是最终数字——真实服务清单确定后必须重新代入这个公式复算,具体待确认项见文末清单。

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

- Prod:CPU 主导,`ceil(2100/1003)=3` 节点;内存 `ceil(2644/4420)=1` 节点 → 取 3。三个可用区各一个,天然满足 HA。
- Lab:`ceil(900/1003)=1` 节点;`ceil(1166/4420)=1` 节点 → 取 1。

**stateless-on-demand(使用 m7g.xlarge,净可用 2346m / 9673MiB;这个池子只承载"稳定基线"副本数,不是 HPA 峰值——峰值弹性交给 stateless-spot):**

- Prod 假设:2 个延迟敏感服务 × 基线 2 副本 × 500m/512MiB = 2000m / 2048MiB → `ceil(2000/2346)=1` 节点(CPU)、`ceil(2048/9673)=1`(内存)→ 1 节点即可满足稳态,但为容忍单节点故障取 2。
- Lab 假设:通常为 0(完全按需由 Karpenter 触发)。

**stateless-spot(使用 m7g.xlarge,净可用 2346m / 9673MiB;这个池子承载 HPA 峰值弹性):**

- Prod 假设:5 个通用服务 × 基线 3 副本、HPA 上限 6 副本 × 250m/256MiB。
  - HPA 峰值需求:5×6×250m=**7500m**,5×6×256MiB=**7680MiB** → `ceil(7500/2346)=4` 节点(CPU 主导),`ceil(7680/9673)=1`(内存)→ 峰值 4 节点。
  - 基线需求(3 副本):5×3×250m=3750m → `ceil(3750/2346)=2` 节点 → 作为 `desired`。
- Lab 假设:通常为 0。

**stateful-on-demand(Lab)/ stateful-az-\*(Prod)(使用 r7g.xlarge,净可用 2346m / 20290MiB):**

- Prod 假设(每个可用区独立计算,对称):1 个数据类工作负载副本 × 1000m/4096MiB → `ceil(1000/2346)=1`,`ceil(4096/20290)=1` → 每个可用区 1 节点。
- Lab 假设:1 个数据类工作负载副本 × 500m/2048MiB → 1 节点。

**batch-spot(使用 m7g.2xlarge,净可用 5039m / 20290MiB):**

- Prod 假设:峰值并发 4 个大批处理 Pod × 2000m/4096MiB = 8000m/16384MiB → `ceil(8000/5039)=2` 节点(CPU 主导)。
- Lab 假设:峰值并发 2 个批处理 Pod × 1000m/2048MiB = 2000m/4096MiB → 1 节点。

### 3.4 汇总:min / desired / max(计算结果,含 N+1 冗余考虑)

详细的每池定义(labels/taints/tolerations/EBS/成本/故障行为/适用负载)见 `docs/eks-node-group-design.md`;这里只列容量计算直接产出的数字。

| 节点池 | Lab min/desired/max | Prod min/desired/max(每 AZ,若拆分) |
|---|---|---|
| `system-on-demand` | 1 / 1 / 2 | 3 / 3 / 5 |
| `stateless-on-demand` | 0 / 0 / 3 | 1 / 2 / 8 |
| `stateless-spot` | 0 / 0 / 5 | 0 / 2 / 8 |
| `stateful-on-demand`(Lab)/ `stateful-az-a/b/c`(Prod,每个池独立) | 1 / 1 / 2 | 1 / 1 / 3(单个 AZ 池)→ 三池合计 3 / 3 / 9 |
| `batch-spot` | 0 / 0 / 2 | 0 / 0 / 6 |

**关于 `desired` 在 Karpenter 场景下的含义:** `system-on-demand` 与 `stateful-*` 使用 **EKS Managed Node Group**(ASG 语义,min/desired/max 是字面意义上的常驻值);`stateless-on-demand`/`stateless-spot`/`batch-spot` 使用 **Karpenter NodePool**(没有真正的"desired"概念,Karpenter 按 Pending Pod 反应式扩容、按 consolidation 策略缩容)。上表里 Karpenter 管理的池子的"desired"是**用于成本估算的典型稳态节点数**,不是需要在代码里配置的字面参数;`min`/`max` 分别对应 Karpenter NodePool 的 consolidation 下限(通常为 0)和 `limits` 资源上限换算出的节点数量级。详见 `docs/eks-node-group-design.md`。

---

## 4. 成本估算

**免责声明:** 以下单价为 us-east-1、Linux、Graviton 机型的**近似值**,仅用于数量级判断,正式预算前必须用 Infracost(`scripts/cost-check.sh`,目前是占位)或 AWS Pricing Calculator 核实当前实际价格。EKS 控制面固定收费 **$0.10/小时 ≈ $73/月**,Lab、Prod 都要付,与节点数量无关。

近似 On-Demand 时价(us-east-1):`m7g.large≈$0.0816/hr`、`m7g.xlarge≈$0.1632/hr`、`r7g.xlarge≈$0.2016/hr`、`m7g.2xlarge≈$0.3264/hr`。Spot 按 On-Demand 的 ~35% 估算(即约 65% 折扣,实际折扣随可用区/机型实时波动)。

### 4.1 Lab

| 版本 | 组成 | 月度计算成本估算(不含 EBS/NAT/流量) |
|---|---|---|
| **最低成本版本** | 只保留 `system-on-demand`(1×m7g.large),不预置 stateful 池,其余全部为 0 | 1×$59.57 + 控制面$73 ≈ **$133/月** |
| **推荐版本** | `system-on-demand`(1×m7g.large)+ `stateful-on-demand`(1×r7g.xlarge)+ 其余按需(平均按 0 估算基线) | 1×$59.57+1×$147.17+控制面$73 ≈ **$280/月** |

### 4.2 Production

| 版本 | 组成(取各池 min 或 desired) | 月度计算成本估算 |
|---|---|---|
| **最小可用版本(各池 min)** | system 3×m7g.large + stateless-on-demand 1×m7g.xlarge + stateful-az-* 3×r7g.xlarge(每 AZ 1 个)+ 控制面 | 3×$59.57+1×$119.14+3×$147.17+$73 ≈ **$812/月** |
| **推荐版本(各池 desired)** | system 3 + stateless-on-demand 2 + stateless-spot 2(spot 价)+ stateful-az-* 3 + 控制面 | 3×$59.57+2×$119.14+2×$41.72+3×$147.17+$73 ≈ **$1,015/月** |
| **峰值上限(各池 max,极端情况,不应长期维持)** | system 5 + stateless-on-demand 8 + stateless-spot 8(spot)+ stateful-az-* 9 + batch-spot 6(spot)+ 控制面 | ≈ **$3,482/月** |

**Production 月度成本区间:约 $812 – $3,482/月(计算资源部分),推荐版本基线约 $1,015/月。** 另需加上 EBS 存储成本(见 `docs/eks-storage-design.md`)和已有 network 模块的 NAT/流量成本(见 `docs/target-architecture.md` §5)。

### 4.3 主要费用来源

按占比从高到低:`stateful-az-*`(r7g.xlarge 单价最高,且强制 On-Demand、不能上 Spot)> `stateless-on-demand` 基线 > `system-on-demand`(必须 On-Demand,但机型较小)> `stateless-spot`/`batch-spot`(Spot 折扣后单价最低)> EKS 控制面固定成本。

### 4.4 可以关闭 / 不能缩容到 0 的资源

- **可以缩容到 0:** `stateless-spot`、`batch-spot`(始终可以);Lab 的 `stateless-on-demand`;Lab 的 `stateful-on-demand`(如果确实没有 stateful 负载在跑)。
- **不能缩容到 0:** `system-on-demand`(Lab min=1,Prod min=3——集群关键组件必须有地方跑);Prod 的 `stateful-az-a/b/c`(一旦有 stateful 负载调度上去,对应 AZ 池必须保持 min=1,否则数据不可用);Prod 的 `stateless-on-demand`(min=1,用于保证低延迟服务不会每次都冷启动)。

---

## 5. 待业务/待实测确认清单

- 本文档 §3.3 里的所有工作负载假设(服务数量、副本数、CPU/内存 request、HPA 上限)都是占位数字,真实服务清单确定后必须重新代入 §3.1/§3.2 的公式复算。
- DaemonSet 开销假设(300m CPU / 400MiB 内存/节点)需要在接入真实可观测性栈(日志/监控 agent 选型)后用实测数据校正。
- 成本估算里的单价需要在实现前用 Infracost 或 AWS Pricing Calculator 核实当前实际价格(尤其 Spot 折扣率会实时波动)。
- Stateful 负载的真实规格(CPU/内存/磁盘 IO 特征)决定了 `docs/eks-storage-design.md` 里 `gp3` vs `gp3-performance` 的选择,目前按"数据库类工作负载"的通用假设估算。
