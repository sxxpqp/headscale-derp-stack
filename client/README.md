# Tailscale 客户端（独立部署）

本目录只部署 Tailscale，连接已部署的 Headscale；Headplane 仍在[服务端](../server/README.md)的 Docker / K8s 清单中。DERP/STUN 使用 Headscale 内置功能，不是第四个独立容器。

提供 Linux 宿主机 / K8s 节点网关模式：发布内网路由、接受其他路由，并可提供出口节点。Docker 使用 host 网络，K8s 使用独立 Pod 网络；后者通过特权 initContainer 开启 Pod 内 IPv4 转发，主容器使用 nftables。每台主机只运行一个 tailscaled，不要与已有原生客户端、另一个容器或 Pod 同时运行。各网关分别部署，状态卷不能复制给另一台网关。

K8s 使用已验证的 tailscale/tailscale:v1.104，Docker 保留 v1.104.5；实际兼容性及转发须在目标环境验收。

## 1. 网络准备

两种方式都需要 /dev/net/tun，并确认实际运行环境能访问要发布的网段，必要时先加载 tun 模块。以下宿主机 sysctl 步骤用于 Docker host 网络；K8s 基础模板由 initContainer 配置 Pod 网络命名空间的转发。

```sh
sudo tee /etc/sysctl.d/99-tailscale.conf >/dev/null <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
```

如果已有同名配置，先合并。host 网络下不在容器或 Pod 中重复设置这些 sysctl。宿主机防火墙须允许相应转发；本模板保持默认子网 SNAT，不要求关闭 SNAT。发布的网段不要与对端本地网络重叠。

## 2. 生成客户端注册密钥

优先通过 Headplane：**Settings → Pre-Auth Keys → Create pre-auth key**，选择所属用户、关闭 Ephemeral，按需设置 Reusable 和有效期，生成后立即复制到 Docker .env 的 TS_AUTHKEY 或 K8s tailscale-auth Secret 的 authkey。此密钥不是管理登录用的 API Key。

完整配置替换步骤见 [部署教程](../TUTORIAL.md)。也可在 Headscale 服务端执行以下命令，使用已存在用户的 ID：

```sh
# 仓库根目录进入服务端 Docker 部署目录
cd server/docker
docker compose exec headscale headscale users list
docker compose exec headscale headscale preauthkeys create --user 用户ID
```

服务端在 K8s 时，将上面的 exec 换为：
```sh
kubectl -n headscale exec deployment/headscale -- headscale users list
kubectl -n headscale exec deployment/headscale -- headscale preauthkeys create --user 用户ID
```

使用非 ephemeral 的预认证密钥注册持久网关，每个新网关单独生成。此密钥不是 Headplane 登录用的 API Key，不提交 Git。

## 3. Docker Compose

从仓库根目录执行：
```sh
cd client/docker
cp .env.example .env
chmod 600 .env
# 编辑 .env：密钥、唯一节点名、控制域名、实际内网网段
nano .env
docker compose config --quiet
docker compose up -d
docker compose logs --tail=100 tailscale
docker compose exec tailscale tailscale status
```

默认接入 https://hb.sxxpqp.top，发布 172.16.0.0/24，接受其他子网并发布出口节点。请逐项核对；不提供互联网出口时删除 TS_EXTRA_ARGS 中的 --advertise-exit-node。不发布子网时清空 TS_ROUTES。

状态保存在 tailscale-state 命名卷，保留该卷即可保持身份。不要用 down -v。注册完成后可从 .env 移除注册密钥；重建时仍需保留状态卷。

## 4. Kubernetes Pod

本模板是手动管理的单副本 Deployment，不依赖 Tailscale Operator。要求 Linux 节点、可用 PVC、可访问 /dev/net/tun，以及集群准入允许 hostPath、privileged、root 和 NET_ADMIN。基础模板不使用 hostNetwork，也无需 Docker socket 或 Kubernetes API 权限。

从仓库根目录执行：
```sh
cd client/k8s
# 修改 deployment.yaml：节点名、控制域名、Pod 可达的路由。
# 无默认 StorageClass 时修改 storage.yaml。
nano deployment.yaml
kubectl apply -f namespace.yaml
# 交互输入预认证密钥，不把真实密钥写入仓库。
read -r -s -p 'Headscale preauth key: ' TS_KEY
printf '\n'
printf '%s' "$TS_KEY" | kubectl -n tailscale-client create secret generic tailscale-auth --from-file=authkey=/dev/stdin
unset TS_KEY
kubectl kustomize .
kubectl apply --dry-run=server -k .
kubectl apply -k .
kubectl -n tailscale-client rollout status deployment/tailscale
kubectl -n tailscale-client logs deployment/tailscale --tail=100
kubectl -n tailscale-client exec deployment/tailscale -- tailscale status
```

命令中的 read 使用 Bash。Secret 已存在时通过现有 Secret 管理流程更新。状态存 PVC，TS_KUBE_SECRET 为空，禁止挂载 ServiceAccount token。调度到的节点必须能挂载该卷并访问所发布的网段，副本数保持 1；备份节点身份时不要泄露卷内私钥。readiness 仅检查已分配 IPv4，不能证明子网转发可用。

基础 K8s 模板采用你确认的配置：`--login-server=https://hs.wishfoxs.com:5443`，公告 `192.168.150.0/24,10.96.0.0/12,172.16.0.0/16`，不默认接受其他路由或发布出口。部署到其他环境时替换为实际地址和网段。

## 5. 批准路由与验收

在 Headscale Docker 服务端目录执行（K8s 服务端用 kubectl exec 替换）：
```sh
docker compose exec headscale headscale nodes list-routes
# 将 1 换为实际节点 ID；批准列表包含需要保留的全部路由。
docker compose exec headscale headscale nodes approve-routes --identifier 1 --routes 172.16.0.0/24,0.0.0.0/0,::/0
```

只提供子网时只批准实际子网。ACL 也必须放行；本项目默认全放行，可按业务收紧。需要使用子网的其他 Linux 客户端执行：
```sh
sudo tailscale set --accept-routes=true
ping 172.16.0.2
```

替换为真实存在且允许 ICMP 的目标，再测试实际 TCP 服务。出口节点需要其他客户端主动选择（仅发布不会自动切换默认出口）。两端都发布内网时，各填自己的网段；要让未安装 Tailscale 的局域网设备主动访问远端，还需在这些设备或局域网网关配置到本机的静态路由。

TS_AUTH_ONCE=true 用于复用身份，已认证后不要依赖修改环境变量自动改变所有登录参数。修改现有节点路由时先更新模板，再显式执行并批准：
```sh
# Docker 客户端目录；K8s 用 kubectl -n tailscale-client exec deployment/tailscale -- 替换前缀
docker compose exec tailscale tailscale set --advertise-routes=172.16.0.0/24 --accept-routes=true --advertise-exit-node=true
```

更换控制服务器或重新注册应单独安排，不在每次启动时执行 --reset。

## 官方参考

- [容器参数及状态持久化](https://tailscale.com/docs/features/containers/docker/docker-params)
- [子网路由](https://tailscale.com/docs/features/subnet-routers)
- [Headscale 路由审批](https://headscale.net/stable/ref/routes/)
- [固定版本](https://github.com/tailscale/tailscale/releases/tag/v1.104.5)
