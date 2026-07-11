# ADR-0002:Terraform State 后端

**状态:** 待定(Proposed)——等待你确认,详见 `docs/target-architecture.md` §3

## 背景

现有的 backend(S3 bucket `mubin-devops-cicd-terraform-eks`,没有 DynamoDB 锁表,没有环境隔离,硬编码在两个 `backend.tf` 文件里)不属于这个组织,也没有锁机制。与这个问题无关地,本次会话里还接入了一个 HCP Terraform Cloud workspace(`operationarvin/infra-aws/devops-terraform-jenkins-eks`),`execution-mode=local`、`auto-apply=false`——目前仓库里没有任何代码指向它。

## 备选方案

**A. 自建 S3 + DynamoDB**(`bootstrap/backend/`):完全自主可控,和需求文档 §6.1 的字面描述一致(`wcd-infra-state/<env>/platform/terraform.tfstate` 这种路径规则),但需要自己搭建和维护这个 bootstrap 模块,而且存在"鸡生蛋"问题(backend 本身的 backend 要放哪)。

**B. 每个环境一个 HCP Terraform Cloud workspace:** 版本控制、加密、锁都由平台原生提供;已经接入了一半。需要新建 `-lab`/`-staging`/`-prod` 这样的兄弟 workspace(或者把现有 workspace 当作 `lab` 用,以后再加其他的),并且要决定 `execution-mode`(`local` 让 apply 留在人的机器上或者在 GitHub Actions 里用 Terraform Cloud token 跑;`remote` 把 plan/apply 的执行放进 HCP Terraform 本身,这也是 HCP 原生 VCS 触发式 run 和 Sentinel 策略检查所必需的)。

## 决策

尚未最终确定。目前倾向于 **B**,把现有的 workspace 用作 `lab` 的 backend,因为这样可以完全省掉一个 bootstrap 模块,而且用户已经把它配置好了。在你确认之前,这份 ADR 会一直保持"待定"状态;`docs/migration-plan.md` 的阶段 1 就卡在这个决策上。

## 影响(如果确认选 B)

- 目标结构里的 `bootstrap/backend/` 会变成可选/暂时用不上;如果 GitHub Actions 要针对这些 workspace 跑 plan,`bootstrap/github-oidc/` 可能还是需要的。
- 每个环境一个 HCP Terraform workspace,命名遵循 `wcd-<project>-<environment>` 的规则。
- Prod 审批既可以通过 HCP Terraform 自带的 run 审批流程,也可以通过包一层 GitHub Environment 审批再走 `terraform-cloud` backend 来实现——等 CI(阶段 5)设计的时候需要再补一份 ADR。
