# 接入现有 Prometheus / Grafana / Loki（Kubernetes）

此目录是 [Tailscale 客户端](../README.md)的可选 Kustomize overlay，不部署新的监控平台。使用 PodMonitor 采集指标，Alloy sidecar 把网关节点的访问记录写入现有 Loki。Headscale、Headplane 仍在 server/，此次不改变它们的指标暴露方式。

## 采集范围

- Prometheus：Tailscale 节点收发字节、直连 / DERP 路径、路由及健康指标。
- Loki：从 tailscale0 进入本机或经网关转发的新连接方向报文，保留时间、源 IP、目标 IP、协议及端口。
- Grafana：导入 [dashboard.json](dashboard.json)，选择现有 Prometheus 和 Loki 数据源。

这里的记录是访问尝试，不代表连接成功、应用登录成功或唯一会话数。ct state new 可能重复记录 TCP 重传和 UDP 报文；规则每链限速 20 条/秒、突发 100 条，内核或 journald 也可能限流。高流量时会漏记，因此不能当成完整合规审计。节点总流量指标不等于每个目标服务器的流量；需要逐连接字节、持续时间时另接 conntrack / ulogd2 的流量日志。

源 IP 采集在本机 SNAT 前，可把 100.64.x.x 与 Headscale 节点列表对应；本配置不自动关联用户名。它只覆盖经过此网关、进入 tailscale0 的流量，无法覆盖绕过网关的节点直连、tailscaled 在注入接口前已拒绝的访问，或 HTTPS 业务内容。

## 1. 先检查现网

需要 Prometheus Operator 的 PodMonitor CRD，Prometheus 有权发现 tailscale-client namespace 的 Pod。确认：
```sh
kubectl get crd podmonitors.monitoring.coreos.com
kubectl get prometheus -A
# 替换 namespace 和资源名，查看 selector、namespace selector 和 RBAC。
kubectl -n monitoring get prometheus YOUR_PROMETHEUS -o yaml
```

核对 spec.podMonitorSelector、spec.podMonitorNamespaceSelector；不要为了接入而直接覆盖现网 Prometheus 配置。只把本 PodMonitor 的 labels/namespace 调整到现网允许的选择范围。若 PodMonitor 必须在 monitoring namespace，可单独 apply 修改 namespace 后的 PodMonitor，并从本 overlay resources 中移除它，避免 namespace transformer 再覆盖。

此可选日志 overlay 显式启用 hostNetwork（基础客户端使用 Pod 网络）；部署前需按客户端 Docker 准备步骤在所选宿主机开启转发。status.hostIP 必须是 Prometheus 可达的受保护内网 IP。9002 是无认证指标端口，只允许监控来源访问；hostNetwork 下不能只依赖普通 Pod NetworkPolicy。确认节点 9002、127.0.0.1:12346 未被其他进程占用。

日志方案要求该 Linux 节点使用 systemd-journald，主机存在 /run/log、/var/log 和 /etc/machine-id，内核支持 nftables。Alloy 以 root 只读挂载日志，无 NET_ADMIN、privileged 或集群 API 权限；集群准入需允许这些现有网关及日志挂载。若现有节点 Alloy 已采相同日志，不重复采集。

## 2. 先准备客户端基础配置

按 [客户端教程](../README.md)准备 client/k8s/deployment.yaml 的网段，并在 deployment-patch.yaml 填写固定节点、密钥 Secret 和 PVC；该目录的 namespace、部署名称保持不变。监控 overlay 直接引用 ../k8s 基础目录，不包含另一份网关实例。

新部署和后续更新均使用本 overlay，不再同时 apply 基础目录，否则基础目录 apply 可能移除监控字段。

## 3. 替换 Loki 地址和 Prometheus 标签

从仓库根目录：
```sh
nano client/monitoring/kustomization.yaml
nano client/monitoring/podmonitor.yaml
```

将 LOKI_URL 替换成客户端 Pod 实际可达的写入地址。例如 NodePort：
```text
http://192.168.10.20:31080/loki/api/v1/push
```

这是格式示例，不是实际 IP/端口。同集群也可使用内部 Service DNS，例如 http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push；服务名和端口以现网为准。域名、非标准 HTTPS 端口也可以使用。不要填 Grafana 地址、Loki /ready 地址或查询接口。

当前按无认证、无租户填写，不发送 X-Scope-OrgID。若网关响应 401/403，再按实际配置在 config.alloy 中加认证，并用 Secret 挂载密码文件。不要把密码放 ConfigMap 或提交仓库。NodePort 只允许采集节点来源访问，尤其现网确实没有认证时。

PodMonitor 的 release 标签替换为现网 selector 要求；若 selector 使用其他标签，按实际添加/替换。不是只要创建 PodMonitor，Prometheus 就一定会发现它。

## 4. 在网关节点启用访问记录

先确认客户端可正常转发。SSH 到 deployment.yaml 中指定的 Linux 节点，在该节点准备本仓库文件。以下命令修改该节点的日志规则，不是在本地管理电脑执行：
```sh
# 仓库根目录，先检查语法和现有规则
sudo nft list ruleset
sudo nft -c -f client/monitoring/tailscale-audit.nft
sudo nft -f client/monitoring/tailscale-audit.nft
sudo nft list table inet tailscale_audit
sudo journalctl -k --since '5 minutes ago' --grep 'TS_AUDIT '
```

同名表已存在时不要再加载。日志表不改变现有放行/拒绝策略，也不会 flush ruleset；其他安全链仍可拒绝对应报文，故日志不能证明最终放行。

第一次验证成功后，按现有防火墙管理方式持久化该独立表。不要直接把带 flush ruleset 的新模板覆盖宿主机 /etc/nftables.conf，避免破坏 Tailscale、Docker 或 Kubernetes 规则。节点重启和防火墙重载后再次检查表存在。

## 5. 校验并应用监控 overlay

在管理终端从仓库根目录：
```sh
kubectl kustomize client/monitoring
kubectl apply --dry-run=server -k client/monitoring
kubectl apply -k client/monitoring
kubectl -n tailscale-client rollout status deployment/tailscale
kubectl -n tailscale-client get podmonitor tailscale-client
kubectl -n tailscale-client logs deployment/tailscale -c alloy --tail=100
```

此操作会滚动重建单副本网关，短暂中断转发，安排适当维护窗口。Alloy 状态写入原节点 PVC 的 alloy 子目录，保留读取游标；不额外建立节点身份或第二个 tailscaled。

可在已安装 Docker 的管理机先校验 Alloy 配置（无需 Loki 在线）：
```sh
docker run --rm -e NODE_NAME=validate \
  -e LOKI_URL=http://loki.example.invalid:31080/loki/api/v1/push \
  -v "$PWD/client/monitoring/config.alloy:/etc/alloy/config.alloy:ro" \
  grafana/alloy:v1.21.3 validate /etc/alloy/config.alloy
```

## 6. 验证指标、日志和 Grafana

从节点或监控网络访问实际节点内网 IP：
```sh
curl -fsS http://NODE_PRIVATE_IP:9002/metrics
```

Prometheus Targets 页面应看到 job=tailscale-client 且 UP。若无 target，优先检查 selector、namespace 和发现权限；target DOWN 时再查 NodeIP:9002、防火墙及 CNI 路由。

从已注册的另一台客户端新建到目标内网服务器的连接，例如 curl 或 SSH。先确认网关 journalctl 出现 TS_AUDIT，再在 Grafana Explore 的 Loki 数据源执行：
```logql
{app="tailscale-audit"} |= "TS_AUDIT "
```

按来源与目标筛选：
```logql
{app="tailscale-audit"} |= "SRC=100.64.0.5 " |= "DST=172.16.0.10 "
```

目标 IP、端口保留在正文，查询时解析，不做高基数索引标签。新连接持续时间很短时无需等流量累计就能查日志；只有历史已建立连接时，不会因此产生新的 ct state new 日志。

Grafana 中 Import → 上传 dashboard.json → 选择已有 Prometheus/Loki 数据源。面板包含采集状态、按路径的节点吞吐、新连接报文记录、目标 IP 报文记录量。后者不是服务器访问次数或字节统计。IPv6 指标和日志按实际内核及流量验证。

## 7. 停用与回滚

在原网关节点，只删除本方案创建的表：
```sh
sudo nft delete table inet tailscale_audit
```

若配置了该表持久化，同步移除对应加载项。管理终端恢复基础客户端并移除本 PodMonitor：
```sh
kubectl apply -k client/k8s
kubectl -n tailscale-client delete podmonitor tailscale-client
```

Kustomize apply 不会自动清理不再引用的 ConfigMap，确认旧 Alloy sidecar 已退出后再按实际 hash 删除遗留 tailscale-alloy ConfigMap。不要用 kubectl delete -k client/monitoring 回滚，它会同时删除基础客户端和 PVC。

## 官方参考

- [Tailscale 容器指标参数](https://tailscale.com/docs/features/containers/docker/docker-params)
- [Tailscale 指标定义](https://tailscale.com/docs/reference/tailscale-client-metrics)
- [Prometheus Operator API](https://prometheus-operator.dev/docs/api-reference/api/)
- [Alloy journal](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.journal/)
- [Alloy Loki 写入](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.write/)
- [nftables 日志](https://wiki.nftables.org/wiki-nftables/index.php/Logging_traffic)
