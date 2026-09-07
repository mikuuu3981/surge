# Mihomo Snell 多入站支持设计

日期：2026-09-07

## 背景

当前 `vless-server.sh` 使用 Surge 官方 `snell-server`、`snell-server-v5` 和
`snell-server-v6` 二进制。每个版本绑定一个固定配置文件和独立服务，因此 Snell
v4、v5 实际上每种只能运行一个节点。Snell+ShadowTLS 还需要一个外置
`shadow-tls` 前端和一个 Snell 后端服务。

Mihomo 从 v1.19.26 开始提供 Snell v4/v5 入站，从 v1.19.28 开始为 Snell listener
提供内置 ShadowTLS。Mihomo 文档当前仅声明支持 Snell v1-v5，不支持 v6。

一手资料：

- [Mihomo PR #2817：Snell v4/v5 outbound 与 inbound](https://github.com/MetaCubeX/mihomo/pull/2817)
- [Mihomo v1.19.26](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.26)
- [Mihomo v1.19.28](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.28)
- [Mihomo Snell listener 配置](https://github.com/MetaCubeX/Meta-Docs/blob/main/docs/config/inbound/listeners/snell.en.md)

## 目标

1. 用一个 Mihomo 进程同时托管任意数量的 Snell v4/v5 入站。
2. 每个节点拥有独立端口和 PSK，并允许 v4、v5 混合运行。
3. Snell+ShadowTLS 改用 Mihomo 内置 ShadowTLS v3；每个节点拥有独立端口、Snell
   PSK、ShadowTLS 密码和 SNI。
4. 自动迁移当前脚本管理的 Snell v4/v5 与 Snell+ShadowTLS 节点。
5. 保留 Surge 官方 `snell-server-v6` 作为 Snell v6 的唯一实现。
6. 为 Mihomo 提供与 Xray、Sing-box 相同层级的核心版本查询、通道选择、指定版本安装、
   变更日志和回滚能力。
7. 保持现有 Surge 节点信息、订阅、systemd/OpenRC 和发行版兼容能力。

## 非目标

- 不通过 Mihomo 实现 Snell v6。
- 不修改 SS2022+ShadowTLS 的 Xray 后端与外置 ShadowTLS 架构。
- 不把多个端口合并为一个共享 PSK 的端口范围；每个端口始终是独立节点。
- 不新增 Mihomo 控制面板、REST API 或流量统计。
- 不迁移用户在本脚本之外维护的 Mihomo 实例。

## 核心边界

新增第四类核心 `mihomo`：

```text
MIHOMO_PROTOCOLS="snell snell-v5 snell-shadowtls snell-v5-shadowtls"
```

上述协议从 `STANDALONE_PROTOCOLS` 移除。`snell-v6` 继续属于独立协议，原官方
二进制、配置、版本管理和服务均保持不变。`ss2022-shadowtls` 也继续属于当前独立
组合协议，不进入 Mihomo。

脚本管理的 Mihomo 使用以下独立资源，避免覆盖用户自行安装的 Mihomo：

- 二进制：`/usr/local/bin/vless-mihomo`
- 配置：`$CFG/mihomo.yaml`
- 服务：`vless-mihomo`
- 进程标识：`vless-mihomo`

最低允许版本为 v1.19.28。首次安装默认选择不低于该版本的最新稳定版；核心版本管理可
选择稳定版、GitHub 预发布版或指定版本，但任何通道都必须拒绝低于最低版本的目标。

## 数据模型

数据库新增 `.mihomo` 根对象。四个协议键下均允许单对象旧格式和数组格式，但新写入
统一采用数组语义；每个元素代表一个独立 listener。

普通 Snell 节点：

```json
{
  "port": 41001,
  "psk": "independent-snell-psk",
  "version": 4
}
```

ShadowTLS 节点：

```json
{
  "port": 42001,
  "psk": "independent-snell-psk",
  "version": 5,
  "sni": "www.microsoft.com",
  "stls_password": "independent-shadowtls-password"
}
```

迁移后不再保存或使用 `snell_backend_port`。生成器必须接受历史单对象和数组数据，
但数据库的新增、替换、删除操作继续以“协议 + 端口”唯一定位节点。

所有 Mihomo Snell 协议之间也必须检查端口唯一性；不能只在同一个协议键内检查。

## Mihomo 配置生成

`generate_mihomo_config` 从 `.mihomo` 的四组记录重新构造完整配置。每条记录生成一个
listener，而不是利用 Mihomo 的多端口范围语法。listener 名称包含版本、是否启用
ShadowTLS 和端口，例如：

```text
snell-v4-41001
snell-v5-stls-42001
```

普通 listener 的语义为：

```yaml
listeners:
  - name: snell-v4-41001
    type: snell
    listen: "::"
    port: 41001
    psk: independent-snell-psk
    version: 4
    udp: true
```

ShadowTLS listener 的语义为：

```yaml
listeners:
  - name: snell-v5-stls-42001
    type: snell
    listen: "::"
    port: 42001
    psk: independent-snell-psk
    version: 5
    udp: true
    shadow-tls:
      enable: true
      version: 3
      users:
        - name: snell-v5-stls-42001
          password: independent-shadowtls-password
      handshake:
        dest: www.microsoft.com:443
```

实际文件由 `jq` 构造 JSON 数据后写入；JSON 是 YAML 的兼容子集。不得通过未转义的
字符串拼接密码或 SNI。顶层配置提供直接出站规则，所有 Snell 入站默认走 `DIRECT`。

监听地址复用脚本当前的双栈探测：支持双栈时使用 `::`，否则使用 `0.0.0.0`。不能在
不支持 IPv6 的主机上强制双栈。`udp: true` 表示 Snell UDP-over-TCP；Snell v5 QUIC
Proxy Mode 不在支持范围。

配置写入流程：

1. 在 `$CFG` 下创建权限为 `600` 的临时文件。
2. 生成完整候选配置。
3. 执行 `/usr/local/bin/vless-mihomo -t -f <候选文件>`。
4. 校验成功后原子移动为正式配置。
5. 校验失败时删除候选文件，不触碰当前配置和服务。

## 新装与节点管理

协议菜单继续显示 Snell v4、Snell v5 和 Snell v6。选择 v4/v5 时：

1. 安装或确认脚本托管的 Mihomo 满足最低版本。
2. 询问是否启用 ShadowTLS v3。
3. 选择一个未占用端口。
4. 为该节点生成独立 Snell PSK；ShadowTLS 节点再生成独立 ShadowTLS 密码并选择 SNI。
5. 将候选节点写入数据库事务副本，生成并校验候选配置。
6. 配置有效后提交数据库与配置并重启共享服务。
7. 服务或端口健康检查失败时恢复修改前的数据库和配置。

已有 v4/v5 节点不再触发独立协议的“重新安装并覆盖”流程，而是进入现有多端口管理
流程。普通与 ShadowTLS 节点、v4 与 v5 节点可任意组合。替换和删除按端口操作；删除
一个节点不得停止其他节点。删除最后一个 Mihomo Snell 节点时，停止并禁用共享服务。

## 自动迁移

当新版脚本发现 `.xray` 下存在以下任一键、且迁移完成标记
`$CFG/.mihomo-snell-migrated-v1` 不存在时，自动迁移：

- `snell`
- `snell-v5`
- `snell-shadowtls`
- `snell-v5-shadowtls`

迁移发生在脚本完成 root、平台、依赖和数据库初始化之后、显示主菜单之前。流程必须
幂等。离线或失败时保留旧服务，下次启动脚本再次尝试。

### 迁移事务

1. 记录旧服务的运行与启用状态。
2. 创建数据库、旧配置和服务定义的临时备份。
3. 下载并验证 Mihomo，构造数据库候选副本。
4. 将历史单对象或数组逐项复制到 `.mihomo`；ShadowTLS 保留公开端口、PSK、密码、
   SNI，丢弃候选数据中的旧后端端口。
5. 从候选数据库生成候选 Mihomo 配置并执行 `-t` 校验。此时旧服务保持运行。
6. 校验成功后停止相关旧 v4/v5、Snell ShadowTLS 前端与后端服务，解决端口占用。
7. 原子提交候选数据库和配置，启动 `vless-mihomo`。
8. 检查共享进程状态，并使用 `ss` 确认每个候选 TCP 端口均在监听。
9. 全部成功后执行旧资源清理，写入权限为 `600` 的
   `$CFG/.mihomo-snell-migrated-v1`，并删除临时备份。

如果第 6 步之后失败，迁移器必须停止 Mihomo、恢复旧数据库/配置/服务定义，并根据第
1 步记录恢复旧服务原来的运行与启用状态。回滚完成前不能报告迁移失败处理完毕。

### 成功后的立即清理

迁移健康检查通过后，不长期保留旧 Snell v4/v5 回退副本：

- 删除旧 `vless-snell`、`vless-snell-v5` 及 Snell ShadowTLS 前端/后端 unit 或
  OpenRC 脚本。
- 删除 `snell.conf`、`snell-v5.conf`、`snell-shadowtls.conf` 和
  `snell-v5-shadowtls.conf`。
- 删除 `/usr/local/bin/snell-server` 与 `/usr/local/bin/snell-server-v5`。
- 不删除 `/usr/local/bin/snell-server-v6` 及其配置和服务。

SS2022+ShadowTLS 保持现状。若数据库存在 `.xray["ss2022-shadowtls"]`，必须保留
`/usr/local/bin/shadow-tls`、SS2022 后端配置及其服务。若不存在该记录，仍需检查
systemd/OpenRC 服务是否引用该二进制；只有确认没有其他引用且文件属于本脚本管理时
才可删除。无法证明归属时保留文件并给出提示。后续由脚本安装外置 ShadowTLS 时写入
托管标记，以便准确清理。

## 服务、状态与更新

`vless-mihomo` 的 systemd/OpenRC 定义直接执行脚本托管二进制与配置。只要数据库中
至少有一个 Mihomo Snell 节点，该服务就应加入开机启动。

启动、停止、重启、Watchdog、状态页、日志页、SELinux 上下文恢复、强制清理和完整
卸载都必须认识共享服务。状态页先显示 Mihomo 核心状态，再逐项显示每个 Snell 节点
的端口监听状态；不能再按 `snell-server` 进程名判断 v4/v5。

核心版本管理菜单新增 Mihomo，并与 Xray、Sing-box 使用一致的交互和缓存框架：

- 版本总览显示“当前版本、最新稳定版、最新 GitHub 预发布版、是否可更新”。
- 使用 `MetaCubeX/mihomo` 独立缓存键保存稳定版、预发布版、版本列表和不可用标记，
  复用现有缓存 TTL、后台刷新和“重新获取版本”功能。
- 更新菜单支持稳定通道、预发布通道和指定版本；指定版本菜单列出对应 Release，并允许
  输入带或不带 `v` 前缀的版本号。
- 所有候选版本先规范化并比较，低于 v1.19.28、无法解析或没有适配资产时拒绝安装。
- 从 GitHub Release 读取所选版本的变更日志摘要，更新完成后展示。
- 根据主机架构选择 Linux 资产；AMD64 优先兼容构建，ARM64 使用对应原生构建。
- 使用 GitHub Release 资产摘要验证下载；没有可验证摘要时拒绝安装。
- 当前版本由 `/usr/local/bin/vless-mihomo` 自身的版本命令解析；未安装、未知版本和
  预发布后缀必须正确显示。
- 升级前备份当前二进制，沿用现有核心备份目录和“仅保留最近三个备份”的策略。
- 安装后先用新二进制校验现有配置，再重启并检查全部 Snell 监听端口。
- 校验、启动或端口健康检查失败时恢复旧二进制并恢复服务；没有运行中的 Snell 节点时
  允许只安装或切换核心而不启动服务。

## 订阅与展示

每个端口独立生成节点信息。普通 Snell 继续输出当前自定义 `snell://` 链接与 Surge
节点行。ShadowTLS 的 Surge 节点行必须包含：

- `psk`
- `version=4` 或 `version=5`
- `shadow-tls-password`
- `shadow-tls-sni`
- `shadow-tls-version=3`

节点名称加入端口或稳定序号以避免多节点重名。IPv4、IPv6、详情页、总览、订阅文件
与 join 信息都必须遍历数组，不能只读取单对象。Snell v6 输出保持原样。

## 安全与错误处理

- 保持全局 `umask 077`，数据库、配置、迁移标记与临时备份不得放宽权限。
- 端口、版本、PSK、ShadowTLS 密码和 SNI 在进入数据库前完成校验。
- 生成器拒绝缺失字段、Snell v6、重复端口和不支持的 ShadowTLS 版本。
- 数据库变更、配置替换和服务重启作为一个可回滚事务处理。
- 下载失败、摘要不匹配、配置测试失败或健康检查失败都不能清理旧服务。
- 只清理脚本拥有的服务与文件；无法确认归属的共享二进制宁可保留。

## 测试策略

### 非破坏性自动检查

- `bash -n vless-server.sh`
- `bash -n nft.sh`
- `bash vless-server.sh --help`
- 使用 Mihomo `-t` 校验生成的测试配置。

### 配置生成用例

- 单个 v4、单个 v5。
- 多个不同端口和不同 PSK。
- v4/v5 混合。
- 普通与 ShadowTLS 混合。
- 每个 ShadowTLS listener 的密码、SNI、用户名和握手目标正确。
- 单栈与双栈监听。
- 重复端口、无效版本、缺失密码和无效 SNI 被拒绝。

### 核心版本管理用例

- 正确解析当前版本、稳定版和带预发布后缀的版本。
- 缓存有效时不重复请求，强制刷新时更新稳定版和预发布版缓存。
- 稳定、预发布和指定版本三个入口均选择正确 Release 与架构资产。
- 拒绝低于 v1.19.28、摘要缺失、摘要不匹配和无适配资产的版本。
- 新二进制配置校验、服务启动或端口检查失败时恢复旧二进制。
- 成功更新后展示变更日志并只保留最近三个备份。

### 迁移用例

- 历史单对象格式。
- 历史数组格式。
- 四种目标协议同时存在。
- 存在 SS2022+ShadowTLS 时保留外置 ShadowTLS。
- 配置校验失败时旧服务不停机。
- 停止旧服务后 Mihomo 启动失败时完整回滚。
- 成功后清理旧 v4/v5 资源但保留 Snell v6。
- 重复执行迁移不重复节点、不误删资源。

### 隔离环境验证

实际安装、systemd/OpenRC 切换、防火墙与 ShadowTLS 握手只能在隔离 VM 或容器中执行。
至少验证两个不同端口和不同 PSK 的节点可同时连接，并验证 v4、v5、ShadowTLS v3 与
Snell v6 并存。

## 验收标准

1. 同一台服务器可同时运行至少两个不同端口、不同 PSK 的 Snell 节点。
2. v4、v5、普通 Snell 和内置 ShadowTLS 可由一个 `vless-mihomo` 进程混合托管。
3. 新增、替换或删除一个节点不会丢失其他 listener。
4. 旧 v4/v5 节点自动迁移，客户端参数保持不变。
5. 迁移失败时旧服务恢复到原状态，迁移成功后旧 v4/v5 资源立即清理。
6. SS2022+ShadowTLS 和 Snell v6 不受迁移影响。
7. 核心版本菜单可查看和更新 Mihomo 的稳定版、预发布版与指定版本，且失败可回滚。
8. 所有生成配置通过 Mihomo 校验，脚本通过 Bash 语法与帮助路径检查。
