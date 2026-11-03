# Kubernetes 部署

## 本目录配置生成脚本（非交互）

在本目录执行：
```sh
cp config.example.env setup.env
chmod 600 setup.env
nano setup.env
bash configure.sh
```

部署侧和方式已固定为 server/k8s，不用填写 ROLE 或 MODE。结果保存到仓库根目录的 `.generated/server-k8s/<INSTANCE>/`，检查后按脚本打印的命令部署。脚本不覆盖模板或已有配置，也不会自动部署。

已有证书 Secret 时，只填写 `TLS_SECRET=你的Secret名称`；`TLS_CERT`、`TLS_KEY` 不写或留空即可。只有同时填写两项本地证书路径时才生成证书 Secret，无需额外开关。

完整变量说明见 [配置生成说明](../../CONFIGURE.md)。也可以继续按下面的原生部署教程操作。

**先看 [部署前配置清单](../CONFIGURATION.md)**，配置文件中也已标明必改项。

从仓库根目录执行 `cd server/k8s`，下面命令均在本目录执行。使用已有集群、Ingress Controller 和 StorageClass，不安装或升级这些组件。

## 1. 网络与存储前提

- 控制平面及 DERP：公网 HTTPS 443 → 已有 Ingress → Headscale Service 8080。
- 管理界面：同域名 `/admin` → Headplane Service 3000，不重写路径。
- STUN：公网 UDP 3478 → 指定 IDC 节点的 hostPort 3478 → Headscale Pod。需要 CNI 支持 hostPort、节点端口空闲并放行防火墙；如有 NAT，映射到该节点相同端口。
- Ingress 公网入口和 STUN 节点应使用同一公网 IPv4（配置中的 `derp.server.ipv4`）；本模板要求该拓扑。不同入口 IP 需要单独设计 DERP map，不能直接套用。
- 两个 1Gi ReadWriteOnce PVC，使用集群默认 StorageClass；无默认项时在 `storage.yaml` 指定已有的 `storageClassName`。固定节点应能挂载 Headscale 卷。
- 单副本 SQLite；Deployment 使用 Recreate 避免新旧 Pod 同时写库，不支持直接扩为多副本。

## 2. 生成实际配置、ConfigMap 和 Secret

本节命令在 **server/k8s/** 目录执行。先区分各项：

| 对象 / 密钥 | 内容 | 如何生成 |
| --- | --- | --- |
| `headscale-config-<hash>` ConfigMap | Headscale 配置和 ACL | Kustomize 的 configMapGenerator 自动生成 |
| `headplane-config-<hash>` Opaque Secret | 完整 Headplane 配置，含 cookie_secret | Kustomize 的 secretGenerator 自动生成 |
| `headscale-tls` TLS Secret | 公网域名的证书链、私钥 | 手动从已有证书创建，或由已有 cert-manager 管理 |
| Headscale API Key | 登录 Headplane | Headscale 启动后执行 apikeys create；当前登录模式不需预先创建 Kubernetes Secret |
| 客户端 Pre-Auth Key | 注册 Tailscale 客户端 | 在 Headplane 创建；供 client/ 使用，不是服务端启动所需 Secret |

### 2.1 复制实际配置并生成 cookie_secret

在 Linux 管理机执行以下首次准备命令，不覆盖已有实际配置：
```sh
umask 077
mkdir -p config
[ -f config/headscale.yaml ] || cp config/headscale.example.yaml config/headscale.yaml
[ -f config/headplane.yaml ] || cp config/headplane.example.yaml config/headplane.yaml
chmod 600 config/headscale.yaml config/headplane.yaml

# 仅首次发现占位符时生成并写入，不在终端打印会话密钥。
if grep -q 'REPLACE_WITH_32_CHAR_RANDOM_VALUE' config/headplane.yaml; then
  COOKIE_SECRET="$(openssl rand -hex 16)" || exit 1
  sed -i "s/REPLACE_WITH_32_CHAR_RANDOM_VALUE/$COOKIE_SECRET/" config/headplane.yaml
  unset COOKIE_SECRET
fi
```

这会生成 32 字符会话密钥并写到 `server.cookie_secret`，后续部署不要重复轮换。两份实际配置被 .gitignore 忽略，保留在受控管理机，不提交仓库。

仓库已有 `config/policy.hujson`，默认允许所有节点互访。自定义过 ACL 时保留原文件，不用重新生成。

### 2.2 编辑域名、公网 IP 和部署目标

```sh
nano config/headscale.yaml
nano config/headplane.yaml
nano workloads.yaml
nano ingress.yaml
nano storage.yaml
```

按表替换已有字段，保留其他内容：
| 文件 | 字段 | 示例 / 要求 |
| --- | --- | --- |
| config/headscale.yaml | server_url | `https://hb.sxxpqp.top`，替换为真实域名 |
| 同上 | derp.server.ipv4 | 真实公网 IPv4，替换 `203.0.113.10` |
| 同上 | dns.base_domain | 如 `ts.corp.internal`，与控制域名不同，不用 .local |
| config/headplane.yaml | server.base_url、headscale.public_url | 与 server_url 相同，不带 /admin |
| 同上 | headscale.url | 保持 `http://headscale:8080`，这是集群内地址 |
| 同上 | server.cookie_secret | 上一步已生成，不保留示例占位符 |
| 同上 | integration.kubernetes | 保留 enabled: false 及 pod_name: "headscale" |
| workloads.yaml | REPLACE_WITH_IDC_NODE | `kubectl get nodes` 查到的实际 hostname |
| ingress.yaml | REPLACE_WITH_INGRESS_CLASS | `kubectl get ingressclass` 查到的实际 class |
| ingress.yaml | rules.host、tls.hosts | 与控制域名一致 |
| storage.yaml | storageClassName | 没有默认 StorageClass 时，两个 PVC 都指定可用项 |

公网使用非 443 端口时，两个公网 URL 都加端口，例如 `https://hb.sxxpqp.top:8443`；Ingress 的 host 字段只填域名，监听端口 / 外部映射在现有 Ingress Controller 上配置，不改内部 Service 8080/3000。

### 2.3 Headplane Secret 如何自动生成

现有 `kustomization.yaml` 已配置：
```yaml
secretGenerator:
  - name: headplane-config
    files:
      - config.yaml=config/headplane.yaml
```

这里的左侧 `config.yaml` 是 Secret 中的键名，右侧是本地源文件。执行 `kubectl apply -k .` 时会同时：
1. 把完整配置文件生成 Opaque Secret，例如 `headplane-config-abc123...`。
2. 自动将 Deployment 中 `secretName: headplane-config` 替换为实际带 hash 的名称。
3. 在 Headplane 容器挂载成 `/etc/headplane/config.yaml`。

因此本项目**不需要另执行 kubectl create secret generic headplane-config**，也不用手写 base64 或把 hash 复制到 workloads.yaml。直接 `kubectl apply -f workloads.yaml` 会绕过这些生成与替换，不能代替 `kubectl apply -k .`。

Headscale 的 ConfigMap 同样自动生成，容器内为 `/etc/headscale/config.yaml` 和 `/etc/headscale/policy.hujson`。不要把 OIDC client_secret 等敏感字段直接放进 Headscale ConfigMap；启用 OIDC 时应单独设计 Secret 挂载与 client_secret_path，当前模板未启用 OIDC。

### 2.4 创建公网证书 Secret（手动证书方式）

先创建 namespace：
```sh
kubectl apply -f namespace.yaml
```

需要已有可信域名证书；下面的命令是**导入证书，不是签发证书**。证书和私钥路径属于执行 kubectl 的这台管理机，不能填写另一台服务器上不存在于本机的路径。

将下面路径换成实际文件：
```sh
TLS_CERT='/实际路径/fullchain.pem'
TLS_KEY='/实际路径/privkey.pem'

# 可用于首次创建或更新自己手动管理的同名 Secret。
kubectl -n headscale create secret tls headscale-tls \
  --cert="$TLS_CERT" --key="$TLS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

unset TLS_CERT TLS_KEY
kubectl -n headscale describe secret headscale-tls
```

Secret 类型应为 `kubernetes.io/tls`，包含 `tls.crt` 和 `tls.key`。describe 只展示键名和大小，不显示私钥正文。Secret 必须在 headscale namespace，与 ingress.yaml 的 `spec.tls[].secretName` 一致。Headscale 和 Headplane Pod 不直接挂载它，由 Ingress Controller 使用。

该固定名称的 TLS Secret 不在 Kustomize generator 中，所以只执行 `kubectl apply -k .` 不会自动创建或签发它。

### 2.5 已有证书 Secret / cert-manager

如果 headscale namespace 已有适用域名的 TLS Secret，直接将 ingress.yaml 的 secretName 改成它的名称。其他 namespace 的同名 Secret 不能直接被这里的 Ingress 引用。

如果已由 cert-manager 签发、续期，使用现有 Issuer / Certificate 流程，确保生成 headscale namespace 中目标 TLS Secret；**跳过上面的手动创建和更新命令**，避免两个管理方式修改同一个 Secret。

不自动安装 cert-manager，也不假设现网 Issuer 名称。确认公开 DNS 指向 Ingress 入口、证书域名匹配；控制域名不开启 Cloudflare HTTP 代理。

## 3. 核对 Ingress 协议支持

`ingress.yaml` 是标准路由模板，未假定控制器类型。必须按现有控制器文档开启长连接、关闭响应缓冲，并保留 Upgrade/Connection；特别是 POST 方法携带 `Upgrade: tailscale-control-protocol`，以及 DERP Upgrade。不能仅凭普通网页可访问判断兼容。Envoy/Istio 等还需显式允许自定义升级类型。

普通 Ingress 不处理 UDP，STUN 由上面的 hostPort 暴露。不要在整个控制域名前添加 Basic Auth。Headscale `trusted_proxies` 留空时忽略来源头；只有确认代理实际来源 CIDR 后才添加精确范围。

参考：[Headscale 反向代理要求](https://headscale.net/stable/ref/integration/reverse-proxy/)、[Kubernetes Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)。控制器特定配置必须在实际集群核验。

## 4. 渲染、应用、查看版本

目标镜像版本在 `kustomization.yaml` 的 `images.newTag` 显式指定，默认 0.29.7 / 0.8.2；覆盖版本前先核对配套兼容性，不会自动升级。

```sh
kubectl kustomize . >/dev/null
kubectl apply --dry-run=server -k .
kubectl apply -k .
kubectl -n headscale rollout status deployment/headscale
kubectl -n headscale rollout status deployment/headplane
kubectl -n headscale exec deployment/headscale -- headscale configtest
kubectl -n headscale exec deployment/headscale -- headscale version
kubectl -n headscale get deployment -o wide
kubectl -n headscale get pods,pvc,service,ingress
```

渲染结果包含完整会话密钥，所以这里只校验、不打印。不要把 kubectl kustomize 的完整输出、Secret 的 -o yaml 或解码后的配置发到公开日志。Secret 的 base64 编码不是加密，需使用现网 RBAC、etcd 静态加密和受控备份。Headplane 配置由 Secret 保存，需使用集群既有 Secret 访问控制与静态加密机制。Kustomize 自动为配置添加内容 hash，重新 apply 会触发相应 Pod 更新。TCP readiness 只检查端口，不代表 DERP 业务可用。

### 4.1 检查 Secret 已生成并被正确引用

应用成功后执行，以下只查看名称、键名和字节数：
```sh
kubectl -n headscale get configmap,secret
HEADPLANE_CONFIG_SECRET="$(kubectl -n headscale get deployment headplane -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].secret.secretName}')"
printf 'Headplane config Secret: %s\n' "$HEADPLANE_CONFIG_SECRET"
kubectl -n headscale describe secret "$HEADPLANE_CONFIG_SECRET"
unset HEADPLANE_CONFIG_SECRET

kubectl -n headscale get ingress headscale -o jsonpath='{.spec.tls[*].secretName}{"\n"}'
```

Headplane Secret 应为 Opaque、键名为 config.yaml；实际名称有 Kustomize hash。Ingress 显示的 TLS Secret 名称应与第 2.4/2.5 节创建或选用的一致。

如果 Pod 为 Pending / ContainerCreating，先看 Events：
```sh
kubectl -n headscale describe pod -l app=headplane
kubectl -n headscale describe pod -l app=headscale
```

- secret not found：检查是否漏了 apply -k，是否创建了 TLS Secret，namespace / secretName 是否一致。
- 找不到 config.yaml：检查 generator 的文件键映射，不能只创建 cookie_secret 单字段 Secret 来替代整份配置。
- 配置报错：检查本地 YAML 缩进、32 字符 cookie_secret、integration.kubernetes.pod_name。
- PVC 未绑定：检查 StorageClass、容量和固定节点的卷可用性。

## 4.2 后续修改配置和更新证书

Headplane 配置应编辑本地源文件，再重新生成、应用：
```sh
nano config/headplane.yaml
kubectl kustomize . >/dev/null
kubectl apply --dry-run=server -k .
kubectl apply -k .
kubectl -n headscale rollout status deployment/headplane
```

内容变化会生成新 hash 的 Secret，Deployment 引用随之更新，触发重建；不要直接 edit 带 hash 的 Secret，否则与本地源文件脱节。轮换 cookie_secret 会使已有登录会话失效。

手动证书续期后，使用第 2.4 节相同的 create --dry-run=client | apply 命令更新固定名称 Secret；由 cert-manager 管理时交给原流程。Ingress Controller 通常会自动加载更新，仍需验证实际对外证书，不需要因此重启 Headscale 或 Headplane。

旧 hash 的 ConfigMap / Secret 不会被普通 apply 自动清理。确认 Deployment 和保留的 ReplicaSet 都不再引用后，再按现有发布保留策略清理；保留回滚所需版本。

## 5. 管理与验收

```sh
kubectl -n headscale exec deployment/headscale -- headscale users create admin
kubectl -n headscale exec deployment/headscale -- headscale apikeys create
curl -v https://你的域名/health
```

使用上面生成的 API Key 登录 `https://你的域名/admin/`。在 **Settings → Pre-Auth Keys → Create pre-auth key** 创建客户端预认证密钥；持久网关关闭 Ephemeral，按需选择 Reusable。API Key 用于管理登录，预认证密钥供客户端 TS_AUTHKEY 使用，不能混用。当前 API Key 登录模式不必把 API Key 预先写入服务端 Secret。客户端执行 `tailscale up --login-server=https://你的域名`，按输出注册链接注册。默认 `config/policy.hujson` 允许所有已注册节点相互访问所有端口；需要隔离时先收紧 ACL，再验证：

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

## Secret 官方参考

- [Kustomize 生成 Secret 与名称 hash](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
- [Kubernetes Secret](https://kubernetes.io/docs/concepts/configuration/secret/)
- [从证书文件创建 TLS Secret](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_create/kubectl_create_secret_tls/)
