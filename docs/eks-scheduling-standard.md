# EKS 调度标准(Scheduling Standard)

**状态:** 设计已完成,待业务确认具体工作负载数据后再进入 `modules/eks` 实现(阶段 4b)。本文档只做设计,不产生任何 Terraform 代码或 AWS 资源。

节点池集合与容量计算见 `docs/eks-capacity-plan.md`;节点池的 labels/taints/tolerations 具体取值、架构(arm64/amd64)调度示例见 `docs/eks-node-group-design.md`。本文档定义 Pod 层面(HPA/VPA)与节点层面(Karpenter/Managed Node Group)之间的职责边界,以及四条结构性禁止项的落地方式。

> **本轮修订说明:** Karpenter 管理的节点池不再有 `min/desired/max` 语义(见 `docs/eks-capacity-plan.md` §3.4/§4),下面 §1 的表述已同步更新。`stateful-*` 默认关闭(`enable_stateful_node_groups=false`),具体形态见 capacity-plan §2 的方案 A/B/C/D。

---

## 1. 职责边界

| 层面 | 负责组件 | 管什么 | 不管什么 |
|---|---|---|---|
| Pod 副本数量 | **HPA**(Horizontal Pod Autoscaler) | 根据 CPU/内存/自定义指标动态调整 Deployment/StatefulSet 的副本数 | 不调整单个 Pod 的资源 request/limit,不管节点数量 |
| Pod 资源请求(第一阶段) | **VPA**(Vertical Pod Autoscaler),`updateMode: "Off"` | 只生成 CPU/内存 request 的推荐值,写入 `VerticalPodAutoscalerCheckpoint`,供人工审阅 | **不自动重启 Pod、不自动修改 request/limit**——Phase 1 严禁 `Auto`/`Initial`/`Recreate` 模式 |
| 节点数量 | **Karpenter**(`stateless-on-demand`/`stateless-spot`/`batch-spot`)或 **Managed Node Group ASG**(`system-on-demand`,若启用的 `stateful-*`) | Karpenter:根据 Pending Pod 反应式扩容节点、按 `consolidation_policy` 缩容,受 `cpu_limit`/`memory_limit` 约束,没有 min 语义;Managed Node Group:按 `min_size`/`desired_size`/`max_size` 静态维持基线 | 不管 Pod 副本数量,不管 Pod 内部资源 request 取值。Karpenter 池子"总有一点基线容量"这件事,由 Deployment `minReplicas`+`PodDisruptionBudget`+`PriorityClass` 在 Pod 层面保证,不是节点层面的职责(详见 `docs/eks-capacity-plan.md` §3.4) |

**目标利用率 65%–70%**(与 `docs/eks-capacity-plan.md` 容量计算保持一致)是 HPA 扩容阈值与 Karpenter 触发新增节点之间共同的设计基准——HPA 让 Pod 数量匹配负载,Karpenter/ASG 让节点数量匹配 Pod 数量,两者独立运作、互不覆盖对方的职责。

### VPA Phase 1 = Recommendation/Off 的原因

1. 避免与 HPA 产生指标冲突(见下面禁止项 2)。
2. 先积累至少一个完整业务周期(建议 ≥2 周)的推荐数据,由人工审阅后再决定是否对特定工作负载放开到 `Initial`(仅新建 Pod 时生效)或 `Auto`(允许自动重建 Pod)模式——每个工作负载单独评估,不做集群级别的一刀切放开。

---

## 2. Deployment 与 StatefulSet 的调度隔离标准

调度隔离完全依赖 `docs/eks-node-group-design.md` §6 定义的 `dedicated=<pool>` labels/taints/tolerations 体系:

- 每个 Deployment/StatefulSet 的 PodSpec 必须显式声明:
  - `nodeSelector`(或 `nodeAffinity`)指向目标节点池的 `dedicated` label;
  - 与目标节点池 taint 匹配的 `tolerations`。
- 不依赖任何隐式/默认调度行为——没有携带正确 nodeSelector+toleration 组合的 Pod,在所有节点池上都会因为 taint 而无法调度(`Pending` + 明确的调度失败事件),这是有意为之的"快速失败"设计,防止工作负载意外落到错误的节点池上,污染容量计算和成本归因。
- 具体到 StatefulSet:仅在 `enable_stateful_node_groups=true` 且已按 `docs/eks-capacity-plan.md` §2 选定方案(A/B/C 之一)之后才会被调度——必须使用对应方案的 nodeSelector+toleration 组合(方案 A/B 是 `stateful-on-demand` 或 `stateful-az-a/b/c`,方案 C 是待定的 Karpenter NodePool),且**不允许**同时携带任何 `node-lifecycle=spot` 相关的 toleration(见下面禁止项 1 的强制手段)。
- 架构(arm64/amd64)是叠加在这套 taint/toleration 体系之上的另一个调度维度,不是替代——具体规则和 YAML 示例见 `docs/eks-node-group-design.md` §7。

---

## 3. 四条结构性禁止项与落地方式

### 禁止项 1:StatefulSet 使用 Spot

**落地方式:**
- `stateful-on-demand`/`stateful-az-a/b/c` 三类节点池在 Karpenter NodePool / Managed Node Group 层面**只声明 On-Demand capacity type**,物理上不存在可供调度的 Spot 节点。
- 所有 StatefulSet 的 tolerations 列表里**不出现**任何 spot 相关 taint 的容忍(`node-lifecycle=spot` 一类)——即使运维手误加了 toleration,由于对应池子里根本没有 Spot 节点,依然无法真正调度上去。
- CI 阶段(未来 `lab-plan`/`prod-plan` workflow)建议加一条静态检查:扫描所有 StatefulSet manifest,若 tolerations 中出现 spot 相关 key 则直接拒绝(留待 CI/CD 工作流阶段实现,本 PR 不实现)。

### 禁止项 2:HPA 和 VPA 同时自动修改同一 CPU 指标

**落地方式:**
- Phase 1(本设计覆盖范围):**全集群** VPA 统一 `updateMode: "Off"`,因此不存在"VPA 自动修改"的情况,这条禁止项在 Phase 1 天然满足,不需要额外机制。
- Phase 1 之后,若某个工作负载要把 VPA 从 `Off` 升级为 `Initial`/`Auto`:
  - 若该工作负载的 HPA 是基于 **CPU** 指标,则 VPA 的 `resourcePolicy` 必须把 CPU 排除在自动调整范围外(只保留内存或自定义指标的自动推荐/调整),或者反过来把 HPA 改成非 CPU 指标(内存/自定义业务指标),两者**永远不允许同时以 CPU 作为自动调整的信号来源**。
  - 这个约束在每个工作负载"升级 VPA 模式"的评审 checklist 里作为强制项,不做集群级别的自动化强制(留待有实际工作负载后再评估是否值得写 admission webhook)。

### 禁止项 3:System 组件运行在可缩容到 0 的节点池

**落地方式:**
- `system-on-demand` 使用 Managed Node Group,`min_size` 恒 ≥1(Lab=1,Prod=3),不是 Karpenter 管理的可缩容到 0 的池子——结构上不可能缩容到 0。
- `system-on-demand` 携带独占 taint(`dedicated=system:NoSchedule`),其他工作负载无法挤占这个池子的容量,避免"表面上节点没缩到 0,但被别的负载占满导致 system 组件被驱逐"的变相风险。
- 集群关键组件的 Deployment 必须配置 `PodDisruptionBudget`(见 `docs/eks-node-group-design.md` §1),进一步保证节点替换/滚动升级期间不会出现全灭。

### 禁止项 4:Karpenter Controller 运行在 Karpenter 自己管理的临时节点上

**落地方式:**
- Karpenter Controller 的 Deployment 显式设置 `nodeSelector: dedicated=system` + 对应 toleration,只能调度到 `system-on-demand`(Managed Node Group,非 Karpenter 管理)。
- 额外加一条反亲和/nodeAffinity 规则,明确排除任何带 `node-lifecycle=spot` 或 Karpenter 自身打的 provisioner 标签(如 `karpenter.sh/nodepool` 存在即排除)的节点,双重保证——即使 taint/toleration 配置出现疏漏,反亲和规则仍能兜底阻止 Karpenter Controller 落到自己管理的节点上,避免"Karpenter 决定回收某节点时把自己也回收掉"的自杀式故障。

---

## 4. 与节点池设计的一致性检查清单

在 `modules/eks` 实现(阶段 4b)时,以下几点必须与 `docs/eks-node-group-design.md` 保持逐项一致,作为该模块 PR 的自检项:

- [ ] 每个节点池的 taint key/value 与本文档、`docs/eks-node-group-design.md` 完全一致
- [ ] 每类工作负载的 Helm chart / manifest 模板携带正确的 nodeSelector + toleration
- [ ] `stateful-*` 节点池在 Terraform 层面就不具备 Spot capacity type 选项(不是靠约定,而是配置上物理不存在)
- [ ] VPA 资源(若已创建)全部 `updateMode: "Off"`
- [ ] Karpenter Controller 的 Deployment spec 包含 §3 禁止项 4 的 nodeSelector + 反亲和配置
- [ ] `system-on-demand`、`stateful-*` 上的关键 Deployment/StatefulSet 都配置了 `PodDisruptionBudget`
