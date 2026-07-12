# ADR-0005:Terraform State Architecture

**状态:** 待定(Proposed)——本 ADR 只完成 Architecture Review 并给出建议,不创建任何 Workspace,不修改任何 `environments/*/versions.tf`。等待你确认后,才会有后续 PR 去实际接线。

## 背景

Plan-1001(Phase 7,HCP Terraform Readiness)发现 `environments/lab/versions.tf` 里完全没有 `cloud {}`/`backend` 块。随后你给出了这个片段:

```hcl
terraform {
  required_version = "1.15.8"

  cloud {
    organization = "operationarvin"
    workspaces {
      name = "devops-terraform-jenkins-eks"
    }
  }
}
```

这个 workspace 名字(`devops-terraform-jenkins-eks`,无环境后缀)如果被原样复制进不止一个 `environments/*/versions.tf`,会让多个环境共享同一个 Terraform State。本 ADR 是在你要求"先做 Architecture Review,不要直接改"之后的正式审查记录。

## 核心原则

```text
One Environment
  ↓
One Workspace
  ↓
One Terraform State
```

任何时候,任何一个 HCP Terraform workspace 都只服务于 `environments/` 下的一个目录。没有例外。

---

## Task 1:当前 State Architecture 现状(引用实际代码,不猜)

逐一检查每个环境目录的 `versions.tf`:

- **`environments/lab/versions.tf`**(`git grep -n "cloud\|backend"`):只有一段注释("Backend intentionally not declared here yet — ADR-0002 ... is still open"),没有任何 `cloud {}` 或 `backend` 块。
- **`environments/prod/versions.tf`**(已读取全文):同样没有 `cloud {}`/`backend` 块,注释明确写着"Production must use a state target fully independent from lab/staging (own bucket key or own HCP Terraform workspace) with a restricted IAM role"——独立性要求**已经写在代码注释里**,只是还没有被强制执行成真正的配置。
- **`environments/staging/`**:整个目录只有一个占位 `README.md`("Status: not yet scaffolded"),没有任何 `.tf` 文件——目前根本不存在可以指向任何 workspace 的 Terraform 配置。

**结论:今天,Lab / Staging / Prod 之间不存在任何 State 共享——因为压根没有任何一个环境接了远程 backend。** 三个环境目前都只会用 Terraform 默认的本地 backend(如果有人在本地跑 `terraform init && terraform apply` 的话,状态文件躺在那台机器的磁盘上,既不共享也不持久、不团队可见——这是另一个问题,不等于"隔离做对了")。

**风险是前瞻性的,不是现状的:** `docs/target-architecture.md` §3 和 `docs/current-state-assessment.md` §6 记录的 HCP Terraform Cloud workspace `operationarvin/infra-aws/devops-terraform-jenkins-eks`(`execution-mode=local`、`auto-apply=false`)确实已经通过 VCS 连接到这个仓库——但连接一个 workspace 到仓库,和某个具体的 `environments/<env>/versions.tf` 用代码指向它,是两件事。`environments/lab/backend.hcl.example` 里已经有一行注释预见到了这个问题:`# or a dedicated "-lab" workspace`——说明这个歧义在原始设计时就被注意到了,只是没有被最终定下来。ADR-0002 的"决策"一节也倾向于"把现有 workspace 当 lab 用,以后再加其他环境的兄弟 workspace"——这个方向本身是对的,本 ADR 是把它落成一个可执行、可检查的命名标准。

---

## Task 2:长期 Workspace Standard

```text
operationarvin (HCP Terraform organization)
  │
  ├── devops-terraform-jenkins-eks-lab       ← environments/lab/
  ├── devops-terraform-jenkins-eks-staging   ← environments/staging/
  └── devops-terraform-jenkins-eks-prod      ← environments/prod/
```

**规则:** 每个 `environments/<env>/` 目录的 `versions.tf` 只能有一个 `cloud { workspaces { name = "..." } }` 块,且这个 workspace 名字在全组织范围内只能被这一个目录引用。命名规则:`<repo-name>-<environment>`——沿用已经连接好的 workspace 的实际命名方式(`devops-terraform-jenkins-eks`),而不是 ADR-0002"影响"一节里提到的 `wcd-<project>-<environment>`(那条规则是给 **AWS 资源命名**(`var.project`="wcd-platform")用的,和 HCP Terraform **workspace 命名**是两个独立的命名空间——这里明确分开,避免以后混用两套规则)。

注:任务描述里的图示用了 `stage`,但仓库实际目录是 `environments/staging/`——本 ADR 统一使用 `staging`,以匹配实际代码,不引入一个不存在的目录名。

**为什么现有的单一 workspace 不需要作废重建:** 现有 workspace `devops-terraform-jenkins-eks` today 没有被任何环境的代码指向(Task 1 的结论),所以把它正式确立为 `devops-terraform-jenkins-eks-lab`(改名,而不是新建)、再新建 `-staging`/`-prod` 两个兄弟 workspace,是唯一需要的变更——不存在"迁移一个已经在用的 workspace"的风险,因为它现在还没有被任何代码真正用起来。

---

## Task 3:Branch Strategy Review

```text
main   ──(VCS trigger)──▶  devops-terraform-jenkins-eks-prod   (working directory: environments/prod)
lab    ──(VCS trigger)──▶  devops-terraform-jenkins-eks-lab    (working directory: environments/lab)
staging (待创建) ──(VCS trigger)──▶  devops-terraform-jenkins-eks-staging (working directory: environments/staging)
```

**Workspace 应该绑定 Branch 吗?是的。** HCP Terraform 的 VCS 连接原生支持"这个 workspace 只在指定分支变化时触发"——把每个环境的 workspace 绑定到它自己的 git 分支,是让"哪个分支的改动会影响哪个环境"变成结构性保证,而不是靠人记住"不要在 `main` 上跑 `lab` 的 tfvars"这种约定。这与仓库已有的分支策略(`feature/* → Draft PR → lab`,之后 `lab → main`)完全对齐,不需要引入新的分支模型。

**是否支持 Lab → Staging → Prod Promotion?支持,但"晋升"的对象是代码,不是 State。** 这里的 Terraform/GitOps 语境下,"promotion" 从来不是把 Lab 的某个 State 文件搬到 Prod(Lab 和 Prod 是完全独立的 AWS 资源,没有什么"实例"可搬)——真正被晋升的是**已经在 Lab 通过验证的 Terraform 代码**,晋升机制就是 git merge 本身:改动先在 `feature/*` 分支上完成、经 `lab` workspace 验证过 plan/apply 之后,合并进 `main`,`prod` workspace(绑定 `main` 分支)据此触发它自己独立的 plan,走人工审批后 apply。`staging` 一旦真正搭建,会插在这个链条中间,用同样的机制(自己的分支、自己的 workspace)。HCP Terraform 本身没有,也不需要"跨 workspace 搬运 state" 这种功能——那是基础设施代码模型下一个反模式,不是缺失的能力。

---

## Task 4:OIDC Review

**必须先拆开两条不同的信任关系,任务描述里的"GitHub → HCP Terraform → AWS"其实是两跳,不是一条链:**

1. **GitHub(VCS)→ HCP Terraform:** 这不是一个 IAM AssumeRole 关系——是 HCP Terraform 原生的 VCS 集成(webhook 触发 + 读取仓库内容的授权),今天已经部分连接好了(`execution-mode=local`)。这一跳不涉及 AWS 凭证。
2. **HCP Terraform → AWS:** 这才是真正需要 OIDC 的地方。HCP Terraform 支持 [Dynamic Provider Credentials](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials)——每个 **workspace** 拿到一个独立的 OIDC token,拿去换 AWS STS 的临时凭证,信任策略可以按 workspace 精确限定。**这正是"每个环境一个 workspace"在安全层面真正的价值所在**,不只是 state 隔离:Lab workspace 的 OIDC 信任只能换到 Lab 范围的 IAM 角色,Prod workspace 只能换到 Prod 范围的角色——State 隔离(Task 1-2)+ 权限隔离(这里)是两层独立的防线,不是同一件事的两种说法。

ADR-0003 目前的标题和范围是 **GitHub Actions → AWS**(用于 CI 自己需要跑 AWS 相关检查的场景)——这是**第三条**、和上面两跳都不同的路径。如果最终执行模式选 `execution-mode=remote`(plan/apply 都在 HCP Terraform 里跑,而不是在 GitHub Actions runner 里跑),那么 Terraform 的 AWS 访问完全走"HCP Terraform → AWS"这条路径,ADR-0003 描述的"GitHub Actions → AWS"就不是 Terraform 执行的阻塞前提——GitHub Actions 那时只需要保持现状(`fmt`/`validate`/lint,零 AWS 权限),这与 `wcd-engineering` 仓库里 Identity Boundary Standard("GitHub Actions is CI only, unless explicitly approved otherwise" / "HCP Terraform is responsible for Terraform Plan, Apply, and State, exclusively")的原则完全一致——本 ADR 是那份组织级标准在这个仓库里的具体落地,不是另立门户。

**Secrets 是否全部保存在 HCP Terraform,不进 Git Repository?** 当前状态核实(不是假设):
- 全仓库 `git grep` 静态 AWS 密钥模式(`AKIA...`、`aws_secret_access_key = "..."`):**未发现任何匹配。**
- `part1-jenkins-from-terraform/terraform.tfvars`、`part2-.../terraform.tfvars`(两个已提交的遗留文件):内容只有 CIDR/机型等非敏感配置,**没有凭证**。
- 所有新代码路径(`environments/*/terraform.tfvars.example`)都只是 `.example` 文件,真正的 `terraform.tfvars` 被 `.gitignore` 排除,从未提交。

**结论:现状已经满足"Git 仓库里没有 secrets"——这是要维持的现状,不是要修的问题。** 一旦 Dynamic Provider Credentials(OIDC)真正接线,连"临时凭证"都不会以任何形式出现在 Git 仓库或 CI 日志里——凭证只存在于 HCP Terraform workspace 运行时的内存中。

---

## Task 5:Destroy Strategy Review——Lab Destroy 会影响 Stage/Prod 吗?

**不会,而且是三层独立防线共同保证的,不是单一机制:**

1. **State 隔离(Task 1-2):** 一旦"一环境一 workspace"落地,`terraform destroy` 只能对着它所指向的那一个 workspace 的 state 操作——Lab workspace 的 state 里根本不存在任何 Prod 资源的地址,Terraform 物理上没有办法销毁一个不在自己 state 里的资源。
2. **AWS 资源命名空间隔离:** Lab 和 Prod 是完全独立的 VPC/子网/集群等资源(不同的 AWS 资源 ID),即使误操作也没有 ID 碰撞的可能——`docs/eks-lab-destroy.md`(Plan-1001 review 已确认)描述的是**workload 层面**的销毁顺序(先删 K8s 对象,再删节点组,再删集群,最后删网络),这是同一个环境内部的顺序要求,不是跨环境的保护机制,两者不要混为一谈。
3. **IAM 权限边界隔离(Task 4 的产出):** 一旦 OIDC 按 workspace 精确限定角色,Lab workspace 拿到的 AWS 凭证本身就没有权限触碰任何打了 Prod 标签/在 Prod 账号(如果未来采用多账号模型)里的资源——即使 State 隔离出于某种原因失效,IAM 边界仍然独立生效。

**当前状态下这个问题的答案更简单:** 因为目前没有任何环境真正 apply 过(Plan-1001 Phase 7 已确认——本环境没有 AWS 凭证,从未执行过 apply),所以"Lab destroy 影响 Prod"在今天是一个不可能发生的假设性问题——Prod 里没有任何资源存在。这个 ADR 的价值在于:在真正开始对着真实账号 apply 之前,先把三层防线都摆正,而不是等出了事再补。

---

## Task 6:Terraform State Architecture(汇总输出)

### State Flow
每个环境的 state 只存在于它自己的 HCP Terraform workspace 里(HCP Terraform 托管,加密、带版本历史、原生锁)。没有任何脚本、任何人工流程会读取或写入另一个环境的 state。State 从不手工编辑(`terraform state ...` 命令若要使用,必须是审查过的、有明确理由的操作,不是日常流程的一部分)。

### Workspace Flow
`operationarvin` 组织下,`infra-aws` project,三个(未来)workspace,命名规则见 Task 2。每个 workspace 的 Working Directory 精确指向对应的 `environments/<env>/`。

### Branch Flow
见 Task 3——workspace 绑定分支,`main → prod`、`lab → lab`、(未来)`staging → staging`。

### Execution Flow
`execution-mode` 目前建议保持 `local`(现有连接的默认值),作为过渡阶段——plan/apply 仍由人在本地机器上触发,便于在正式打通 OIDC 之前维持人工可控。一旦 Task 4 的 Dynamic Provider Credentials 接好、且每个环境的 workspace 都独立存在,建议升级到 `remote`(HCP Terraform 自己跑 plan/apply,VCS push 触发,原生 run 审批流程)——这是解锁 HCP Terraform 原生审批/Sentinel 策略检查能力的前提,`local` 模式下这些能力用不上。

### Apply Flow
Plan 永远先出、先人工审阅,才谈得上 apply。Lab 的 apply 审批可以相对宽松(HCP Terraform workspace 的 run 审批,或延续现有的"人工在本地跑"模式);**Prod apply 永远需要人工点击批准**——这是需求文档 §10.4、`policies/ai-pull-request-policy.md`(`wcd-engineering` 仓库)、以及本仓库自己 README 的"Production 变更流程"三处独立强调的同一条规则,本 ADR 不改变它,只是把它接到具体的 workspace 审批机制上。

### Destroy Flow
Workspace 级别:`terraform destroy` 必须显式针对目标环境的 workspace 执行,并要求确认输入(`scripts/infra.sh` 已经实现了这一层确认逻辑,机制上不需要改)。Workload 级别:见 `docs/eks-lab-destroy.md`(Plan-1001 已审查)的有序销毁序列,那是同一个环境内部的操作顺序,和本 ADR 的 workspace 级隔离是互补关系,不是同一件事。

### Recovery Flow
HCP Terraform Cloud 原生保留每一个 state 版本的历史,可以在 UI 里回滚到任意历史版本——这是选择 Option B(HCP Terraform Cloud)相对 Option A(自建 S3)的一个具体优势:S3 方案要达到等价的保护,需要自己额外开启 bucket 版本控制并维护回滚流程;HCP Terraform 原生就有。State 锁(HCP Terraform 原生提供)从源头上防止并发 apply 造成的 state 损坏,这是"恢复"之前更重要的一层"预防"。

### Migration Flow
今天没有任何环境的 remote state 真正被使用过(Task 1 的结论)——这意味着"迁移"在这个仓库的当前阶段,是一次冷启动接线,不是一次带着真实资源的高风险状态迁移:

1. **人工操作(不在本 ADR 范围内,需要你亲自做):** 把现有 workspace `devops-terraform-jenkins-eks` 重命名为 `devops-terraform-jenkins-eks-lab`(或新建同名 workspace 并废弃旧的——两种方式都可以,取决于 HCP Terraform UI 当时支持哪种);新建 `-staging`、`-prod` 两个 workspace。
2. **代码变更(未来的、每环境各自独立的 PR,不在本 ADR 里做):** 给 `environments/lab/versions.tf` 加上指向 `devops-terraform-jenkins-eks-lab` 的 `cloud {}` 块;`environments/prod/versions.tf` 同理指向 `-prod`;`environments/staging/` 要等它真正被脚手架搭建出来之后才有 `versions.tf` 可以改。**三个环境的接线必须是三个独立的 PR,不要为了省事合并成一个**——每一个都需要各自的 Architecture/Implementation Review,理由和 Plan-1001 里 network 和 EKS 分成两个 PR 是一样的:改动范围要能被单独审查、单独回滚。
3. **验证(人工操作,需要真实 AWS/HCP Terraform 凭证,不在本环境能做):** 每个环境接线后,`terraform init` 确认成功连接到正确的 workspace,`terraform plan` 确认没有意外的资源变更(因为目前没有真实资源,预期结果应该是"no changes" 或者"这是第一次 apply,以下是要创建的资源列表"——不应该出现任何已存在资源的隐式导入或漂移)。

---

## Workspace Recommendation

采用 Task 2 的命名标准(`devops-terraform-jenkins-eks-<env>`),复用现有已连接的 workspace 作为 `-lab`(改名而非新建),新建 `-staging`/`-prod`。每个 workspace 精确绑定一个 git 分支(Task 3)和一个 `environments/<env>/` 工作目录。`execution-mode` 短期维持 `local`,OIDC(Task 4)接好后升级到 `remote`。

## Migration Recommendation

见 Task 6"Migration Flow"。核心建议:三个环境分三个独立 PR 接线,且因为目前没有任何真实 state 存在,这是低风险的冷启动操作,不需要 `terraform state mv`/`import` 之类的高风险迁移工具——这一点值得明确写下来,因为一旦某个环境真的 apply 过一次,这个"低风险"窗口就关闭了,以后再调整 workspace 归属会变成一次真正的状态迁移。

## Risk Assessment

| 风险 | 等级 | 缓解 |
|---|---|---|
| 多环境共享同一 workspace(本 ADR 的起因) | 高(如果不做任何事,直接复制 Background 里的片段到多个环境) | 本 ADR 的核心建议——每环境独立 workspace,已给出具体命名和接线方式 |
| Workspace 改名/新建操作本身出错(人工步骤) | 低 | 目前没有真实资源挂在现有 workspace 下,改名操作没有资源层面的爆炸半径 |
| OIDC 未接好前,`local` execution-mode 下人工 apply 缺少集中审计 | 中 | 短期可接受(现状本来就是本地/无自动化);列为升级到 `remote` 的驱动因素之一,不是本 ADR 需要立刻解决的问题 |
| 三个环境接线 PR 被合并成一个大 PR,难以单独审查/回滚 | 中 | Migration Flow 中已明确要求分开,呼应 `policies/ai-pull-request-policy.md`"保持 PR 小而清晰"的既有原则 |
| `staging` 环境命名(`stage` vs `staging`)在不同文档间不一致 | 低 | 本 ADR 统一使用 `staging`,匹配实际目录名;已在 Task 2 中明确标注 |

## 参考

- `docs/decisions/ADR-0002-terraform-state.md`(本 ADR 是它的具体化,见下方更新)
- `docs/decisions/ADR-0003-github-oidc.md`——本 ADR Task 4 澄清了它和 HCP Terraform OIDC 路径的关系,不取代它
- `docs/target-architecture.md` §3、`docs/current-state-assessment.md` §6——已连接 workspace 的背景事实来源
- `docs/eks-lab-destroy.md`——workload 层面的销毁顺序,与本 ADR 的 workspace 层面隔离互补
- `wcd-engineering` 仓库 `standards/security/identity-boundary.md` / `adr/ADR-0005-terraform-execution-identity.md`——本 ADR Task 4 的 OIDC 分层与该组织级标准保持一致
