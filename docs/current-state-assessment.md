# 现状评估(Current State Assessment)

**范围:** `main` 分支 commit `5f90d72` 时的完整仓库,对应 `feature/iac-foundation` 分支。
**方法:** 以下涉及的每个文件都被完整读取过;对两个 Terraform 根目录都实际运行了 `tfsec`;没有依赖任何 AWS 控制台假设。

## 1. 当前目录与 Terraform 文件清单

```
devops-terraform-jenkins-eks/
├── README.md                                          (1 行 —只有一个外部链接,没有真正的文档)
├── .gitignore                                         (2 行 —见 §3,有一个真实的 bug)
├── part1-jenkins-from-terraform/
│   ├── backend.tf            (7 行)
│   ├── provider.tf           (3 行)
│   ├── variables.tf          (20 行)
│   ├── terraform.tfvars      (5 行)
│   ├── vpc.tf                (58 行)
│   ├── server.tf             (31 行)
│   └── jenkins-server-setup.sh (23 行)
└── part2-cluster-from-terraform-and-jenkins/
    ├── Jenkinsfile            (30 行)
    ├── kubernetes/
    │   ├── deployment.yaml    (19 行)
    │   └── service.yaml       (15 行)
    └── terraform-for-cluster/
        ├── backend.tf         (8 行)
        ├── provider.tf        (3 行)
        ├── variables.tf       (10 行)
        ├── terraform.tfvars   (3 行)
        ├── vpc.tf             (27 行)
        └── eks-cluster.tf     (26 行)
```

在本次工作之前,不存在 `modules/`、`environments/`、`bootstrap/`、`policies/`、`tests/` 或 `docs/` 目录。只有一个 Git 分支(`main`)和一个 commit(`First commit`)。

## 2. 这套代码实际创建的 AWS 资源

**part1(`part1-jenkins-from-terraform`)—单一扁平根模块:**
- `aws_vpc.myjenkins-server-vpc` — 单个 VPC,无 flow logs
- `aws_subnet.myjenkins-server-subnet-1` — **只有一个公有子网,单一可用区**(无高可用)
- `aws_internet_gateway.myjenkins-server-igw`
- `aws_default_route_table.main-rtbl` — 修改的是 VPC 的*默认*路由表,而不是专用路由表
- `aws_default_security_group.default-sg` — 修改的是 VPC 的*默认*安全组,而不是专用安全组;对 `0.0.0.0/0` 开放 **22/tcp 和 8080/tcp**,出站 `-1` 对 `0.0.0.0/0` 全开
- `data.aws_ami.latest-amazon-linux-image` — 每次 apply 都会浮动解析"最新" AMI(未锁定版本)
- `aws_instance.myjenkins-server` — EC2 `t2.small`,公网 IP,引用 `key_name = "jenkins-server-key"`,但**这段代码里没有创建这个 key pair**——它必须已经在目标 AWS 账户中存在,否则 `apply` 会失败。根卷是默认配置(未加密,tfsec 已确认),未启用 IMDSv2,没有 IAM instance profile。

**part2(`terraform-for-cluster`)—一个扁平根模块,调用两个上游 registry 模块:**
- `module.myjenkins-server-vpc`(`terraform-aws-modules/vpc/aws`,**未锁定 `version`**)— 3 个公有子网 + 3 个私有子网,1 个 NAT gateway,无 VPC flow logs
- `module.eks`(`terraform-aws-modules/eks/aws`,锁定为 `~>19.0`)— EKS 集群 `myjenkins-server-eks-cluster`,Kubernetes `1.24`,`cluster_endpoint_public_access = true` 且没有 CIDR 限制(默认等于 `0.0.0.0/0`),一个托管节点组(`t2.small`,1–3 节点,只有 on-demand,没有 capacity_type/Spot 选项),未开启控制面日志,IRSA/OIDC 未显式启用

**Kubernetes 层面:** 一个纯粹的 `nginx` `Deployment` + `LoadBalancer` `Service`(无 ingress controller,无 TLS),只是用来做手工冒烟测试。

**Jenkins 流水线(`Jenkinsfile`):** 把长期有效的 `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` 作为 Jenkins credentials 注入,无条件运行 `terraform apply -auto-approve`,**完全没有 plan 审查环节,也没有任何 destroy 阶段**。

## 3. 当前变量与硬编码情况

- 任何地方都没有 `required_version` 和 `required_providers` 块(4 个 provider.tf 等价文件,0 个版本锁定)—— Terraform core 和 AWS provider 的版本完全没有约束。本机 CLI 是 `1.5.7`;本次会话新接入的 HCP Terraform workspace 默认是 `1.15.8`——两者在第一次真实运行时就会产生分歧。
- Terraform state 后端 bucket `mubin-devops-cicd-terraform-eks` 在两个 `backend.tf` 中都是**硬编码**的,几乎可以肯定是原教程作者的个人 bucket,而不是这个 AWS 账户/组织拥有的——在把 backend 指向一个这个组织真正拥有的 bucket 之前,`terraform init` 大概率会失败(见 §6)。
- `key_name = "jenkins-server-key"`(part1/server.tf:17)—— 硬编码引用一个在代码之外、手工创建的 key pair。
- 两个 `provider.tf` 文件里都硬编码了 region `us-east-1`(不算致命问题,但没有参数化)。
- `.gitignore` 里的 `.terraform*` 规则,除了排除 `.terraform/` 之外,也顺带排除了 `.terraform.lock.hcl`——而这个文件恰恰是应该被提交、以保证 provider 版本可复现的文件。目前仓库里根本没有这个锁定文件。
- 两个根目录都没有提交 `.terraform.lock.hcl`——今天重新跑 `terraform init` 可能会悄悄解析出和上次 apply 时不同的 provider/module 版本。
- part2 中 `terraform-aws-modules/vpc/aws` 模块源**没有版本约束**——每次全新 `init` 都可能拉到不同的模块版本;只有 `module.eks` 锁定了版本。
- 两个根目录里的任何资源都没有携带标准标签(`Project`、`Environment`、`ManagedBy`、`Owner`、`CostCenter`)——只有零散的 `Name`/`environment`/`application` 标签。

## 4. 当前 IAM 风险

- Jenkins EC2 实例**完全没有 IAM instance profile**——虽然谈不上权限过大,但也意味着以后想把 Jenkins 流水线里长期有效的 AWS key 换成基于实例角色的认证,需要重新设计。
- Jenkins 流水线凭证(`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`)是长期有效的 IAM 用户密钥,存放在 Jenkins 里,不是基于 OIDC/STS 的——而 Jenkins 本身又能从公网访问到 8080 端口(见 §5),所以 Jenkins 一旦被攻破,这些密钥就直接暴露了。
- 除了 `terraform-aws-modules/eks` 模块隐式创建的部分之外,Terraform 没有为 EKS 集群/节点访问定义任何 IAM 角色;没有启用 IRSA/OIDC provider,所以目前无法做到 Pod 级别的 AWS 最小权限访问。
- 不存在专门的 Terraform bootstrap 角色;现在谁要执行 `terraform apply`,都需要拥有较大范围的常驻 AWS 凭证。

## 5. 当前网络风险(由 `tfsec` 确认,不只是人工判断)

`tfsec` 对 `part1-jenkins-from-terraform` 的扫描结果:

| 严重程度 | 发现 | 位置 |
|---|---|---|
| HIGH | EC2 实例未强制要求 IMDSv2 token | `server.tf:14-26` |
| HIGH | 根 EBS 卷未加密 | `server.tf:14-26` |
| MEDIUM | VPC Flow Logs 未启用 | `vpc.tf:1-6` |

`tfsec` 对 `terraform-for-cluster` 的扫描结果(含模块内容,共扫描 785 个 block / 27 个文件):

| 严重程度 | 发现 | 位置 |
|---|---|---|
| CRITICAL | EKS 公网集群端点访问已启用 | `eks-cluster.tf` → `module.eks` |
| CRITICAL | EKS 集群允许来自 `0.0.0.0/0` 的访问 | `eks-cluster.tf` → `module.eks` |
| CRITICAL | 节点组安全组出站规则对多个公网地址开放 | `eks-cluster.tf` → `module.eks` |
| CRITICAL ×5 | VPC 模块的默认 NACL 规则允许所有端口/公网入站 | `vpc.tf` → `module.myjenkins-server-vpc`(是模块自身默认行为,不是这个仓库代码直接设置的) |
| MEDIUM ×2 | EKS 控制面日志(含 controller-manager)未启用 | `eks-cluster.tf` → `module.eks` |
| MEDIUM | VPC Flow Logs 未启用 | `vpc.tf` → `module.myjenkins-server-vpc` |

人工确认(这个 tfsec 规则集没有标出来,但目标需求文档里明确禁止):`aws_default_security_group.default-sg` 对 `0.0.0.0/0` 开放了 **SSH 22/tcp 和 Jenkins 8080/tcp**(`part1-jenkins-from-terraform/vpc.tf:35-58`)。这是 Jenkins 模块重构中优先级最高的一项修复。

## 6. 当前 Terraform State 管理方式

- 同一个 bucket(`mubin-devops-cicd-terraform-eks`)下有两个独立的 S3 key:`jenkins-server/terraform.tfstate` 和 `eks/terraform.tfstate`。完全没有环境隔离——始终只有"唯一的" state,而不是 lab/staging/prod 的拆分。
- **没有配置 state 锁**——两个 backend 都没有设置 `dynamodb_table`(S3 原生锁 `use_lockfile` 需要 Terraform ≥1.10,而且反正也没有 `required_version` 约束)。今天如果两个人同时 `apply`,state 可能会被破坏。
- Bucket 的版本控制、加密、public-access-block 设置都无法从代码中确认(没有任何 bootstrap 模块管理这个 bucket)——显然是教程作者在代码之外手工创建的。
- 没有任何 backend 是按环境参数化的(即 `backend.hcl` 模式)—— bucket/key 直接硬编码在 `backend.tf` 里,把这个仓库复制到新 AWS 账户,需要手工改两个文件。
- **本次会话的新信号:** 一个 HCP Terraform Cloud workspace(`operationarvin/infra-aws/devops-terraform-jenkins-eks`)已经通过 VCS 接入这个仓库。它当前的设置是 `execution-mode = local`、`auto-apply = false`,所以接入本身**不会**导致 GitHub push 触发远程 run——但仓库里目前没有任何代码指向它(没有 `cloud {}` 块或 `remote` backend 配置)。这是相对于目标架构中 S3-bootstrap 方案的一个真实可选项,已在 `docs/target-architecture.md` / ADR-0002 中列为待决策事项。

## 7. 当前 Jenkins 部署方式

EC2 实例,Amazon Linux 2,完全通过一段 `user_data` bash 脚本(`jenkins-server-setup.sh`)在启动时一次性完成配置:
- 从上游 `jenkins.io` yum 仓库安装 Jenkins、Java 11、Git、Terraform(通过 HashiCorp 的 yum 仓库——**未锁版本,启动时是什么最新版就装什么**),`kubectl` 锁定在 `v1.23.6`(相对于它要对接的 EKS `1.24` 集群已经落后好几个版本,到 2026 年只会更落后)。
- 没有为 `/var/lib/jenkins` 单独挂载 EBS 数据卷——Jenkins home 就在根卷上;没有备份,没有快照策略。
- 没有 HTTPS/TLS,没有反向代理/ALB——Jenkins 直接通过明文 HTTP 在 `:8080` 上访问,对应的安全组对整个互联网开放。
- 没有 secrets 管理——初始管理员密码必须通过 SSH 登录实例才能拿到(而 SSH 同样对 `0.0.0.0/0` 开放)。
- 第 2 行(`sudo yum update`,没加 `-y`)是一个潜在 bug:在非交互式的 `user_data` 环境下这行不会弹出确认提示,实际上等于空跑;之所以不致命,是因为第 6 行(`yum upgrade -y`)已经完成了真正的更新。

## 8. 现有代码能否干净地 `destroy`?

**未经验证,而且今天大概率会被阻塞**:硬编码的 backend bucket `mubin-devops-cicd-terraform-eks` 不属于这个 AWS 账户/组织(这台机器上没有配置 AWS CLI 凭证,无法直接确认,但从 bucket 命名规律看,极大概率是原教程作者账户下的资源)。在把 backend 指向这个组织真正拥有的 bucket之前,`plan` 和 `destroy` 都跑不起来——目前根本没有可以 destroy 的可达 state。等 backend 修好之后:`destroy` 仍然不会清理手工创建的 `key_name = "jenkins-server-key"` key pair(Terraform 从未创建过它,自然也不会删除它);而且由于 `aws_default_security_group`/`aws_default_route_table` 是*默认*资源,`destroy` 只会把它们的规则重置为空,而不是真正删除对象本身(这里不算成本/安全问题,因为整个 VPC 也会一起被销毁,但这是一个 Terraform 反模式,值得在拆出网络模块时一并去掉)。

## 8a. 已验证:part2 目前直接无法通过 `terraform validate`

这一点是通过实际运行 `terraform init -backend=false && terraform validate` 针对 `part2-cluster-from-terraform-and-jenkins/terraform-for-cluster`(通过新建的 `scripts/validate.sh`)确认的——不是推测出来的。由于没有 `required_providers` 锁定,`init` 解析出了最新可用的 `hashicorp/aws` provider,而下载到的 `terraform-aws-modules/eks/aws ~>19.0` 模块(是针对更早一代 AWS provider 写的)和它已经不兼容:

```
Error: Unsupported argument
  on .terraform/modules/eks/main.tf line 428, in resource "aws_eks_addon" "before_compute":
    resolve_conflicts = try(each.value.resolve_conflicts, "OVERWRITE")
An argument named "resolve_conflicts" is not expected here.

Error: Unsupported block type
  on .terraform/modules/eks/modules/eks-managed-node-group/main.tf line 104:
    dynamic "elastic_gpu_specifications" { ... }
Blocks of type "elastic_gpu_specifications" are not expected here.
(还有 3 处同类问题,包括 "elastic_inference_accelerator")
```

这不是一个假设性的可复现性风险——而是一个真实存在、正在发生的问题:`part2` 今天用一次全新的 `init` 就无法通过 `terraform validate`,更不用说 `plan`/`apply` 了,除非 `eks-cluster.tf` 锁定 `required_providers { aws = { version = "..." } }` 到 `~>19.0` 模块真正支持的 provider 版本,或者把模块本身升级到与当前 AWS provider 兼容的版本。(`part1` 同样没有锁版本,但今天碰巧还能正常 `validate`——只是没有任何保证它以后还能继续这样。)

## 9. 现有代码能否稳定地重复 `apply`?

不能,原因是多方面的:
- `data.aws_ami.latest-amazon-linux-image` 每次 plan 都会重新解析"最新" AMI——即使代码毫无变化,几个月后第二次 apply 也可能触发实例替换。
- 未锁版本的 `terraform-aws-modules/vpc/aws` 模块源,不同次运行之间可能解析到不同的模块版本。
- 没有 `required_version`/`required_providers` 锁定,意味着 AWS provider 本身在不同机器/CI 上运行时可能出现不同行为。
- 没有提交 `.terraform.lock.hcl`(而且就算生成了,当前的 `.gitignore` 也会把它排除掉)。
- 两个根目录都是单一扁平 state——完全没有环境隔离,所以某个贡献者在本地改动 `terraform.tfvars` 后第二次 apply,可能悄无声息地覆盖掉别人的 lab 资源。

## 10. 距离 Production-ready 还有多远

这只是一个单环境的教程快照,还不是一个模板。要达到 WCD 需求文档描述的目标,至少需要:一个这个组织真正拥有的、正式的 Terraform state bootstrap(§6);对 Terraform/AWS-provider/所有模块的版本锁定(§3);把 `network`/`jenkins`/`eks` 拆分成可复用模块,并为 NAT/flow-logs/endpoint-access 提供变量(需求文档 §8);去掉 SSH/Jenkins/EKS 端点上的 `0.0.0.0/0`;强制标签;按环境(`lab`/`staging`/`prod`)划分 state 和 IAM 边界;CI 认证从长期有效的 Jenkins 流水线密钥换成基于 OIDC 的方式;补上目前完全不存在的 destroy 工作流;以及 §13 要求的文档/ADR 集合。这些都不需要推倒重来——现有的资源定义是一个合理的起点,可以被提炼进模块,而不需要从零重写。
