# EKS 存储设计(Storage Design)

**状态:** 设计已完成,待业务确认具体数据规模后再进入 `modules/eks` 实现(阶段 4b)。本文档只做设计,不产生任何 Terraform 代码或 AWS 资源。

节点池集合与容量计算见 `docs/eks-capacity-plan.md`;哪些节点池承载 stateful 工作负载、taints/tolerations 见 `docs/eks-node-group-design.md`。

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

### EBS Snapshot

Production 关键数据(`gp3-retain`/`gp3-performance` 卷)需要定期快照,建议通过 `VolumeSnapshotClass`(对接 EBS CSI driver 的快照能力)+ AWS Backup 或 Velero 实现按 Schedule 自动创建,并设置保留天数(占位建议:每日快照,保留 7–14 天,具体保留策略待业务确认合规/RPO 要求)。

### 应用一致性备份

EBS/CSI 快照本身只是**崩溃一致性**(crash-consistent)——相当于突然断电时刻的磁盘状态,对大多数现代数据库是安全的,但不保证"事务级"一致性,尤其是有独立 WAL/日志目录挂载在不同卷、或者应用层有内存缓冲未落盘的场景。对于 Production 数据库类工作负载,建议:

- 使用应用原生的一致性备份工具(如 `pg_basebackup`/逻辑 dump,而不是仅依赖块级快照);或
- 如果依赖块级快照,备份前用 Velero 的 pre/post hook(或应用自身的 quiesce 机制)先让应用flush 缓冲区、短暂暂停写入,快照完成后再恢复写入,确保快照那一刻是应用一致的。

具体选哪种方式因数据库/中间件类型而异,留待真实 stateful 工作负载选型确定后再补充到本文档。

---

## 5. StatefulSet 与可用区绑定

- PV 一旦创建,`topology.kubernetes.io/zone` 节点亲和(由 `WaitForFirstConsumer` + EBS CSI driver 自动写入)就**永久固定**了该卷所在可用区——这个绑定关系不会随节点池扩缩容而改变。
- 对应到 `docs/eks-node-group-design.md` 的设计:Production 的 `stateful-az-a/b/c` 三个池子,与已存在的 PV 可用区分布必须始终匹配。
- **操作风险提示:** 绝不能在某个 `stateful-az-*` 池仍有存活 PVC 引用的情况下直接删除/清空该池——这会让对应 PVC 永久失去可调度节点。如果确实需要下线某个可用区的 stateful 容量,必须先完成"跨可用区数据迁移"(基于 §4 的快照/备份能力,在目标可用区新建卷并恢复数据),迁移确认完成后才能移除原节点池,这个操作本身也需要单独的、经过审查的 PR,不属于本设计文档或阶段 4a/4b 的范围。

---

## 6. Destroy 后 Orphan EBS 检查

因为 `gp3-retain`/`gp3-performance` 的 reclaim policy 是 `Retain`,`terraform destroy`(或 `make lab-destroy`/`make prod-plan` 对应的销毁流程)**不会**删除这些卷背后的 EBS 资源——PV 被删除后,底层 EBS 卷会变成"未挂载但仍然存在"的孤儿资源,继续计费。

要求:`scripts/infra.sh <env> destroy` 在执行 `terraform destroy` 之后,必须新增一步残留检查(目前 `scripts/infra.sh` 还是阶段 0/1 的占位骨架,真正接入这一步留给阶段 4b 或专门的销毁流程 PR,这里先把要求写清楚):

1. 按集群名/`kubernetes.io/cluster/<name>` 标签或本仓库强制的 `Project`/`Environment` 标签(见 `docs/target-architecture.md` §5.3),列出状态为 `available`(未挂载)的 EBS 卷。
2. **Lab:** 默认直接提示是否删除(Lab 不允许保留生产敏感数据,残留卷没有保留价值)。
3. **Prod:** 只报告、不自动删除——残留可能是有意的数据保留,必须人工确认后再手动删除,并记录在销毁报告里(呼应 requirements §10.3"Destroy 后检查残留资源"、§9"Destroy 后执行残留检查")。

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
- Lab 存储成本估算(root volume,不含 PVC):`system`(20GiB)+`stateful`(50GiB)=70GiB × $0.08 ≈ **$5.6/月**。
- Prod 存储成本估算(root volume,desired 配置,不含 PVC):`system` 3×20GiB + `stateless-on-demand` 2×20GiB + `stateless-spot` 2×20GiB + `stateful-az-*` 3×50GiB = 290GiB × $0.08 ≈ **$23.2/月**。
- PVC 本身的存储成本取决于 §3 的初始大小假设与真实数据量,待业务确认后单独核算,不包含在上述 root volume 估算内。
