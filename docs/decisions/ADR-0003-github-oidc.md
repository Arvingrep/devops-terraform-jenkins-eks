# ADR-0003:GitHub → AWS 认证方式

**状态:** 待定(Proposed)——尚未实现

## 背景

`Jenkinsfile` 目前把长期有效的 `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` 作为 Jenkins credentials 注入进去,用来跑 Terraform。需求文档(§7)要求:凡是最终落在 GitHub Actions 里的 CI/CD 路径,都应该用 OIDC 联合登录到按环境划分的 IAM 角色(`WCDTerraformLabRole`、`WCDTerraformProdPlanRole`、`WCDTerraformProdApplyRole`),而不是静态密钥。

## 决策

尚未实现——本次 PR 里的 `.github/workflows/terraform-check.yml` 完全不需要任何 AWS 凭证(只做 `fmt`/`validate`,而且 `-backend=false`),所以这份 ADR 要到阶段 5(`lab-plan`/`lab-apply`/`lab-destroy`/`prod-plan` 这些 workflow)才会真正起作用,或者如果 ADR-0002 的 backend 决策最终选了 HCP Terraform Cloud、并且用 GitHub Actions 作为触发方式,那也会提前用到。`bootstrap/github-oidc/` 现在只是先占个位置,让目标结构可见,里面还没有能跑的 Terraform 代码。

## 待确认的问题

以后 `plan`/`apply` 到底以 Jenkins(现有的,会被保留并加固,见 `modules/jenkins`)为主,还是以 GitHub Actions(全新)为主——或者不同环境用不同的系统。这会影响"OIDC 到 AWS"这套机制对 Jenkins 是否真的适用(Jenkins 更可能用 EC2 instance profile,而不是 OIDC)。这个问题需要在阶段 5 之前决定。
