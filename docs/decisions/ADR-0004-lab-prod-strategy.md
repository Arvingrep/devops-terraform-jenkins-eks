# ADR-0004:Lab/Prod 策略

**状态:** 已采纳

## 背景

需求文档明确禁止长期维护两套不断漂移的 Lab/Prod Terraform 代码(需求文档 §2.2/§10.4 的表述:"复用同一套 Terraform Modules,通过不同 Environment Configuration 部署 Lab、Staging 和 Production")。

## 决策

`modules/*` 是资源逻辑的唯一真相来源。`environments/lab`、`environments/staging`、`environments/prod` 之间的区别,只体现在:`.tfvars` 取值、backend/state 指向、apply 时用的 IAM 角色,以及打开哪些可选的模块特性(比如 `enable_vpc_flow_logs`、`capacity_type`、`cluster_endpoint_public_access_cidrs`)。任何环境都不允许在本地 fork 某个模块的 `.tf` 文件——Lab 特有的需求应该变成一个新的模块变量(并给出一个对 Prod 合理的默认值),而不是复制一份代码。

## 影响

- 每一个为了"Lab 需要"而新增的模块变量,都必须同时给出一个对 Prod 合理的默认值(或者干脆做成没有默认值的必填变量,逼着 Prod 显式做出选择)——绝不能悄悄地默认成 Lab 那种"便宜/开放"的配置。
- 评审一个模块变更,意味着要考虑它对全部三个环境的影响,而不只是最初提出这个需求的那个环境。
- 只有 `main` 才能被认为是"可复用的模块基线";`lab` 是用来做集成验证的,不是模块本身的 fork 起点。
