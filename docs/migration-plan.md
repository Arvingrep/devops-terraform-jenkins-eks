# 迁移计划(Migration Plan)

把现状(`docs/current-state-assessment.md`)对接到目标(`docs/target-architecture.md`),拆成一步步可审查、可回滚的步骤。除了文档和脚手架文件本身之外,下面提到的每一个涉及真实 Terraform 资源的步骤,本次 PR 都不会去执行——全部都是后续工作,之所以在这里列出来,是为了在真正发生之前就能被审查一遍。

## 指导原则

每个涉及真实 Terraform 资源的阶段都作为独立 PR 提交,附上自己的 `terraform plan` 输出贴进 PR 描述,并且执行者(agent)不会自动 merge、也不会自动 apply。

## 阶段 0 —— 本次 PR(`feature/iac-foundation` → `lab`)

**做了什么:** 文档、目录骨架、工具配置、只做 lint 的 CI workflow。没有动任何 Terraform 资源;唯一的例外是对 `part1-jenkins-from-terraform/*` 和 `part2-cluster-from-terraform-and-jenkins/terraform-for-cluster/*` 运行了 `terraform fmt -recursive`,目的是让新加的 `terraform-check.yml` 的 fmt 检查能通过——这是纯粹的空白符/对齐调整(`fmt` 从不改动资源参数、取值或语义),顺带修掉了 `server.tf` output 块里一个历史遗留的多余空格 typo。没有改动任何资源属性、变量取值或模块参数。

**旧代码保持不变(语义层面):** 现有的 part1/part2 两棵代码树,每一个资源、变量、取值都和之前完全一样——只是空白符被重新格式化了。
**新增内容:** `docs/*`、`modules/*/README.md` 占位文档、`environments/*/README.md` 占位文档、`bootstrap/*/README.md` 占位文档、修好的 `.gitignore`、`.terraform-version`、`.tflint.hcl`、`Makefile`、`scripts/infra.sh`(带防护措施 + 对着空目录会给出清晰的"还没实现"报错,不会真的对空目录跑 terraform)、`.github/workflows/terraform-check.yml`。
**资源影响:** 无。**State 影响:** 无。**回滚方式:** revert 这个 PR,外部什么都不会变。

## 阶段 1 —— Bootstrap 决策 + backend(独立 PR,agent 不执行 apply)

**这个阶段开始前必须先决策(否则阻塞):** 是走 S3+DynamoDB 的 bootstrap,还是每个环境一个 HCP Terraform Cloud workspace——见 ADR-0002。目前倾向于 HCP Terraform Cloud,因为已经接入了一半;在写任何 bootstrap 代码之前需要你确认。
**做什么:** 如果走 S3 路线,建 `bootstrap/backend/`;如果走 HCP 路线,写清楚每个环境一个 workspace 的搭建说明,再加上 `environments/lab/backend.hcl.example` 或 `cloud {}` 块的接入方式。
**如果选 S3 路线的资源影响:** 恰好新建一个 S3 bucket + 一张 DynamoDB 表(全新资源,不会碰 `mubin-devops-cicd-terraform-eks`)。**如果选 HCP 路线:** 不会新建任何 AWS 资源,只是 Terraform Cloud 的 workspace 配置——但仍然需要人(不是 agent)去真正执行 `terraform login`/应用 workspace 设置,符合 `feedback_wcd_agent_permission_boundaries` 里的权限边界。
**回滚方式:** 全新的 backend,想放弃随时可以放弃——目前还没有任何东西迁移到它上面。

## 阶段 2 —— 网络模块拆分

**做什么:** 新建 `modules/network`,然后把 `environments/lab/main.tf` 改写为调用这个模块,传入适合 lab 的变量(`single_nat_gateway=true`,flow logs 可选)。
**受影响的旧代码:** `part1-jenkins-from-terraform/vpc.tf` 和 `part2-cluster-from-terraform-and-jenkins/terraform-for-cluster/vpc.tf` 是这个模块"应该长成什么样"的*参考*——它们本身不会被原地修改;模块是全新代码。
**这会替换已经在跑的资源吗?** 只有当有人真的把 `environments/lab` 指向真实 AWS 并执行 apply 之后才会——在那之前,爆炸半径为零。如果以后要把一个已经 apply 过的 VPC 纳入这个模块的资源地址空间,需要用 `terraform state mv` 或 `import` block,逐个资源地规划,绝不会盲目 `apply`。
**这个 PR 开出来时必须明确标出的强制替换风险:** 对全新的 lab 来说没有;如果指向一个已存在的 VPC 而没有导入方案,风险为 HIGH(VPC/子网 CIDR 变化会强制触发替换)。

## 阶段 3 —— Jenkins 模块拆分 + 安全修复

**做什么:** 新建 `modules/jenkins`;修复 `0.0.0.0/0` 上的 SSH/8080 暴露问题,加上 IMDSv2 强制、EBS 加密、专用数据卷、IAM instance profile。
**必须明确标出的风险:** 如果这个模块被应用到一个*已经存在*的 Jenkins EC2 实例上(而不是全新 lab 环境),安全组和 instance profile 的变更很可能会强制触发实例替换(新的 AMI 设置、新的 IMDS 选项往往无法原地修改)——除非提前做快照/备份,否则根卷上的 Jenkins 数据会丢失。这一点必须在那个 PR 的描述里再次、大声地强调,在任何人把它 apply 到真实运行的 Jenkins 实例之前。
**目前只做 lab 规格:** 这个阶段只交付 lab 规格的配置;高可用/ALB/HTTPS 明确推迟(见 target-architecture §6)。

## 阶段 4 —— EKS 模块拆分

**做什么:** 新建 `modules/eks`,在上游模块外面包一层,使用一个受支持的 Kubernetes 版本(现有的 `1.24` 必须升级——很可能现在已经超出 AWS 标准支持层了)、IRSA/OIDC、受限的端点 CIDR、控制面日志。
**必须明确标出的风险:** 对一个已经 apply 过的集群升级 `cluster_version`,在 EKS 里是原地升级路径(不是替换),但这是单向门——AWS 不支持降级——必须作为独立、被审查过的步骤来做,绝不能悄悄地捆绑进模块重构里。
**State 影响:** 对 lab 来说是全新资源;如果要接管一个已存在的集群,需要显式规划 `terraform state mv`/import,和阶段 2 的规则一样。

## 阶段 5 —— 完善 CI/CD

`lab-plan.yml`、`lab-apply.yml`(手动触发,GitHub Environment 把关)、`lab-destroy.yml`(手动触发 + 输入确认文本 + 先出 destroy plan 再批准,按需求文档 §10.3)、`prod-plan.yml`(只 plan,apply 在有明确签字确认的 Prod 审批工作流之前,仍然是人工/控制台操作,按 §10.4)。在阶段 1–4 落地、真正有东西可以跑之前,这些都不会建。

## 贯穿所有阶段:如何防止"意外销毁"

- 每个阶段的 PR 必须贴出真实的 `terraform plan`(或者说明为什么贴不出来,比如 backend 还没定)——绝不凭记忆描述。
- 任何 plan 里出现 `destroy`、强制替换、`-/+`,或者 IAM 权限扩大的行,都要单独在 PR 描述里用一段话说清楚,而不是埋在 diff 里。
- 执行这项工作的 agent 在任何阶段都不会主动去跑 `apply` 或 `destroy`,除非用户在当次对话里明确针对那一次具体的执行提出要求——不会把之前某个阶段给过的批准,当作对后面阶段的默认授权。
