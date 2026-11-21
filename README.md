# 独角鲸云 · 一键部署

支持：VLESS + REALITY + Vision (TCP) / Hysteria2 + Salamander (UDP)
适用：Debian 11/12/13、Ubuntu 20/22/24、Alpine 3.19+（NAT 容器或独立机）

## 一键部署

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/331636694/deploy/main/deploy.sh)
```

国内机器 raw 不通时可用 jsDelivr 镜像：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/331636694/deploy@main/deploy.sh)
```

> Alpine 精简镜像若没有 bash：先 `apk add bash` 再执行。

## 参数

| 命令 | 说明 |
|---|---|
| `bash deploy.sh` | 交互式部署（选 1 = VLESS+REALITY，选 2 = Hysteria2） |
| `bash deploy.sh --force` | 强制重新生成配置（旧客户端链接会失效） |
| `bash deploy.sh --uninstall` | 卸载：停服务 / 禁自启 / 删配置 / 删二进制 / 删防火墙规则 |

重复执行默认「复用已有配置」，不会打断正在使用的客户端。

## 常用命令（systemd）

```bash
systemctl status xray        # 查看状态
journalctl -u xray -f        # 查看日志
systemctl restart xray       # 重启服务
```
