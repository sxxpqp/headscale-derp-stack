# 部署前配置清单

先选 [Docker](docker/README.md) 或 [K8s](k8s/README.md)，不要同时部署两套。配置内以 **【必改】/【按需】/【通常不用改】** 标记。示例配置不会自动替换变量；需要复制后编辑实际文件。

## 两种方式共用的必改项

下表的 `<方式>` 为 `docker` 或 `k8s`。修改实际 `.yaml` 文件，保留 `.example.yaml` 作为模板。

| 配置位置 | 字段 / 示例 | 需要填写的值 |
| --- | --- | --- |
| `<方式>/config/headscale.yaml` | `server_url` | 公网控制地址，如 `https://vpn.your-domain.com` |
| 同上 | `derp.server.ipv4` / `203.0.113.10` | IDC 真实公网 IPv4；不能是内网 IP 或示例 IP |
| 同上 | `dns.base_domain` | MagicDNS 基域，如 `tail.your-domain.com`，必须不同于控制域名 |
| `<方式>/config/headplane.yaml` | `server.base_url` | 公网管理基础地址；本模板与控制地址相同，不带 `/admin` |
| 同上 | `server.cookie_secret` | `openssl rand -hex 16` 生成的随机 32 字符密钥 |
| 同上 | `headscale.public_url` | 与 Headscale `server_url` 一致 |
| `<方式>/config/policy.hujson` | `acls` | 业务通信前必须按实际用户、节点和端口添加规则；空列表拒绝全部 |

先复制：在所选方式目录执行 `cp config/headscale.example.yaml config/headscale.yaml` 和 `cp config/headplane.example.yaml config/headplane.yaml`。两份实际配置都已被 Git 忽略。API Key 在服务启动后生成，不填进示例文件。

## Docker 专属配置

| 文件 | 要修改 / 核对的项目 |
| --- | --- |
| `docker/nginx/headscale.conf.example` | 所有 `vpn.example.com`、证书和私钥路径；合并到现有 Nginx，勿覆盖其他业务 |
| `docker/.env`（从 `.env.example` 复制） | 目标版本，默认 Headscale 0.29.7 / Headplane 0.8.2；通常保持默认 |
| `docker/compose.yaml` | 宿主机 8080、3000 回环端口及 UDP 3478 是否空闲；端口变化须同步 Nginx 上游 |

## K8s 专属配置

| 文件 / 资源 | 要修改 / 核对的项目 |
| --- | --- |
| `k8s/workloads.yaml` | `REPLACE_WITH_IDC_NODE` → 实际节点 hostname；节点需支持 hostPort 并开放 UDP 3478 |
| `k8s/ingress.yaml` | `REPLACE_WITH_INGRESS_CLASS` → 已有 IngressClass；`tls.hosts` 与 `rules.host` 都替换为控制域名 |
| 同上 / 集群 Secret | 创建同 namespace 的 `headscale-tls`，或同步修改 Secret 名称；配置证书续期 |
| 现有 Ingress Controller | 按控制器开启自定义 Upgrade、长连接和关闭缓冲，具体要求见 K8s 文档 |
| `k8s/storage.yaml` | 有可用默认 StorageClass；没有时两个 PVC 都添加 `storageClassName`；按需调整 1Gi 容量 |
| `k8s/kustomization.yaml` | `images.newTag` 是目标版本，默认固定，不自动升级 |

本 K8s 模板要求 Ingress 入口和 STUN 节点共用公网 IPv4。普通 HTTP Ingress 不转发 UDP。不能只改域名就认为网络已配通。

## 通常不用改

内部 HTTP 地址、持久化路径、Noise/DERP 密钥路径、`cookie_secure: true`、`verify_clients: true` 保持默认。`trusted_proxies` 未知时留空，确认实际代理来源 CIDR 后再配置。仅在 IPv6 真实可达时添加 `derp.server.ipv6`。

## 改完后检查

1. 搜索实际配置和入口文件，确认没有残留 `vpn.example.com`、`tail.example.com`、`203.0.113.10`、`REPLACE_WITH`。模板文件内保留占位值是正常的。
2. Docker 执行 Compose 检查及 Headscale configtest；K8s 执行 Kustomize 渲染和服务端 dry-run，命令见各部署文档。
3. 在目标环境验证 HTTPS、管理登录、节点注册、STUN 及两节点实际中继；静态检查不能替代这些步骤。

本项目不自动安装 Docker、K8s 或 Ingress Controller；若调整组件版本，先核对配套版本、配置及兼容性。
