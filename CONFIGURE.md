# 非交互配置生成器

编辑变量文件后运行脚本，不会逐项提问。支持服务端 / 客户端，以及 Docker / Kubernetes 四种组合。

## 使用

Linux 上需要 Bash 4+、GNU sed、grep、cp 等常用工具；服务端 COOKIE_SECRET 留空时需要 openssl。只有同时填写 TLS_CERT 和 TLS_KEY 时，生成阶段需要 kubectl（仅本地 create secret --dry-run=client，不连接集群）。部署阶段再使用现有 Docker Compose 或 kubectl。

脚本与变量模板都在对应部署目录中：

| 目标 | 进入目录 | 脚本与变量模板 |
| --- | --- | --- |
| 服务端 Docker | server/docker | configure.sh、config.example.env |
| 服务端 K8s | server/k8s | configure.sh、config.example.env |
| 客户端 Docker | client/docker | configure.sh、config.example.env |
| 客户端 K8s | client/k8s | configure.sh、config.example.env |

例如服务端 K8s，从仓库根目录：
```sh
cd server/k8s
cp config.example.env setup.env
chmod 600 setup.env
nano setup.env
bash configure.sh
```

其余目录用法相同。每个入口固定部署侧和方式，无需 ROLE 或 MODE。默认读取脚本所在目录 setup.env，也可以显式指定变量文件路径。共享校验和生成逻辑位于 lib/configure-common.sh，无需直接执行。

以后只修改变量文件，不修改脚本。变量文件是纯 KEY=value 数据：
- 不加引号，不写 export，不在等号两边加空格。
- 不展开 $变量、~ 或 $(命令)，也不执行其中的 shell 内容；证书路径写完整绝对路径。
- 空行和 # 注释可用；未知变量、重复变量或非法值会报错。
- 不会询问、安装软件、apply、启动容器、修改节点转发或改写现有文件。

### 例：服务端 K8s

在 server/k8s/setup.env 中修改这些字段；其余保留示例：
```dotenv
INSTANCE=prod
PUBLIC_URL=https://hb.sxxpqp.top:8443
PUBLIC_IPV4=替换为实际公网IPv4
NODE=替换为kubectl_get_nodes查到的hostname
INGRESS_CLASS=替换为已有IngressClass
STORAGE_CLASS=
TLS_SECRET=headscale-tls
COOKIE_SECRET=
```

上面的中文必须换成实际值。COOKIE_SECRET 留空自动生成；使用已有部署的会话密钥时填写原值。本地 TLS_CERT、TLS_KEY 不写或都留空时，直接使用 TLS_SECRET 指定的已有证书。headscale namespace 必须已有适用域名的 TLS Secret，或由现有 cert-manager 流程生成；不要因此覆盖 cert-manager 管理的 Secret。

需要由本地证书生成 Secret 配置时，改为：
```dotenv
TLS_CERT=/管理机实际路径/fullchain.pem
TLS_KEY=/管理机实际路径/privkey.pem
```

两项路径同时填写时才导入；只填写一项会报错，避免生成不完整的证书配置。旧 TLS_IMPORT 开关已弃用，现有变量文件保留它也会被忽略。

脚本只把现有证书转换为本地 Secret YAML，加入生成目录的 kustomization.yaml；不会签发证书或访问集群。Headplane 配置 Secret 仍由 secretGenerator 自动生成。

PUBLIC_URL 可以包含 HTTPS 端口，Ingress host 字段会只保留域名；Controller/NAT 的公网端口、UDP STUN 及证书续期仍由现有流程配置。

### 例：服务端 Docker

在 server/docker/setup.env 中修改：
```dotenv
INSTANCE=prod-docker
PUBLIC_URL=https://hb.sxxpqp.top:8443
PUBLIC_IPV4=替换为实际公网IPv4
TLS_CERT=/etc/letsencrypt/live/hb.sxxpqp.top/fullchain.pem
TLS_KEY=/etc/letsencrypt/live/hb.sxxpqp.top/privkey.pem
```

不使用 NODE、INGRESS_CLASS 或 StorageClass。生成 nginx/headscale.conf，需手动合并到已有 Nginx。证书路径属于 Nginx 宿主机，不会自动导入或复制证书。80 跳转和 HTTPS 监听会同步 PUBLIC_URL 的端口；公网端口映射场景可按实际拓扑再调整监听。

### 例：客户端 K8s / Docker

在 Headplane 的 Settings → Pre-Auth Keys 创建密钥，持久网关关闭 Ephemeral；它不是管理登录 API Key。

客户端 K8s 修改 client/k8s/setup.env：
```dotenv
INSTANCE=site-a
PUBLIC_URL=https://hb.sxxpqp.top:8443
NODE=替换为网关节点hostname
STORAGE_CLASS=
CLIENT_NAME=site-a-router
AUTH_KEY=替换为Headplane生成的预认证密钥
ROUTES=172.16.0.0/24
ACCEPT_ROUTES=y
EXIT_NODE=n
```

客户端 Docker 在 client/docker 目录编辑 setup.env，运行本目录 configure.sh，不填写 NODE、StorageClass。客户端会忽略服务端的公网 IP、会话密钥和 Ingress 配置。

ROUTES 支持规范 IPv4 子网地址及逗号分隔多个网段，例如 172.16.0.0/24,192.168.10.0/24，不接受 172.16.0.5/24。IPv6 路由可在生成后的配置中按客户端原生参数手动添加。

K8s 的预认证密钥写入 config/authkey，kustomization.yaml 自动生成并引用 tailscale-auth-<hash> Secret，无需重复手动创建 tailscale-auth。Docker 则写入 .env。脚本不输出密钥正文。

## 输出与部署

生成目录：
```text
.generated/
  server-k8s/prod/
  server-docker/prod-docker/
  client-k8s/site-a/
  client-docker/site-a/
```

各部署目录的 setup.env、setup.*.env 和根目录 .generated/ 已加入 .gitignore。生成文件含真实密钥，使用受控管理机保存；普通 Unix 环境下新文件默认600、目录700。同名输出目录存在时退出，不自动覆盖。失败时也可能留下部分生成文件，检查后使用新的 INSTANCE 重试。

脚本不会读取原部署中未跟踪的配置文件或私钥，仅从仓库模板生成。源 manifest 如果已被手工修改，缺少预期替换字段时会报错；可在干净仓库副本中运行，再合并自定义 ACL、DNS 或其他修改。默认复制仓库的全放行 ACL，不会自动继承旧部署自定义策略。

生成后先检查文件，再在生成目录执行脚本列出的命令。服务端 K8s 示例：
```sh
cd .generated/server-k8s/prod
kubectl kustomize . >/dev/null
kubectl apply -f namespace.yaml
kubectl apply --dry-run=server -k .
kubectl apply -k .
```

Docker 示例：
```sh
cd .generated/server-docker/prod-docker
docker compose config --quiet
docker compose run --rm headscale configtest
docker compose up -d
```

INSTANCE 只区分本地生成目录，不会创建新的 namespace、Kubernetes 资源名或 Compose 项目名。不要把不同 INSTANCE 当成互相隔离的并行部署。已有部署应先备份、比对配置和数据卷引用，再安排更新。

客户端启动前仍需在目标 Linux 节点开启转发；发布路由需 Headscale 批准。服务端 Secret、证书和 Ingress 验证见 [K8s 教程](server/k8s/README.md)。现有日志采集和监控配置不在这个生成器中重复部署，继续使用现网组件。

## 本地检查

```sh
shellcheck server/docker/configure.sh server/k8s/configure.sh client/docker/configure.sh client/k8s/configure.sh lib/configure-common.sh tests/test-configure.sh
bash -n server/docker/configure.sh
bash -n server/k8s/configure.sh
bash -n client/docker/configure.sh
bash -n client/k8s/configure.sh
bash -n lib/configure-common.sh
# 可选：本地生成测试文件并校验 Compose/Kustomize，不部署、不访问集群
bash tests/test-configure.sh
```

冒烟测试依赖 Docker Compose CLI、kubectl 和 openssl；仅使用虚构密钥，测试产物放在 .generated/。不要求 Docker 引擎在线，但需要这些 CLI 可运行。

## 从旧入口迁移

根目录 scripts/ 中的入口、模板和说明已移到对应部署目录、本说明及 lib/。把原变量值复制到相应目录 setup.env，移除 ROLE、MODE 行，运行本目录 configure.sh。生成目录格式和部署资源名称不变。共享 helper 只复用实现，部署入口均与业务配置放在一起。
