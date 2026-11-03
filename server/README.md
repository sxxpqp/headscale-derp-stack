# 服务端：Headscale + Headplane

此目录部署 Headscale 控制服务、内置 DERP/STUN 和 Headplane 管理界面。Tailscale 客户端单独在 [../client/](../client/README.md) 部署。

先阅读 [部署前配置清单](CONFIGURATION.md)，再选择一种方式：

| 方式 | 从仓库根目录进入 | 部署文档 |
| --- | --- | --- |
| Docker Compose | `cd server/docker` | [Docker](docker/README.md) |
| Kubernetes | `cd server/k8s` | [K8s](k8s/README.md) |

两种方式均包含 Headscale 和 Headplane，不要重复部署两套。
