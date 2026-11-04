# headscale-derp-stack

自建 Headscale 控制平面、DERP/STUN 中继及 Headplane Web 管理界面，提供两种独立部署方式。

组件分为 **Headscale 控制服务（含内置 DERP/STUN）**、**Headplane 管理界面**、**Tailscale 客户端**。前两者一起部署，客户端独立部署到各网关节点。

客户端 Docker / Kubernetes 配置和操作步骤见 [client/README.md](client/README.md)。

**开始前先看：[服务端部署前配置清单](server/CONFIGURATION.md)**，集中列出了所有必改字段及对应文件。

**逐步操作：[按配置文件替换部署教程](TUTORIAL.md)**，包含 Headplane 创建客户端密钥、填写配置及后续变更方法。

**现有监控平台接入：[Kubernetes PodMonitor + Alloy → Loki](client/monitoring/README.md)**，含 Grafana 导入面板和网关访问记录配置。

## 变量生成配置（非交互）

脚本和变量模板均在对应部署目录：

| 部署目标 | 脚本 | 变量模板 |
| --- | --- | --- |
| 服务端 Docker | [configure.sh](server/docker/configure.sh) | [config.example.env](server/docker/config.example.env) |
| 服务端 K8s | [configure.sh](server/k8s/configure.sh) | [config.example.env](server/k8s/config.example.env) |
| 客户端 Docker | [configure.sh](client/docker/configure.sh) | [config.example.env](client/docker/config.example.env) |
| 客户端 K8s | [configure.sh](client/k8s/configure.sh) | [config.example.env](client/k8s/config.example.env) |

例如服务端 K8s：
```sh
cd server/k8s
cp config.example.env setup.env
chmod 600 setup.env
nano setup.env
bash configure.sh
```

其他部署目录用法相同，不填写 ROLE 或 MODE。输出仍在仓库根目录 `.generated/<部署侧>-<方式>/<INSTANCE>/`。只生成文件，不自动部署，详见 [配置生成说明](CONFIGURE.md)。

## 选择部署方式

| 方式 | 适用环境 | HTTPS 443 | STUN UDP 3478 | 部署文档 |
| --- | --- | --- | --- | --- |
| Docker Compose | 单台 IDC 服务器 | 复用宿主机 Nginx | Docker 端口映射 | [Docker 部署](server/docker/README.md) |
| Kubernetes | 已有 K8s 集群 | 复用已有 Ingress Controller | 固定 IDC 节点 hostPort | [K8s 部署](server/k8s/README.md) |

## 目录

```text
server/                 # 服务端：Headscale + Headplane，含内置 DERP/STUN
  README.md
  CONFIGURATION.md
  docker/               # Compose、配置模板、Nginx 示例
  k8s/                  # Kustomize、配置模板、存储与入口
client/                 # 客户端：Tailscale，独立启动
  README.md
  docker/               # Linux host 网络网关
  k8s/                  # Pod 网络子网路由客户端
```

从仓库根目录进入相应目录：

```sh
# 服务端，二选一
cd server/docker
# 或 cd server/k8s

# 客户端，另一个终端从仓库根目录进入，二选一
cd client/docker
# 或 cd client/k8s
```

## 旧目录迁移

旧 `docker/`、`k8s/` 已归入 `server/`，旧 `tailscale/` 已改为 `client/`。拉取更新后，将原目录中未跟踪的 `.env`、`config/headscale.yaml`、`config/headplane.yaml` 及自定义策略迁移到对应新目录，再从新目录运行命令；不要用示例覆盖真实配置。

Compose 项目名及命名卷定义保持不变，迁移目录无需删除卷或重新注册。K8s 的资源名称和 namespace 保持不变。若曾用 `-p` 或 `COMPOSE_PROJECT_NAME` 自定义项目名，仍使用相同名称。

## 默认行为

- 固定 Headscale **0.29.7**、Headplane **0.8.2**，不使用 latest；切换版本前核对配置和兼容性并备份。
- DERP 只允许已注册节点使用；仅发布自建中继，无其他中继兜底。
- ACL 默认允许所有已注册节点访问所有端口，需要隔离时按实际需求收紧。
- 管理界面使用 Headscale API Key 登录，不提供 Docker socket 或集群控制权限。
- 示例域名及公网 IP 必须替换；真实配置、会话密钥和证书不提交 Git。

## 验收范围

两种方式均需验证 HTTPS、管理登录、节点注册、UDP STUN 及双节点实际中继通信。当前提供部署模板；本地静态检查不代表已在 IDC 或集群部署成功。各方式的前提、启动步骤、版本检查和备份说明见对应文档。

## 官方参考

- [Headscale 固定版本配置](https://github.com/juanfont/headscale/blob/v0.29.7/config-example.yaml)
- [DERP](https://headscale.net/stable/ref/derp/)
- [反向代理协议要求](https://headscale.net/stable/ref/integration/reverse-proxy/)
- [Headplane 配置](https://github.com/tale/headplane/blob/v0.8.2/config.example.yaml)
