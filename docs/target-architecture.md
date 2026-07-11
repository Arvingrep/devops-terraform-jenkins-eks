# 目标架构(Target Architecture)

本文档描述这个仓库要走向的方向。目前还没有实现——实现工作按照 `docs/migration-plan.md` 中的顺序逐步进行。现状基线见 `docs/current-state-assessment.md`。

## 1. 指导原则

1. 只维护一套版本受控的 Terraform **模块**,所有环境共用。
2. 每个环境(`lab`、`staging`、`prod`)都有自己独立的 state、自己的 `.tfvars`、自己的 IAM 边界——绝不共享同一个 state 文件,也绝不仅靠 workspace 名字来做隔离。
3. `main` 里的任何东西都不是 Lab 的复制粘贴分叉——`main` 保存的是模块 + 环境配置;漂移是通过结构设计来防止的,而不是靠自觉。
4. Lab 必须便宜、可随时销毁、随时销毁都是安全的。Prod 必须可审计,任何变更都需要人工审批。

## 2. 仓库结构(目标状态)

```
devops-terraform-jenkins-eks/
├── bootstrap/{backend,github-oidc}/     # 每个账户一次性的初始化,由人工执行
├── modules/{network,security,iam,jenkins,eks,ecr,observability,dns}/
├── environments/{lab,staging,prod}/     # 很薄:只有模块调用 + tfvars,没有资源逻辑
├── scripts/{infra.sh,bootstrap.sh,validate.sh,cost-check.sh,smoke-test.sh}
├── policies/{iam,security,tagging}/
├── tests/{terraform,smoke}/
├── docs/{architecture,deployment,destroy,security,disaster-recovery}.md, decisions/ADR-*.md
└── .github/workflows/{terraform-check,lab-plan,lab-apply,lab-destroy,prod-plan}.yml
```

`environments/*` 里不包含任何内联资源块——只有类似 `module "network" { source = "../../modules/network" ... }` 这样的模块调用,加上 provider/backend/版本锁定。所有真正的资源逻辑都在 `modules/` 里。

## 3. State 后端——待决策事项,见 ADR-0002

目前有两个候选方案:

- **A. 自建 S3 + DynamoDB**,按照原始需求文档的描述:`bootstrap/backend/` 创建一个这个组织拥有的、加密、开启版本控制、屏蔽公网访问的 bucket,按环境划分 key(`lab/platform/terraform.tfstate` 等),配一张 DynamoDB 锁表。
- **B. HCP Terraform Cloud**(本次会话已经配置好:org `operationarvin`,project `infra-aws`,workspace `devops-terraform-jenkins-eks`,`execution-mode=local`,`auto-apply=false`):原生提供版本控制、加密和锁,不需要额外的 bootstrap 模块,但需要每个环境各建一个 workspace,并且要决定 `execution-mode`(`local` = 只存 state,plan/apply 仍在本地跑;`remote` = 由 HCP Terraform 来跑,真正的 VCS 触发式 CI 需要这个模式)。

**建议:** 对 `lab` 采用方案 B(已经接了一半,不需要额外的 bootstrap 成本),等 OIDC/审批方案(§6)确定之后再决定 `staging`/`prod` 怎么做——HCP Terraform 自带的 run 审批机制可以替代 GitHub Environment 审批,也可以两者叠加使用。这个决定目前在 ADR-0002 里标记为"待确认",不是最终结论,等你确认。

## 4. 环境模型

| | lab | staging | prod |
|---|---|---|---|
| AWS 账户 | 独立账户或隔离的 OU | 独立账户 | 独立账户 |
| State | 独立(见上面的后端候选方案) | 独立 | 独立 |
| NAT | 单 NAT(省成本) | 单个或每 AZ 一个 | 每 AZ 一个 |
| EKS 端点 | 公网、不限制也可以 | 公网 + CIDR 限制 | 私有 + 受限公网 |
| 节点容量 | 允许 Spot,最少 1 个 | 混合 | on-demand 打底 + spot 突发 |
| Apply 触发方式 | 合并到 `lab` 后手动/自动 | 手动 | 必须人工审批 |
| 标签 | 强制 `AutoDestroy=true` | `AutoDestroy=false` | `AutoDestroy=false` |

命名规则:`wcd-<project>-<environment>-<resource>`(例如 `wcd-platform-lab-vpc`),按需求文档 §5.2——`wcd-platform` 是否作为实际的 project slug,待你确认(本次会话中的公开问题)。

## 5. 网络模块(`modules/network`)

替换现有两份手写的 `vpc.tf`,以及未锁版本的 `terraform-aws-modules/vpc/aws` 调用。接口:`enable_nat_gateway`、`single_nat_gateway`、`enable_vpc_flow_logs`、`availability_zones`、`public_subnet_cidrs`、`private_subnet_cidrs`,外加强制的标签变量。不使用 `aws_default_security_group`/`aws_default_route_table`——只用专用资源,这样模块才具备可组合性,才能在不同环境之间导入/复用而不用和 AWS 隐式的默认资源"打架"。

## 6. Jenkins 模块(`modules/jenkins`)

要脱离"教程代码"的身份,必须先修复:SSH 22 和 8080 都不能对 `0.0.0.0/0` 开放(改成一个受限 CIDR 变量,长期来看应该用 SSM Session Manager 完全替代 SSH),强制 IMDSv2,根卷 + 一个专用加密数据卷用于 `/var/lib/jenkins`,IAM instance profile 只给 Jenkins 真正需要的权限(绝不给 `AdministratorAccess`),`user_data` 里不出现任何明文密钥,Terraform/kubectl 版本锁定,而不是"启动时装最新版"。HTTPS/ALB 和 Jenkins-home 备份明确不在 Lab 最小可用版本的范围内,作为后续待办事项跟踪。

## 7. EKS 模块(`modules/eks`)

在 `terraform-aws-modules/eks/aws` 外面包一层,使用一个当前受支持、锁定版本的 Kubernetes 版本,同时锁定匹配的 `required_providers { aws = { version = ... } }` 约束——这不是纸上谈兵:`part2` 现在未锁版本的 `~>19.0` 模块,今天用当前的 AWS provider 就已经跑不过 `terraform validate`(`docs/current-state-assessment.md` §8a)。锁定版本、当前受支持的 Kubernetes 版本(现有的 `1.24` 已经过了标准支持期,必须升级),用变量限制 `cluster_endpoint_public_access_cidrs`,默认启用 IRSA/OIDC,开启控制面日志,节点组 `capacity_type` 可选(lab 默认 `SPOT`)。更高级的能力(Karpenter、PDB、多 AZ 节点绑定)按需求文档 §8.3 明确推迟到后面再做。

## 8. CI/CD

`terraform-check.yml`(本次 PR 已加入):`fmt -check -recursive`、`init -backend=false`、`validate`,每个 PR 都跑,不需要 AWS 凭证。`lab-plan`/`lab-apply`/`lab-destroy` 和 `prod-plan` 工作流推迟到模块拆分阶段,等 `environments/lab` 有真实内容可以 plan 了再建——现在建这些针对空壳目录的 workflow,只会是一个永远失败的 workflow。

## 9. 本次 PR 不会改变什么

本次 PR 不会创建、修改或销毁任何 AWS 资源。`part1-jenkins-from-terraform` 和 `part2-cluster-from-terraform-and-jenkins` 原样保留、继续正常工作,直到模块拆分的 PR 落地,并且有了经过验证的 `terraform state mv` 方案为止(见 `docs/migration-plan.md`)。
