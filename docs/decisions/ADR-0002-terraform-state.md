# ADR-0002:Terraform State 后端

**状态:** 待定(Proposed)——等待你确认,详见 `docs/target-architecture.md` §3。Workspace 命名、branch 绑定、OIDC 分层、迁移步骤等具体架构细节已经拆到 `docs/decisions/ADR-0005-terraform-state-architecture.md`(Plan-1002 Architecture Review 产出)——本 ADR 只保留"选 A 还是 B"这个上层决策,不重复 ADR-0005 已经写清楚的内容。

## 背景

现有的 backend(S3 bucket `mubin-devops-cicd-terraform-eks`,没有 DynamoDB 锁表,没有环境隔离,硬编码在两个 `backend.tf` 文件里)不属于这个组织,也没有锁机制。与这个问题无关地,本次会话里还接入了一个 HCP Terraform Cloud workspace(`operationarvin/infra-aws/devops-terraform-jenkins-eks`),`execution-mode=local`、`auto-apply=false`——目前仓库里没有任何代码指向它。

## 备选方案

**A. 自建 S3 + DynamoDB**(`bootstrap/backend/`):完全自主可控,和需求文档 §6.1 的字面描述一致(`wcd-infra-state/<env>/platform/terraform.tfstate` 这种路径规则),但需要自己搭建和维护这个 bootstrap 模块,而且存在"鸡生蛋"问题(backend 本身的 backend 要放哪)。

**B. 每个环境一个 HCP Terraform Cloud workspace:** 版本控制、加密、锁都由平台原生提供;已经接入了一半。需要新建 `-lab`/`-staging`/`-prod` 这样的兄弟 workspace(或者把现有 workspace 当作 `lab` 用,以后再加其他的),并且要决定 `execution-mode`(`local` 让 apply 留在人的机器上或者在 GitHub Actions 里用 Terraform Cloud token 跑;`remote` 把 plan/apply 的执行放进 HCP Terraform 本身,这也是 HCP 原生 VCS 触发式 run 和 Sentinel 策略检查所必需的)。

## 决策

尚未最终确定。目前倾向于 **B**,把现有的 workspace 正式确立为 `lab` 专用的 backend(改名为 `devops-terraform-jenkins-eks-lab`,而不是继续用不带环境后缀的名字),因为这样可以完全省掉一个 bootstrap 模块,而且用户已经把它配置好了,且目前没有任何环境真正 apply 过、没有真实资源挂在这个 workspace 下(ADR-0005 Task 1 已核实),改名/重新归属没有资源层面的风险。在你确认之前,这份 ADR 会一直保持"待定"状态;`docs/migration-plan.md` 的阶段 1 就卡在这个决策上。

**具体的 workspace 命名、branch 绑定、OIDC 分层、迁移顺序,见 `docs/decisions/ADR-0005-terraform-state-architecture.md`——这里不重复。**

## 影响(如果确认选 B)

- 目标结构里的 `bootstrap/backend/` 会变成可选/暂时用不上;如果 GitHub Actions 要针对这些 workspace 跑 plan,`bootstrap/github-oidc/` 可能还是需要的(但 ADR-0005 Task 4 已经说明:如果 `execution-mode=remote`,Terraform 执行本身完全走"HCP Terraform → AWS"这条 OIDC 路径,不依赖 GitHub Actions 自己的 AWS 权限——`bootstrap/github-oidc/` 是否还需要,取决于 GitHub Actions 未来是否有任何工作流需要直接调用 AWS API,而不是取决于 Terraform 执行本身)。
- **每个环境一个 HCP Terraform workspace,命名为 `devops-terraform-jenkins-eks-<environment>`**(沿用已连接 workspace 的实际命名方式,而不是 `wcd-<project>-<environment>`——那条规则是给 AWS 资源命名用的,是两个独立的命名空间,见 ADR-0005 Task 2)。
- Prod 审批既可以通过 HCP Terraform 自带的 run 审批流程,也可以通过包一层 GitHub Environment 审批再走 `terraform-cloud` backend 来实现——等 CI(阶段 5)设计的时候需要再补一份 ADR。
