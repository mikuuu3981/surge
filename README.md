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

查看完整配置：进入“协议服务管理 → 查看运行配置文件”，选择 Xray 或 Sing-box。脚本按服务进程的启动参数查找配置，完整输出磁盘文件；服务停止时明确标注默认配置。显示内容包含原始凭据，磁盘文件也可能与进程已经载入的配置不同。

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

## VLESS+Vision+REALITY 核心选择

安装 VLESS+Vision+REALITY 时可选择 Xray（默认）或 Sing-box。Sing-box 版使用独立协议键 `vless-singbox`，与 Xray 版可在不同端口同时运行；支持多端口、用户管理、分享链接和通用/Clash 订阅。

Sing-box 版与其他 Sing-box 协议共用 `vless-singbox` 服务及 `/etc/vless-reality/singbox.json`，配置或核心变更会影响同一服务的所有入站。REALITY 默认向伪装域名的 443 端口握手；域名匹配脚本托管的真实证书时，使用本地 `127.0.0.1:8443`。Vision 使用 `xtls-rprx-vision`。

卸载 Sing-box 版 VLESS 时，先校验剩余协议的配置，再重启原本正在运行的共享服务；配置生成、重启或监听检查失败会恢复原数据库、配置和服务状态。仍有 Snell 等协议时保留共享服务、原运行及自启状态和现有订阅，只有最后一个 Sing-box 协议删除后才清理共享服务。

**REALITY 防偷流量限速仅适用于 Xray。** Sing-box 版不写入 `reality_fallback_limits` 或 Xray 的 `limitFallbackUpload` / `limitFallbackDownload` 字段。

## Snell 与 Sing-box

- Snell v4/v5/v6 统一由 Sing-box v1.14.0+ 提供，与 HY2/TUIC/AnyTLS 共用 `vless-singbox` 服务。每个端口可独立使用不同的 PSK 和协议版本。
- Snell v4/v5 的服务端配置统一使用 `version: 5`，分享链接和 Surge 订阅仍保留所选的 `version=4/5`。这是 Sing-box 的协议兼容方式；不支持 Snell v5 的 QUIC 代理模式。
- Snell+ShadowTLS 使用 Sing-box 内置 ShadowTLS v3 接入 Snell；安装 Snell v6 时仍可选择 **Sing-box（默认）** 或 **Surge 官方**。已有官方安装不会自动迁移，两种实现可使用不同端口同时运行。
- Sing-box 版使用 `/etc/vless-reality/singbox.json`。支持多个端口，重复安装可添加或覆盖指定端口，卸载也按端口处理。v6 支持 `default` / `unshaped` / `unsafe-raw` 模式，PSK 沿用脚本的 16–255 位字母数字限制；迁移 v4/v5 时保留原凭据。暂不提供 Snell 多用户、用户限额和用户流量统计。
- Sing-box 版直接复用“分流管理”的现有共享规则，包括预设 GeoSite/GeoIP、自定义域名/IP、广告及访问限制、IPv4/IPv6 匹配、直连、WARP、链式代理及现有负载均衡，不另写 Snell 专属 DNS。新核心配置使用 `domain_resolver`，无需依赖旧 `domain_strategy` 弃用开关。
- 官方版继续使用独立的 `vless-snell-v6` 服务和 `/etc/vless-reality/snell-v6.conf`，保留原有 DNS 选择。默认使用官方 `v6.0.0` 正式版下载链接（[官方发布说明](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell)），已核对 amd64/aarch64 安装包与 RC2 的 SHA-256 一致；GitHub 镜像未同步时也会使用正式版。
- Surge 订阅中的 Snell v6 节点名称包含实现和端口，客户端 `mode` 与服务端一致；TFO 选择只控制客户端参数。Sing-box 节点变更先校验候选配置，重启/监听检查失败则回滚数据库、配置及服务状态；分流更新失败保留原运行配置。存在 Snell 入站时，核心更新拒绝降级至 v1.14.0 以下。
- 旧版 Mihomo 及更早独立服务中的 Snell v4/v5 节点迁移到 Sing-box，保留端口、PSK 和 ShadowTLS 参数。迁移先校验候选配置，切换失败自动回滚；成功后清理脚本托管的 Mihomo 资源。ShadowTLS 的 Snell 后端仅绑定回环地址。
- 暂停服务时延后迁移；已安装的 Sing-box 版本不足时，先通过核心管理升级再重试。无法等价迁移的旧分流或负载均衡配置会在停服前报错，保留旧节点和服务。
- WARP 支持 WGCF 与官方 SOCKS5 模式；官方模式的 UDP 保持直连。GeoSite/GeoIP 首次使用需要从 GitHub 下载规则库，之后每 24 小时更新。
- Instagram/INS 分流迁至 Sing-box，沿用 [Yuu-rules 域名列表](https://github.com/Yuu518/Yuu-rules/blob/rule-set/mihomo/geosite/instagram.list)，仅匹配 Snell v4/v5（含 ShadowTLS）入站。规则列表缓存 24 小时，更新失败时使用已有缓存；不会扩大到 HY2/TUIC/AnyTLS 或 Snell v6。
- AI 分流分为 `GeoSite-AI-Xray专属`（原 `ai-intl`，仅 Xray）与 `Sukka-AI-Sing-Box专属`（`singbox-ai`，仅 Sing-box，有 Sing-box 协议时显示 `s` 选项）。Sukka 分别使用 [non_ip](https://ruleset.skk.moe/sing-box/non_ip/ai.json) 和 [ip](https://ruleset.skk.moe/sing-box/ip/ai.json) 两份完整规则集，共用所选出口；IPv4/IPv6 限制与规则集匹配条件相交。源文件缓存到 `/etc/vless-reality/ruleset-src/`，独立编译到 `ruleset/`，配置重建时刷新超过 24 小时的缓存；更新失败使用有效旧缓存，无有效缓存则配置生成失败。添加或删除 AI 规则仅重载对应核心。
- v4/v5 入站保留 HTTP Host / TLS SNI 嗅探，供域名分流使用，不改写原始目标地址。

安全回归测试（仅临时配置，不安装服务或修改防火墙）：

```bash
# VLESS 双核心并存、多端口、用户、REALITY 握手及分享/订阅
bash tests/test-singbox-vless.sh
# VLESS Sing-box 安装事务成功路径及配置/重启/健康检查失败回滚
bash tests/test-singbox-vless-install.sh
# VLESS 卸载保留共享 Snell 服务、订阅及失败回滚
bash tests/test-singbox-vless-uninstall.sh
# Snell 多版本、多端口、共享分流、升级保护与失败回滚
bash tests/test-singbox-snell.sh
# v4/v5、ShadowTLS 及旧数据库迁移
bash tests/test-singbox-snell-migration.sh
# Instagram 域名规则、旧规则兼容与入站隔离
bash tests/test-singbox-instagram.sh
# AI 核心/出口隔离、完整源编译、缓存刷新回退与菜单/重载隔离
bash tests/test-singbox-ai.sh
# 可选：使用本机核心真实编译 AI 规则集并校验配置（不启动服务）
VLESS_TEST_SINGBOX_BIN=/usr/bin/sing-box bash tests/test-singbox-ai.sh
# 脚本自身更新、校验与失败恢复
bash tests/test-script-update.sh
# 运行配置路径识别、完整输出及停止状态
bash tests/test-runtime-config.sh
# 可选：VLESS 使用已有 Sing-box 1.14+ 执行真实配置校验（不启动监听）
VLESS_TEST_SINGBOX_BIN=/path/to/sing-box bash tests/test-singbox-vless.sh
# 可选：已有 Sing-box 1.14+ 的真实配置校验及回环 TCP/UDP 测试（需要 Python 3）
VLESS_TEST_SINGBOX_BIN=/path/to/sing-box bash tests/test-singbox-snell.sh
# 可选：真实迁移配置校验与 ShadowTLS 握手测试（还需 OpenSSL）
VLESS_TEST_SINGBOX_BIN=/path/to/sing-box bash tests/test-singbox-snell-migration.sh
```

测试使用临时目录和模拟服务；规则集使用本地测试数据，不下载规则库。真实核心流量测试只监听回环地址，不安装服务、不改防火墙。Snell 安装和迁移会写入 `/etc/vless-reality`、`/usr/local/bin` 和 systemd/OpenRC 服务目录；节点变更、迁移及核心升级会短暂重启所有 Sing-box 入站，请在维护窗口操作。

REALITY 防偷流量说明：

REALITY 对鉴权失败的连接会回落到伪装目标。如果伪装目标使用 Cloudflare 等公共 CDN，服务器可能被扫描后被当作 CDN 端口转发器，消耗额外出口流量。脚本会按照 XTLS 官方文档，仅为 **Xray** 的 VLESS+REALITY 和 VLESS+REALITY+XHTTP 写入 `limitFallbackUpload` / `limitFallbackDownload` 令牌桶限速，并为每个实例随机化参数；合法 REALITY 连接不受此限速影响。Sing-box 版不支持此限速。

这里针对的是 REALITY 的 `target` 使用 CDN 的场景；普通 Cloudflare CDN 不代理原始 TCP REALITY，需使用脚本中的 XHTTP+TLS+CDN 模式。

该限速字段由 Xray 25.6.8 起支持；如果服务器保留更早的 Xray 核心，请先在脚本的核心版本管理中升级。

官方说明：<https://xtls.github.io/config/transports/reality.html>
官方实现：<https://github.com/XTLS/Xray-core/pull/4553>
