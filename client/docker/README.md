# Tailscale 客户端 Docker

## 本目录配置生成脚本（非交互）

在本目录执行：
```sh
cp config.example.env setup.env
chmod 600 setup.env
nano setup.env
bash configure.sh
```

部署侧和方式已固定为 client/docker，不用填写 ROLE 或 MODE。结果保存到仓库根目录的 `.generated/client-docker/<INSTANCE>/`，检查后按脚本打印的命令部署。脚本不覆盖模板或已有配置，也不会自动部署。

完整变量说明见 [配置生成说明](../../CONFIGURE.md)。宿主机转发、节点注册、路由批准及原生部署步骤见 [客户端教程](../README.md)。

