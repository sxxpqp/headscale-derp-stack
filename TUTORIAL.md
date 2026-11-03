# 按配置文件替换部署教程

目录分为服务端 `server/`（Headscale + Headplane，含内置 DERP/STUN）和客户端 `client/`（Tailscale）。本教程先演示 Docker 部署，最后列出 Kubernetes 的配置替换位置。

以下复制模板的步骤用于首次部署。已有实际配置时先备份并编辑原文件，勿重新复制示例覆盖域名、密钥和自定义 ACL。配置片段只展示要替换的字段，保留文件中的其他字段；不要重复添加同名 YAML 配置块。

## 1. 准备替换值

| 内容 | 本教程示例 | 需要做的事 |
| --- | --- | --- |
| 控制与管理域名 | `hb.sxxpqp.top` | 换成你实际拥有且已解析到服务器的域名 |
| 服务端公网 IPv4 | `你的真实公网IPv4` | 填真实 IP，不能写文字占位符或内网 IP |
| MagicDNS 基域 | `ts.corp.internal` | 可保留；与控制域名不同，不使用 .local |
| 客户端节点名 | `site-a-router` | 每台网关使用不同名称 |
| 客户端发布的内网 | `172.16.0.0/24` | 换成这台网关实际能访问的网段 |
| 会话密钥 | `openssl rand -hex 16` 的输出 | 填入 Headplane cookie_secret |
| 客户端注册密钥 | Headplane 创建的 Pre-Auth Key | 填入客户端 TS_AUTHKEY |

服务端需已安装 Docker Compose，域名有正确 DNS 记录，并有可用于该域名的 HTTPS 证书和宿主机 Nginx。开放 TCP 443、UDP 3478；80 按现有证书和跳转流程开放。HTTPS 控制域名不启用 Cloudflare HTTP 代理。

## 2. 服务端：复制配置

在服务端，从仓库根目录执行：
```sh
cd server/docker
cp .env.example .env
cp config/headscale.example.yaml config/headscale.yaml
cp config/headplane.example.yaml config/headplane.yaml
openssl rand -hex 16
```

命令最后一行输出的 32 字符随机值，下一步填入 cookie_secret。镜像版本在 .env 中，首次部署保持模板固定版本。

### 2.1 替换 config/headscale.yaml

```sh
nano config/headscale.yaml
```

找到下面这些位置，修改对应值：
```yaml
server_url: https://hb.sxxpqp.top

derp:
  server:
    ipv4: 你的真实公网IPv4

dns:
  base_domain: ts.corp.internal
```

保留 derp.server 下的 enabled、verify_clients、stun_listen_addr 等其他配置。公网 IP 必须是实际 IPv4 字面值。监听地址保留 `0.0.0.0:8080`，Headscale 的证书路径保持空，由 Nginx 处理 HTTPS。

### 2.2 替换 config/headplane.yaml

```sh
nano config/headplane.yaml
```

修改已有字段：
```yaml
server:
  base_url: "https://hb.sxxpqp.top"
  cookie_secret: "替换为刚才生成的32字符随机值"

headscale:
  url: "http://headscale:8080"
  public_url: "https://hb.sxxpqp.top"
```

base_url 和 public_url 不带 /admin，内部 url 不改为公网域名。保留已有其他字段，特别是：
```yaml
integration:
  kubernetes:
    enabled: false
    pod_name: "headscale"
```

这是关闭状态的配置校验必需字段，不需要启用 Kubernetes 集成。

### 2.3 核对策略文件

仓库已提供 `config/policy.hujson`，默认内容允许全部节点互访。首次部署需要重新创建时：
```sh
cat > config/policy.hujson <<'EOF'
{
  "acls": [
    { "action": "accept", "src": ["*"], "dst": ["*:*"] }
  ]
}
EOF
```

已有自定义策略时保留原文件，按实际业务放行。

## 3. 服务端：启动与 HTTPS

仍在 server/docker 目录：
```sh
docker compose config --quiet
docker compose run --rm headscale configtest
docker compose up -d
docker compose logs --since=2m --tail=100 headscale headplane
```

Nginx 参考 [反代模板](server/docker/nginx/headscale.conf.example)。将模板内容合并到现有 Nginx 的 http 配置中，替换：
- 所有 `vpn.example.com` → 实际域名，例如 `hb.sxxpqp.top`。
- `ssl_certificate` → 已有该域名的完整证书链路径。
- `ssl_certificate_key` → 对应私钥路径。

保留控制协议 Upgrade 头、长连接设置及 /admin 路径。代理 Headplane 时 `proxy_pass http://127.0.0.1:3000;` 的端口后不要加 /，以便保留 /admin 前缀。宿主机 Nginx 使用回环上游；容器 Nginx 需按 [服务端文档](server/docker/README.md) 配置相同网络。

```sh
sudo nginx -t && sudo systemctl reload nginx
curl -fsS https://hb.sxxpqp.top/health
```

将 curl 的域名换成实际域名。管理页面访问 `https://hb.sxxpqp.top/admin/`，不是根路径 /。

## 4. 登录 Headplane 并创建客户端密钥

仍在服务端 Docker 目录，先创建用户（已存在则跳过创建）和管理 API Key：
```sh
docker compose exec headscale headscale users create admin
docker compose exec headscale headscale apikeys create
```

复制 API Key 到 Headplane 登录页。然后在界面：
1. 打开 **Settings → Pre-Auth Keys**。
2. 点击 **Create pre-auth key**，选择节点所属 User。
3. 持久网关关闭 **Ephemeral**；单台节点注册可关闭 **Reusable**。
4. 设置 **Key Expiration** 后生成，立即复制密钥。

API Key 用于管理登录，Pre-Auth Key 用于客户端注册，不能混用。无需进入容器的 sh，也无需为了注册客户端开放 Docker socket 或集群权限。

## 5. 客户端：替换 .env

在需要作为网关的另一台 Linux 主机上准备仓库和 Docker Compose。从仓库根目录执行：
```sh
cd client/docker
cp .env.example .env
chmod 600 .env
nano .env
```

把 .env 中对应字段替换为：
```dotenv
TAILSCALE_VERSION=v1.104.5
TS_HOSTNAME=site-a-router
TS_AUTHKEY=替换为Headplane生成的PreAuthKey
TS_ROUTES=172.16.0.0/24
TS_EXTRA_ARGS=--login-server=https://hb.sxxpqp.top --accept-routes --advertise-exit-node
```

内网网段、域名和节点名按实际环境修改。只需要子网互访、不提供互联网出口时，从 TS_EXTRA_ARGS 删除 --advertise-exit-node；只接受别人的路由、不发布自己的子网时，将 TS_ROUTES 留空。

本模板使用 Linux host 网络，该主机不能同时运行另一个原生或容器 tailscaled。已有原生客户端时先安排迁移，不要直接启动第二个实例。每台网关用自己的状态卷，不复制节点身份。

### 5.1 开启客户端宿主机转发

在客户端 Linux 主机执行：
```sh
sudo tee /etc/sysctl.d/99-tailscale.conf >/dev/null <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
```

已有同名文件时先合并。确认 /dev/net/tun 存在、网关能访问发布网段，且防火墙允许实际转发。

### 5.2 启动客户端

仍在 client/docker：
```sh
docker compose config --quiet
docker compose up -d
docker compose logs --since=2m --tail=100 tailscale
docker compose exec tailscale tailscale status
```

节点身份保存在命名卷中，不执行 down -v。注册完成后可移除 .env 中的注册密钥，保留状态卷。

## 6. 服务端批准路由，验证访问

回到服务端的 server/docker 目录：
```sh
docker compose exec headscale headscale nodes list-routes
```

找到客户端的实际节点 ID。下面用 1 举例，仅发布子网时：
```sh
docker compose exec headscale headscale nodes approve-routes --identifier 1 --routes 172.16.0.0/24
```

如果还提供出口节点，批准列表应包含需要保留的全部路由：
```sh
docker compose exec headscale headscale nodes approve-routes --identifier 1 --routes 172.16.0.0/24,0.0.0.0/0,::/0
```

在其他已注册 Linux 客户端执行：
```sh
sudo tailscale set --accept-routes=true
ping 172.16.0.2
```

测试实际存在且允许 ICMP 的内网设备，再验证实际 TCP 服务。需要使用互联网出口的客户端须另外选择出口节点；发布出口不会自动让其他节点走它上网。

## 7. 已部署后变更配置

编辑实际文件，勿重新复制模板。

| 修改内容 | 文件 / 操作 | 生效方法 |
| --- | --- | --- |
| Headscale 公网 IP、DNS、DERP | server/docker/config/headscale.yaml | configtest 成功后 restart headscale |
| Headplane 公网 URL、cookie_secret | server/docker/config/headplane.yaml | restart headplane；变更会话密钥会使现有登录失效 |
| 客户端环境变量 | client/docker/.env | docker compose up -d 重建容器，restart 不加载新环境变量 |
| 已认证客户端发布的路由 | 更新 .env 后执行 tailscale set | Headscale 重新批准完整路由列表 |

服务端检查并应用：
```sh
# 在 server/docker 执行
docker compose exec headscale headscale configtest
docker compose restart headscale headplane
```

客户端使用 TS_AUTH_ONCE=true，重建后复用身份；不能仅凭改环境变量保证已有节点所有登录参数被重新应用。更新已有节点的路由可在 client/docker 显式执行：
```sh
docker compose exec tailscale tailscale set --advertise-routes=172.16.0.0/24 --accept-routes=true --advertise-exit-node=true
```

按需将出口参数设为 false。更换控制服务器属于重新认证操作，单独安排；不在日常修改时反复使用 --reset。

## 8. Kubernetes 的替换位置

| 部署侧 | 文件 | 要替换的内容 |
| --- | --- | --- |
| 服务端 | server/k8s/config/headscale.yaml（从 example 复制） | 同第 2 节的域名、公网 IP、DNS |
| 服务端 | server/k8s/config/headplane.yaml（从 example 复制） | 同第 2 节的公网 URL、cookie_secret |
| 服务端 | server/k8s/ingress.yaml | rules.host、tls.hosts、IngressClass |
| 服务端 | server/k8s/workloads.yaml | REPLACE_WITH_IDC_NODE |
| 服务端 | server/k8s/storage.yaml | 按集群调整 StorageClass |
| 客户端 | client/k8s/deployment.yaml | 节点 hostname、TS_HOSTNAME、TS_ROUTES、TS_EXTRA_ARGS |
| 客户端 | tailscale-client namespace 的 tailscale-auth Secret | 将 Headplane 生成的 Pre-Auth Key 写入 authkey |
| 客户端 | client/k8s/storage.yaml | 按集群调整 StorageClass |

具体创建 Secret、证书、宿主机转发、渲染和应用命令见 [服务端 K8s 教程](server/k8s/README.md) 和 [客户端教程](client/README.md)。客户端 TS_KUBE_SECRET 保持空，状态使用 PVC，无需开放 Kubernetes API 权限。

从仓库根目录分别渲染：
```sh
kubectl kustomize server/k8s
kubectl kustomize client/k8s
```

服务端渲染前须先准备实际配置文件。渲染输出包含 Headplane 会话密钥，不公开。首次应用和配置变更都需先通过相应目录的服务端 dry-run，再 apply；最终仍要在目标环境验证路由和实际业务。
