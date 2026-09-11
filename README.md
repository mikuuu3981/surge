在Zyx0rx大佬基础上维护，问题反馈：  
  
[![Telegram](https://img.shields.io/badge/Telegram-@vless__vaio-26A5E4?logo=telegram&logoColor=white)](https://t.me/vless_vaio)  

vless脚本使用方法：

```bash
wget -O vless-server.sh https://raw.githubusercontent.com/mikuuu3981/surge/main/vless-server.sh && chmod +x vless-server.sh && bash vless-server.sh
```
快捷命令
```bash
vless
```

## 脚本更新渠道

在主菜单选择“检查脚本更新”后，可选择：

- 稳定版：跟随 `main` 分支，按发布版本升级（默认）。
- 测试版：跟随 `dev` 分支；即使版本号相同，只要脚本内容有变化也可以升级。

仓库发布 `dev` 分支后，已安装用户可直接检查并升级测试版：

```bash
vless --update-dev
```

首次直接使用测试版：

```bash
wget -O vless-server.sh https://raw.githubusercontent.com/mikuuu3981/surge/dev/vless-server.sh && chmod +x vless-server.sh && bash vless-server.sh
```

如果远端尚未发布 `dev` 分支，测试版升级会安全失败，不会替换当前脚本。测试版可能包含尚未稳定的功能。升级前会校验 GitHub Blob SHA 和 Bash 语法，并在原脚本旁保留 `.bak` 备份；更新渠道不会被永久记住，下次仍默认稳定版。

![image](https://tc.mozisen.com/i/29701fc8-b1bb-44a1-996f-afb172199829.png)

![image](https://tc.mozisen.com/i/db7cd00e-62ab-40a8-ab37-06b9dbf8084b.png)

nft脚本使用方法：
```bash
curl -L https://raw.githubusercontent.com/mikuuu3981/surge/main/nft.sh -o nft.sh
chmod +x nft.sh  
./nft.sh  
```

快捷命令：    
```bash  
nftm
```

## Snell 与 Mihomo

- Snell v4/v5 由 Mihomo v1.19.28+ 提供；一个进程可同时监听多个端口，且每个端口可独立使用不同的 PSK 和版本。
- Snell+ShadowTLS 使用 Mihomo 内置的 ShadowTLS v3；Snell v6 仍由官方 `snell-server-v6` 提供。
- 旧版 Snell v4/v5 安装会自动迁移到 Mihomo；冷启动时会等待所有 listener 就绪，迁移失败则自动回滚，并自动清理迁移产生的空协议记录。
- Mihomo 已纳入核心版本管理和运行状态显示。

REALITY 防偷流量说明：

REALITY 对鉴权失败的连接会回落到 `target`。如果伪装目标使用 Cloudflare 等公共 CDN，服务器可能被扫描后被当作 CDN 端口转发器，消耗额外出口流量。脚本会按照 XTLS 官方文档为 VLESS+REALITY 和 VLESS+REALITY+XHTTP 写入 `limitFallbackUpload` / `limitFallbackDownload` 令牌桶限速，并为每个实例随机化参数；合法 REALITY 连接不受此限速影响。

这里针对的是 REALITY 的 `target` 使用 CDN 的场景；普通 Cloudflare CDN 不代理原始 TCP REALITY，需使用脚本中的 XHTTP+TLS+CDN 模式。

该限速字段由 Xray 25.6.8 起支持；如果服务器保留更早的 Xray 核心，请先在脚本的核心版本管理中升级。

官方说明：<https://xtls.github.io/config/transports/reality.html>
官方实现：<https://github.com/XTLS/Xray-core/pull/4553>
