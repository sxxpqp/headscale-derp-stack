# Kubernetes 部署

从仓库根目录执行 `cd k8s`，下面命令均在本目录执行。使用已有集群、Ingress Controller 和 StorageClass，不安装或升级这些组件。

## 1. 网络与存储前提

- 控制平面及 DERP：公网 HTTPS 443 → 已有 Ingress → Headscale Service 8080。
- 管理界面：同域名 `/admin` → Headplane Service 3000，不重写路径。
- STUN：公网 UDP 3478 → 指定 IDC 节点的 hostPort 3478 → Headscale Pod。需要 CNI 支持 hostPort、节点端口空闲并放行防火墙；如有 NAT，映射到该节点相同端口。
- Ingress 公网入口和 STUN 节点应使用同一公网 IPv4（配置中的 `derp.server.ipv4`）；本模板要求该拓扑。不同入口 IP 需要单独设计 DERP map，不能直接套用。
- 两个 1Gi ReadWriteOnce PVC，使用集群默认 StorageClass；无默认项时在 `storage.yaml` 指定已有的 `storageClassName`。固定节点应能挂载 Headscale 卷。
- 单副本 SQLite；Deployment 使用 Recreate 避免新旧 Pod 同时写库，不支持直接扩为多副本。

## 2. 准备配置和证书

```sh
cp config/headscale.example.yaml config/headscale.yaml
cp config/headplane.example.yaml config/headplane.yaml
openssl rand -hex 16
```

将随机 32 字符值填入 Headplane `cookie_secret`。替换两份配置与 `ingress.yaml` 的域名及 Headscale 公网 IP；MagicDNS 基域必须与服务域名不同。Headplane 内部通过 `http://headscale:8080` 连接。

修改 `workloads.yaml` 的 `REPLACE_WITH_IDC_NODE` 为节点实际 hostname；修改 `ingress.yaml` 的 `REPLACE_WITH_INGRESS_CLASS` 为已有 IngressClass。使用 `kubectl get nodes` 和 `kubectl get ingressclass` 查询。

```sh
kubectl apply -f namespace.yaml
kubectl -n headscale create secret tls headscale-tls \
  --cert=/实际路径/fullchain.pem --key=/实际路径/privkey.pem
```

证书续期由已有流程管理；如集群已有 cert-manager，按已配置的 Issuer 方式生成相同 Secret，勿直接重复创建。公网 DNS 指向 Ingress 入口，不开启 Cloudflare HTTP 代理。

## 3. 核对 Ingress 协议支持

`ingress.yaml` 是标准路由模板，未假定控制器类型。必须按现有控制器文档开启长连接、关闭响应缓冲，并保留 Upgrade/Connection；特别是 POST 方法携带 `Upgrade: tailscale-control-protocol`，以及 DERP Upgrade。不能仅凭普通网页可访问判断兼容。Envoy/Istio 等还需显式允许自定义升级类型。

普通 Ingress 不处理 UDP，STUN 由上面的 hostPort 暴露。不要在整个控制域名前添加 Basic Auth。Headscale `trusted_proxies` 留空时忽略来源头；只有确认代理实际来源 CIDR 后才添加精确范围。

参考：[Headscale 反向代理要求](https://headscale.net/stable/ref/integration/reverse-proxy/)、[Kubernetes Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)。控制器特定配置必须在实际集群核验。

## 4. 渲染、应用、查看版本

目标镜像版本在 `kustomization.yaml` 的 `images.newTag` 显式指定，默认 0.29.7 / 0.8.2；覆盖版本前先核对配套兼容性，不会自动升级。

```sh
kubectl kustomize .
kubectl apply --dry-run=server -k .
kubectl apply -k .
kubectl -n headscale rollout status deployment/headscale
kubectl -n headscale rollout status deployment/headplane
kubectl -n headscale exec deployment/headscale -- headscale configtest
kubectl -n headscale exec deployment/headscale -- headscale version
kubectl -n headscale get deployment -o wide
kubectl -n headscale get pods,pvc,service,ingress
```

渲染结果包含会话密钥，不提交到 Git 或公开日志。Headplane 配置由 Secret 保存，需使用集群既有 Secret 访问控制与静态加密机制。Kustomize 自动为配置添加内容 hash，重新 apply 会触发相应 Pod 更新。TCP readiness 只检查端口，不代表 DERP 业务可用。

## 5. 管理与验收

```sh
kubectl -n headscale exec deployment/headscale -- headscale users create admin
kubectl -n headscale exec deployment/headscale -- headscale apikeys create
curl -v https://你的域名/health
```

使用 API Key 登录 `https://你的域名/admin`。客户端执行 `tailscale up --login-server=https://你的域名`，按输出注册链接注册。默认 `config/policy.hujson` 拒绝节点间业务连接，先按用户及端口配置 ACL，再验证：

```sh
tailscale netcheck
tailscale debug derp-map
tailscale debug derp us-idc
tailscale ping 对端IP
```

客户端命令在注册节点执行。至少两台节点，在无法直连时确认实际走 us-idc 中继。健康检查成功不代表 STUN/中继已通过。

## 6. 备份与卸载

维护窗口将两个 Deployment 缩为 0 后，使用现有 CSI 快照或卷备份方式备份两个 PVC 及真实配置、证书 Secret，再恢复副本数为 1。恢复流程先在隔离环境验证。删除 namespace 或 `kubectl delete -k .` 会涉及 PVC 删除，底层数据是否保留取决于 PV 回收策略；有备份前不要执行。

本清单尚未在真实集群部署验证，需在目标集群执行服务端 dry-run、调度、存储、Ingress 升级协议和实际中继验收。
