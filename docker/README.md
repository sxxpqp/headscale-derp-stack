# headscale-derp-stack

**先看 [部署前配置清单](../CONFIGURATION.md)**，配置文件中也已标明必改项。

美国 IDC 自建 Headscale 控制平面、内置 DERP/STUN 和 Headplane 管理界面。Docker Compose 部署，复用宿主机已有 Nginx 的 HTTPS 443。以下命令均在 `docker/` 目录执行。

## 版本与范围

固定默认版本：Headscale 0.29.7、Headplane 0.8.2。可在 `.env` 显式修改版本；升级前核对对应版本配置、兼容性并备份。不安装 Docker，不自动升级。Kubernetes 方式见 [../k8s/README.md](../k8s/README.md)。

这是一套部署模板，尚未在目标 IDC 验证。需要 Linux、Docker Compose、域名及有效证书。域名 A 记录指向 IDC 公网地址，不开启 Cloudflare HTTP 代理。仅配置真实可达的 AAAA 记录。

## 准备

```sh
cp .env.example .env
cp config/headscale.example.yaml config/headscale.yaml
cp config/headplane.example.yaml config/headplane.yaml
mkdir -p config
cat > config/policy.hujson <<'EOF'
{
  "acls": [
    { "action": "accept", "src": ["*"], "dst": ["*:*"] }
  ]
}
EOF
openssl rand -hex 16
```

仓库已提供同名策略文件；上述创建命令会覆盖它，自定义过 ACL 时请保留原文件。Compose 已将该文件只读挂载到 `/etc/headscale/policy.hujson`。

将生成的 32 字符随机值填入 `cookie_secret`。修改两份配置及 Nginx 示例的域名；将 `203.0.113.10` 改为真实公网 IPv4。MagicDNS 的 `base_domain` 必须不同于控制域名。实际配置和 `.env` 已被 Git 忽略，不提交 API Key、证书或数据库。

## 启动

```sh
docker compose config --images
docker compose run --rm headscale configtest
docker compose up -d
docker compose exec headscale version
docker compose logs --tail=100 headscale headplane
```

启动日志应展示实际版本；与 `.env` 目标版本核对。配置未准备好前不要启动，避免文件挂载源被创建成目录。

## Nginx 与端口

参考 `nginx/headscale.conf.example` 合并到现有 Nginx；替换域名及真实证书路径。示例假设 Nginx 在宿主机，并由既有证书流程负责签发和续期。先执行 `sudo nginx -t`，成功后执行 `sudo systemctl reload nginx`。不要覆盖现有业务配置。

443/TCP 代理控制协议和 DERP；3478/UDP 必须在防火墙及安全组直接放行，不能通过普通 HTTP Ingress。80/TCP 用于跳转及现有证书流程。8080/3000 仅绑定宿主机回环地址。Nginx 必须保留自定义 Upgrade 请求头，不能在整个控制域名前添加 Basic Auth。

Nginx 若在容器中，加入相同网络后使用 `headscale:8080` 和 `headplane:3000`，不要使用容器自身的 127.0.0.1。`trusted_proxies` 默认留空，不信任外部传入 IP 头；确认实际代理来源地址后按精确 CIDR 设置。

## 管理界面和注册

```sh
docker compose exec headscale users create admin
docker compose exec headscale apikeys create
```

访问 `https://你的域名/admin`，使用 API Key 登录。默认仅启用 API 管理，不挂载 Docker socket，不允许界面修改 Headscale 文件配置。需要 SSO 时另行配置 OIDC 和服务端 API Key。

客户端执行 `tailscale up --login-server=https://你的域名`，按显示的注册链接操作。默认 `config/policy.hujson` 允许所有已注册节点相互访问所有端口；需要隔离时按实际用户、节点及端口收紧。

## 验证

```sh
curl -v https://你的域名/health
tailscale netcheck
tailscale debug derp-map
tailscale debug derp us-idc
```

客户端命令应在已注册节点上执行。需两台节点和对应 ACL，在无法直连时用 `tailscale ping 对端IP` 确认使用 us-idc 中继。HTTP 健康检查不能证明 UDP 或实际中继可用。只发布自建 DERP，服务器故障时没有其他中继兜底。

## 数据与备份

数据库、Noise/DERP 密钥分别保存在 `headscale-data`，管理界面状态保存在 `headplane-data` 命名卷。维护窗口停止服务后备份两个卷及本地实际配置，备份完成再启动；恢复操作先在隔离环境验证。`docker compose down` 保留卷，勿使用 `down -v`，它会删除数据。

## 官方参考

- https://github.com/juanfont/headscale/blob/v0.29.7/config-example.yaml
- https://headscale.net/stable/ref/derp/
- https://headscale.net/stable/ref/integration/reverse-proxy/
- https://github.com/tale/headplane/blob/v0.8.2/config.example.yaml
