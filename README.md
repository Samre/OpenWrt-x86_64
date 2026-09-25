# OpenWrt x86_64 云编译固件

[![Release](https://img.shields.io/github/v/release/Samre/OpenWrt-x86_64?display_name=tag)](https://github.com/Samre/OpenWrt-x86_64/releases/latest)
[![Build OpenWrt](https://github.com/Samre/OpenWrt-x86_64/actions/workflows/build-openwrt.yml/badge.svg)](https://github.com/Samre/OpenWrt-x86_64/actions/workflows/build-openwrt.yml)

基于 [Lean's LEDE](https://github.com/coolsnowwolf/lede) 源码、使用 GitHub Actions 自动编译的 **x86_64 软路由固件**。编译源固定为 [Samre/lede](https://github.com/Samre/lede) 快照仓库，Update Checker 按计划检查**该快照**是否有新提交，有则自动构建，编译成功后自动发布到 [Releases](https://github.com/Samre/OpenWrt-x86_64/releases)。

## 固件信息

| 项目 | 值 |
|---|---|
| 目标平台 | x86_64 generic |
| 源码 | [Samre/lede](https://github.com/Samre/lede) master（Lean's LEDE 快照，非实时跟进 coolsnowwolf/lede） |
| 源码版本 | 见 Release 说明中的 `Samre/lede@<commit>` 或固件内 `/etc/openwrt_release` |
| 默认后台地址 | `192.168.216.10`（刷写后请确认；`config_generate` 仅在无网络配置时才生成该地址） |
| 默认账号 | `root`。`diy-part2.sh` 会移除上游写入的默认密码哈希，正常情况首次登录无密码，请登录后立即设置 |
| 防火墙架构 | firewall3 / iptables（注意：不支持依赖 firewall4/nftables 的插件） |
| 虚拟化优化 | 内置 `qemu-ga`（PVE/KVM 等虚拟机环境即装即用） |

## 下载固件

前往 [Latest Release](https://github.com/Samre/OpenWrt-x86_64/releases/latest)：

| 文件 | 用途 |
|---|---|
| `openwrt-x86-64-generic-squashfs-combined-efi.img.gz` | 主镜像，解压后直接写入硬盘/软路由 U 盘（UEFI 启动） |
| `openwrt-x86-64-generic-squashfs-rootfs.img.gz` | 仅 rootfs，用于自行分区引导的场景 |
| `openwrt-x86-64-generic-rootfs.tar.gz` | tar 格式 rootfs，适用于 LXC 容器等环境 |
| `openwrt-x86-64-generic.manifest` | 固件内全部软件包清单（检验插件是否包含以此为准） |
| `sha256sums` | 全部文件的 SHA256 校验值 |

## 内置插件

**代理上网**
- **OpenClash**（mihomo 内核）· **PassWall** · **PassWall2**

**DNS 与去广告**
- **mosdns v5**（含 LuCI 界面）
- **AdGuardHome 0.107.x**（含 LuCI 界面）

**Docker**
- dockerd 29.x + docker compose + `luci-app-docker` / `dockerman` 管理界面

**存储与文件**
- 磁盘管理（`luci-app-diskman`，含 btrfs / lsblk / mdadm）
- 文件助手（`luci-app-fileassistant`）
- 网络共享（`luci-app-ksmbd`，Samba）、自动挂载、exFAT / NTFS / btrfs 文件系统支持

**系统工具**
- **iStore** 应用商店
- ttyd 网页终端、UPnP、定时重启（`luci-app-watchcat`）
- DDNS（含阿里云 / DNSPod 脚本）、ddnsto 内网穿透
- vlmcsd（KMS 激活）、coremark 跑分、软件包管理器

**AI Agent**
- **PicoClaw**（Go 单二进制，源自 [sipeed/picoclaw](https://github.com/sipeed/picoclaw)，本仓库自行打包，见下文）

**界面**
- Argon 主题 + Argon 配置插件，中文界面

## AI Agent（PicoClaw）

固件内置 [PicoClaw](https://github.com/sipeed/picoclaw)：Go 单二进制 AI 助手，运行内存约 10–20 MB，支持 30+ 模型后端与 19+ 消息通道（Telegram、飞书/Lark、钉钉、企业微信等）。

**本仓库自行打包**（`package/picoclaw/`），不直接使用第三方 OpenWrt 包。原因是审计发现第三方包在本仓库固定的上游提交上存在多处静默失效：版本 ldflags 注入到了上游已迁移走的源码路径（Go linker 会静默忽略，固件将永远显示错误版本号）、`sed` 补丁的目标函数已不存在（二进制会忽略 `PICOCLAW_HOME`，服务起不来）、构建标签漏掉 `goolm`（丢 SQLite 支持）、以及默认把网关绑到 `0.0.0.0` 并关闭工作区限制。

### 首次使用

固件首次启动会生成默认配置，**不含任何密钥**（密钥绝不打进镜像）：

```bash
vi /etc/picoclaw/config.json     # 填 model_list[].api_key
/etc/init.d/picoclaw restart
```

### 模型后端（运行时可切换）

云端 API 与本地 Ollama 都支持，改 `config.json` 的 `agents.defaults.model_name` 即可切换，无需重装：

| 后端 | `model` 写法 | `api_base` |
|---|---|---|
| DeepSeek（默认） | `deepseek/deepseek-chat` | 留空 |
| OpenAI | `openai/gpt-4o` | 留空 |
| 本地 Ollama | `ollama/qwen3:8b` | `http://127.0.0.1:11434/v1` |

### 消息通道

通道凭据写在 `settings` **子对象**里，不是平铺的顶层字段（PicoClaw 的 `Channel.GetDecoded()` 按类型解码 `settings`，平铺写法会被静默忽略）：

```json
"feishu": {
  "enabled": true,
  "settings": { "app_id": "...", "app_secret": "...", "is_lark": false }
}
```

`is_lark` 置 `true` 表示使用国际版 Lark。飞书通道为 PicoClaw 内置，不需要额外软件包。

### 安全默认值

| 项目 | 默认 | 说明 |
|---|---|---|
| 网关监听 | `127.0.0.1:18790` | 仅回环。改绑 `0.0.0.0` 前请自行加防火墙规则与认证 |
| `restrict_to_workspace` | `1` | 文件工具限制在工作区内 |
| `heartbeat` | `0` | 关闭，避免空闲时持续消耗 API 额度 |
| 密钥存放 | `/etc/picoclaw/config.json`，权限 `0600` | 不经环境变量传递，避免出现在 `/proc/<pid>/environ` |

访问内置 Web UI 请用 SSH 端口转发，不要直接暴露端口：

```bash
ssh -L 18790:127.0.0.1:18790 root@192.168.216.10
# 然后浏览器打开 http://127.0.0.1:18790
```

> 工作区默认在 `/etc/picoclaw/workspace`（overlay 内）。overlay 容量小或希望聊天记录不随重刷丢失时，把 `uci set picoclaw.agent.workspace` 指向外置盘即可。

### 本地自检

```bash
bash tools/check-picoclaw.sh
```

在校验包定义、安全默认值与上游修订钉扎；`diy-part2.sh` 在构建时会做同一组断言，因此本机跑通即代表 CI 那一关多半能过（无需先跑一次完整 CI）。

## 云编译机制

| 工作流 | 说明 |
|---|---|
| `build-openwrt.yml` | 主编译工作流。手动触发（Actions 页面 Run workflow 或 `gh workflow run build-openwrt.yml`），或被 Update Checker 唤起。编译成功自动发布 Release，失败不发版。同一时间只跑一个构建（`concurrency` 组串行化），避免重叠运行互相覆盖产物 |
| `update-checker.yml` | 每周一凌晨 3 点（北京时间）检查**编译源快照**是否有新提交，有则自动触发编译；支持手动触发；已有构建在运行或排队时自动跳过 |

**失败重试机制**：快照源的 SHA 通过 `upstream-tracker` 标签记录，记录的是**本次实际编译的提交**，仅在编译成功后更新。构建失败不会更新标签，下一个检查点会自动重试。若编译期间快照源又有新提交，标签停在已编译的 SHA，新提交会在下一个检查点被重新构建。

## 自定义

1. **调整插件**：编辑 `.config`（`CONFIG_PACKAGE_xxx=y`）。注意核对名称是否存在于已配置的 feed 中，透明代理类插件同时只能运行一个；
2. **添加第三方源**：编辑 `diy-part1.sh`（在 feeds 更新前执行），源码里预置了 iStore、kenzok8/openwrt-packages、kenzok8/small 三个常用源；
3. **构建期定制**：编辑 `diy-part2.sh`（feeds 更新后执行），当前包含：修改默认 IP、清除 root 默认密码哈希、shortcut-fe 内核兼容补丁、PicoClaw 包的全部前置与后置断言；
4. **自建软件包**：放在仓库根的 `package/<名称>/`。workflow 会在构建前把它们合并进 `openwrt/package/`，合并时遇到同名目录会直接报错而不是覆盖。PicoClaw 即按此方式打包；
5. **本地校验**：`tools/` 下是可脱离 OpenWrt 源码树运行的静态检查脚本。

这两个 DIY 脚本都是 fail-fast 的：定制的目标文件不存在、替换没有命中，或补丁没有真正生效时，构建会直接失败并打印 `::error::`，不会静默产出一个没打补丁的固件。

构建前还有一道配置对账：`make defconfig` 之后会逐个核对 `.config` 里被选中的符号是否仍然存在，被静默丢弃就报错退出——避免"配置里写了、固件里没有"。自建包因此必须在 `diy-part2.sh` 里选中（此时 `package/` 已就位），而不能只写在提交的 `.config` 里。

另外，构建 job 只持有只读仓库权限，发布与打标签在独立的 publish job 中完成；第三方 action 全部固定到 commit SHA，不再跟随 `main` 分支。自建包同样遵循这一原则：上游源码固定到具体 commit SHA，而非跟踪 `main`。

> **naiveproxy 临时补丁**：`diy-part2.sh` 会把 `feeds/small` 里 naiveproxy 的版本从 `154.0.8037.49-1` 改写为上游已发布的 `-2`，并同步更新 x86_64 的 `PKG_HASH`（该哈希由实际下载文件实测得出，非猜测）。原因是上游在发布 `-2` 的同时删除了 `-1`，导致 feed 里钉住的下载地址变成 404，`make world` 会在编译到后续软件包之前直接中止。此补丁只改 x86_64 一个分支，且会在替换前断言目标哈希在文件中唯一，避免误改其他架构。**待 kenzok8/small 自行更新到 `-2` 后即可删除该段**（脚本已做幂等判断，届时会自动跳过）。

修改后推送到仓库并在 Actions 页手动触发即可；或等待每周自动检查。

> 注意：`.config` 里的 `CONFIG_TARGET_KERNEL_PARTSIZE=64`、`CONFIG_TARGET_ROOTFS_PARTSIZE=1024`（单位 MiB）决定镜像内的分区大小，压缩包约 300 MB，解压写入需要 ≥1.1 GiB 的磁盘空间。这两个值同时决定系统分区容量，上调可留出更多 overlay 空间，下调则影响后续固件升级时能否原地写入。

## 致谢

- [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) — Lean's LEDE 源码
- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt) — 云编译模板
- [kenzok8/openwrt-packages](https://github.com/kenzok8/openwrt-packages) & [kenzok8/small](https://github.com/kenzok8/small) — 插件源
- [linkease/istore](https://github.com/linkease/istore) — iStore 应用商店

## License

[MIT](https://github.com/Samre/OpenWrt-x86_64/blob/main/README.md) © 2019-2020 P3TERX（编译模板部分），其余修改遵循相同协议。
