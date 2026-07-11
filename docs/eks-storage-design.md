# EKS 存储设计(Storage Design)

**状态:** 设计已完成,待业务确认具体数据规模后再进入 `modules/eks` 实现(阶段 4b)。本文档只做设计,不产生任何 Terraform 代码或 AWS 资源。

节点池集合与容量计算见 `docs/eks-capacity-plan.md`;哪些节点池承载 stateful 工作负载、taints/tolerations 见 `docs/eks-node-group-design.md`。`stateful-*` 节点组默认关闭(`enable_stateful_node_groups=false`),本文档描述的 StorageClass/备份/销毁流程是**启用后**适用的设计,不代表现在就有任何 PVC 在跑。

> **本轮修订说明:** (1)§6 destroy 流程改为强制的有序销毁步骤,orphan EBS 检查是验收项而不是可选建议,并且明确 `reclaimPolicy=Delete` 不能保证绝对无残留;(2)§4 备份改成"EBS 快照只是块级恢复点,不代表应用可恢复"的表述,并按 PostgreSQL/Elasticsearch/VictoriaMetrics/Kafka/Jenkins 分别给出备份方向(仅方向,不在本 PR 实现)。

---

## 1. StorageClass 集合

| StorageClass | `type` | `reclaimPolicy` | 用途 |
|---|---|---|---|
| `gp3` | gp3(基线 3000 IOPS / 125MB/s,免费额度内) | `Delete` | 通用场景:缓存/scratch 卷、非关键数据、**Lab 默认使用的唯一 class** |
| `gp3-retain` | gp3(基线) | `Retain` | **Production 关键数据强制使用**:数据库、任何"PVC/StatefulSet 被误删也不能丢数据"的场景 |
| `gp3-performance` | gp3 + 提升 IOPS/吞吐(示例:`iops=6000`, `throughput=250`) | `Retain` | 高 IOPS 数据库、消息队列(如自建 Kafka)等基线吞吐不够用的场景;既然是性能敏感的重要负载,默认也走 Retain |

三个 StorageClass 统一配置:

```yaml
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  encrypted: "true"
  type: gp3
  # gp3-performance 额外声明 iops / throughput 参数
```

**为什么统一 `WaitForFirstConsumer`:** EBS 卷是可用区绑定资源,如果 StorageClass 用默认的 `Immediate` 绑定模式,PV 可能在 Pod 调度决策**之前**就已经创建并绑定到某个可用区,而 Pod 实际被调度到另一个可用区时就会直接失败。`WaitForFirstConsumer` 延迟到 Pod 完成调度决策后才创建/绑定卷,天然保证卷和 Pod 落在同一可用区——这一点对 `docs/eks-capacity-plan.md` §2 的 AZ 拆分设计(`stateful-az-a/b/c`)尤其关键,两者必须配合工作。

**为什么统一 `allowVolumeExpansion: true` + `encrypted: "true"`:** 见 requirements 安全基线(EBS 加密是强制项);扩容能力允许先按保守估计创建 PVC、后续按实际用量增长(见 §3)。

---

## 2. Lab 使用 Delete 还是 Retain

**Lab 默认统一使用 `gp3`(reclaim policy = `Delete`)。** `gp3-retain`/`gp3-performance` 这两个 class 在 Lab 里依然**存在**(方便工程师在 Lab 里预先验证 Retain/高性能配置的行为,不用等到 Prod 才第一次接触),但默认不作为 Lab StatefulSet 的默认选择。

理由:Lab 环境标签强制 `AutoDestroy=true`(见 `docs/target-architecture.md` §4),且 requirements 明确"Lab 不允许保存生产敏感数据"——Lab 里的数据本来就应该是随时可丢的,`Delete` 策略配合整体销毁流程,能保证 `terraform destroy`/`make lab-destroy` 之后不留残余 EBS 卷(呼应 §7 的 orphan 检查)。

**Production 关键数据必须使用 `gp3-retain` 或 `gp3-performance`。** 判断"是否关键"的标准:该数据丢失是否会造成不可恢复的业务损失或需要从外部系统重新导入——数据库、消息队列的持久化数据都归入此类;纯缓存/可重建的临时数据仍可使用 `gp3`(Delete)。

---

## 3. PVC 初始大小与扩容流程

### 初始大小(占位假设,待业务确认真实数据量后调整)

| 工作负载类型 | Lab 初始 PVC 大小 | Prod 初始 PVC 大小 |
|---|---|---|
| 通用 scratch/缓存卷 | 10GiB | 10GiB |
| 数据库类(主 + 副本) | 50GiB | 100GiB |
| 消息队列类 | 30GiB | 80GiB |

原则:初始值按"预期数据量 + 明显但不过度的增长缓冲"估算,不做一次性大额预置——依赖下面的在线扩容能力按实际增长追加,避免为不确定的未来用量长期多付 EBS 费用。

### 扩容流程

1. 编辑对应 PVC 的 `spec.resources.requests.storage`,改为更大的值(必须 ≥ 当前值,EBS/CSI 不支持在线缩容)。
2. EBS 卷通过 CSI 在线扩容(`allowVolumeExpansion: true`),无需卸载卷。
3. 文件系统层扩容:多数情况下 CSI node 插件会在下一次挂载刷新时自动扩展文件系统;个别文件系统/CSI 版本组合可能需要重启一次 Pod 才能让文件系统感知到新容量,操作前查阅当时 EBS CSI driver 版本的已知限制。
4. 扩容后进入 Pod 用 `df -h` 验证实际可用空间已增长。
5. **注意冷却时间:** 同一块 EBS 卷两次 `ModifyVolume`(包括扩容)之间建议至少间隔 6 小时,过于频繁的扩容请求可能被 AWS 限流——按增长趋势提前规划,不要"用多少扩多少"地频繁小步扩容。

---

## 4. 备份

### EBS Snapshot 的定位:只是块级恢复点,不是备份策略本身

**EBS/CSI 快照是一个块级恢复点,不代表应用数据可恢复、也不代表满足了任何 RPO/RTO 目标。** 快照能保证的只是"某一时刻磁盘块的副本存在",不保证:文件系统/数据库内部结构在那一刻是一致的、恢复后应用能正常启动、恢复所需时间符合业务预期。**生产环境的真实恢复能力,必须由应用原生备份机制、定期的恢复演练(restore drill)、以及针对 RPO/RTO 目标的验证共同建立——只配置好 `VolumeSnapshotClass` 并不构成"已经有备份"。**

基础设施层面仍然需要:通过 `VolumeSnapshotClass`(对接 EBS CSI driver 的快照能力)+ AWS Backup 或 Velero 按 Schedule 自动创建快照,设置保留天数(占位建议:每日快照,保留 7–14 天,具体保留策略待业务确认合规/RPO 要求)。但这只是"应用原生备份"的补充/兜底,不是替代。

### 分组件的备份方向(仅方向,具体实现留给对应组件上线时的独立设计,不在本 PR 实现)

| 组件 | 备份方向 |
|---|---|
| **PostgreSQL** | WAL 归档 + 基础备份(`pgBackRest`/`WAL-G`/`pg_basebackup`)支持时间点恢复(PITR);逻辑备份(`pg_dump`)作为便携、可跨版本恢复的补充;**必须定期做恢复演练**,验证从备份实际拉起一个可用实例所需时间是否满足 RTO。 |
| **Elasticsearch** | 使用原生 Snapshot API(`_snapshot`,S3 repository 插件),按索引/分片增量快照——这是应用感知的一致性备份,**不要**对 Elasticsearch 数据节点直接做块级 EBS 快照当作主要备份手段。 |
| **VictoriaMetrics** | 使用原生 `vmbackup`/`vmrestore` 工具对接对象存储(S3),理解 VictoriaMetrics 自身的存储格式、支持增量;EBS 快照可以作为最后手段但会丢失 vmbackup 的空间效率优势。VictoriaMetrics 没有 AWS 托管等价物(见 `docs/eks-capacity-plan.md` §2 方案 D),因此无论最终节点组选型如何,它的备份问题都需要独立解决。 |
| **Kafka** | 数据持久性首先依赖 **副本因子 ≥3、跨可用区分布**的 broker 设计,这是主要的可靠性机制,不是"备份"。真正的备份/灾备需求用 MirrorMaker2 复制到独立的备用集群,或用 Kafka Connect S3 Sink Connector 做主题数据的持久归档;broker 卷的 EBS 快照只是最后兜底手段。 |
| **Jenkins** | Jenkins Home(job 定义、插件、凭证库、配置)通过定期 tar/rsync 到 S3 的方式备份;更根本的方向是用 Configuration-as-Code(JCasC)把 Jenkins 配置声明化,使其本身可从代码重建而不完全依赖备份恢复。当前 Jenkins 跑在 EC2(`part1-jenkins-from-terraform`),备份需求同时记录在 `docs/current-state-assessment.md` 的既有差距里,不完全属于本 EKS 存储设计的范围;如果未来 Jenkins Agent/流水线组件迁移到 EKS,这里的方向同样适用。 |

以上均为方向性说明,具体备份工具选型、Schedule、恢复演练流程,留待每个组件真正确定要自建(而不是走 `docs/eks-capacity-plan.md` §2 方案 D 的托管服务)之后再补充到本文档或对应组件的独立设计里。

---

## 5. StatefulSet 与可用区绑定

- PV 一旦创建,`topology.kubernetes.io/zone` 节点亲和(由 `WaitForFirstConsumer` + EBS CSI driver 自动写入)就**永久固定**了该卷所在可用区——这个绑定关系不会随节点池扩缩容而改变。
- 对应到 `docs/eks-node-group-design.md` 的设计:Production 的 `stateful-az-a/b/c` 三个池子,与已存在的 PV 可用区分布必须始终匹配。
- **操作风险提示:** 绝不能在某个 `stateful-az-*` 池仍有存活 PVC 引用的情况下直接删除/清空该池——这会让对应 PVC 永久失去可调度节点。如果确实需要下线某个可用区的 stateful 容量,必须先完成"跨可用区数据迁移"(基于 §4 的快照/备份能力,在目标可用区新建卷并恢复数据),迁移确认完成后才能移除原节点池,这个操作本身也需要单独的、经过审查的 PR,不属于本设计文档或阶段 4a/4b 的范围。

---

## 6. 有序销毁与 Orphan EBS 检查(强制验收项)

**`reclaimPolicy=Delete` 不能保证 `terraform destroy` 之后绝对没有残留。** `Delete` 策略依赖 Kubernetes 的正常回收链路(PVC 删除 → PV 删除 → EBS CSI controller 收到 PV 删除事件 → 调用 AWS API 删除底层 EBS 卷)完整跑完;如果 `terraform destroy` 直接把 EKS 集群/节点组/VPC 一起拆掉,而不是先让 Kubernetes 完成对象级别的清理,CSI controller 可能根本来不及处理这个回收链路(它自己所在的节点已经被销毁、或者集群 API 已经不可达)——即使所有 StorageClass 都配置的是 `Delete`,同样可能产生孤儿 EBS 卷。`gp3-retain`/`gp3-performance` 的 `Retain` 策略则是**设计上就不会**被自动删除,这部分残留是预期行为,不是 bug,但同样需要被检查到、而不是被遗忘。

### 强制的 Lab 销毁顺序

`scripts/infra.sh lab destroy`(目前是阶段 0/1 的占位骨架,真正接入以下顺序留给阶段 4b 或专门的销毁流程 PR,这里先把顺序定下来)必须按以下顺序执行,不能跳步、不能把 K8s 层清理和 Terraform 层销毁揉在一起:

1. **删除应用 / StatefulSet**(`kubectl delete` 对应的 Deployment/StatefulSet,或直接删除 namespace)。
2. **删除 PVC**——触发 `Delete` 策略的 PV/EBS 回收链路开始执行。
3. **等待 PV 和底层 EBS 卷实际删除完成**(轮询确认,不是发出删除请求就假定已完成——EBS 卷删除不是瞬时的)。
4. **执行 orphan EBS 检查**(见下)——确认没有意外残留(`Retain` 卷会被检查到但预期存在,`Delete` 卷理论上此时应该已经不存在,如果还存在说明回收链路没跑完,需要在继续销毁前处理)。
5. **删除 Node Group**(Managed Node Group / Karpenter NodePool)。
6. **删除 EKS Cluster**。
7. **删除网络**(VPC/子网等,`modules/network` 范畴)。

这个顺序对 Prod 同样适用,只是第 4 步之后 Prod 默认不自动删除任何东西(见下)。

### Orphan EBS 检查——销毁验收的强制项,不是可选建议

1. 按集群名/`kubernetes.io/cluster/<name>` 标签或本仓库强制的 `Project`/`Environment` 标签(见 `docs/target-architecture.md` §5.3),列出状态为 `available`(未挂载)的 EBS 卷。
2. **这一步是 Destroy 流程的强制验收项**——`scripts/infra.sh <env> destroy` 在完成上面 §6 的顺序之后,必须报告 orphan EBS 检查结果,销毁报告里没有这一项视为销毁流程不完整,不能视为"已销毁干净"。
3. **Lab:** 检查后默认提示是否删除残留卷(Lab 不允许保留生产敏感数据,残留卷没有保留价值)。
4. **Prod:** 只报告、不自动删除——残留可能是有意的数据保留(`Retain` 策略),也可能是回收链路未完成的真实问题,两种情况都需要人工判断,不能自动处理;检查结果必须记录在销毁报告里(呼应 requirements §10.3"Destroy 后检查残留资源"、§9"Destroy 后执行残留检查")。

---

## 7. EBS 成本优化

- 全线使用 `gp3` 而不是旧的 `gp2`——同等基线性能下 gp3 单价更低,且性能(IOPS/吞吐)与容量解耦,不需要靠加大容量来换取更高 IOPS。
- 初始 PVC 大小按 §3 的保守估算创建,依赖在线扩容按真实增长追加,不预先超配。
- 定期审查 §6 的 orphan 检查结果,避免 Retain 策略产生的孤儿卷无限期计费。
- 快照保留策略设置上限(见 §4),避免快照数量随时间无限增长、悄悄变成第二笔隐藏的存储账单。
- 只有真正 IOPS 受限的工作负载才使用 `gp3-performance`(需要额外 IOPS/吞吐是要单独计费的,见下面成本示例)——大多数场景 `gp3`/`gp3-retain` 的基线性能已经足够,不要默认全上性能档。

### 成本示例(近似值,us-east-1,需要 Infracost/AWS Pricing Calculator 核实)

- `gp3` 基线:约 $0.08/GB-月,基线 3000 IOPS / 125MB/s 免费。
- `gp3-performance` 额外开销示例(在基线之上 +3000 IOPS、+125MB/s):IOPS 每单位约 $0.005/IOPS-月、吞吐每单位约 $0.04/(MB/s)-月 → 额外 IOPS 成本 ≈ 3000×$0.005=$15/月,额外吞吐成本 ≈ 125×$0.04=$5/月,一块性能盘比同容量基线盘每月多付约 $20(与容量费叠加,不含容量本身)。
- Lab 日常存储成本估算(root volume,`stateful-*` 关闭时,不含 PVC):仅 `system`(20GiB)× $0.08 ≈ **$1.6/月**。测试期间临时启用 `stateful-on-demand`(+50GiB)会额外增加 ≈$4/月,测试结束应随节点组一起关闭。
- Prod 存储成本估算(root volume,desired 配置,不含 PVC,假设 `stateful-*` 已按方案 B 启用):`system` 3×20GiB + `stateless-on-demand` 2×20GiB + `stateless-spot` 2×20GiB + `stateful-az-*` 3×50GiB = 290GiB × $0.08 ≈ **$23.2/月**;`stateful-*` 未启用时对应减少 150GiB,约 **$11.2/月**。
- PVC 本身的存储成本取决于 §3 的初始大小假设与真实数据量,待业务确认后单独核算,不包含在上述 root volume 估算内。
