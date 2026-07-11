# ADR-0001:环境布局(Environment Layout)

**状态:** 已采纳

## 背景

这个仓库之前完全没有"环境"的概念——每个 Terraform 根目录只有一份扁平的 state,只有一套硬编码的变量(`part1-jenkins-from-terraform/terraform.tfvars`)。需求文档要求 `lab`/`staging`/`prod` 各自拥有独立的 state、IAM 边界、CIDR 范围、标签和 secrets,同时共用一套版本受控的模块。

## 决策

采用 `environments/{lab,staging,prod}/` 作为薄的组合层(只有模块调用 + `.tfvars` + backend/provider 配置,不包含内联资源)。`staging` 从一开始就搭好骨架(空的,只有文档),但在 `lab` 和 `prod` 都跑通之前不会真正填充内容,对应需求文档 §5.1 的 MVP 指引(先做 `lab` + `prod`)。

## 影响

- 每个环境都有自己的 `terraform.tfvars` 和自己的 state——不靠 workspace 名字来做隔离(需求文档 §5.1 明确禁止这种做法)。
- 新增一个环境,意味着新建一个调用同一批模块的 `environments/<name>/` 目录,而不是 fork 模块代码。
- 模块接口必须保持足够通用,才能同时服务 lab 的低成本配置和 prod 的加固配置,而不需要拆成两套源码。
