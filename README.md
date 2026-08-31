# OpenWrt x86_64 云编译固件

[![Release](https://img.shields.io/github/v/release/Samre/OpenWrt-x86_64?display_name=tag)](https://github.com/Samre/OpenWrt-x86_64/releases/latest)
[![Build OpenWrt](https://github.com/Samre/OpenWrt-x86_64/actions/workflows/build-openwrt.yml/badge.svg)](https://github.com/Samre/OpenWrt-x86_64/actions/workflows/build-openwrt.yml)

基于 [Lean's LEDE](https://github.com/coolsnowwolf/lede) 源码、使用 GitHub Actions 自动编译的 **x86_64 软路由固件**。上游有新提交时按计划自动构建，编译成功后自动发布到 [Releases](https://github.com/Samre/OpenWrt-x86_64/releases)。

## 固件信息

| 项目 | 值 |
|---|---|
| 目标平台 | x86_64 generic |
| 源码 | [Samre/lede](https://github.com/Samre/lede)（Lean's LEDE master 分支） |
| 默认后台地址 | `192.168.216.10` |
| 默认账号 | `root`（默认无密码，首次登录请自行设置） |
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

**界面**
- Argon 主题 + Argon 配置插件，中文界面

## 云编译机制

| 工作流 | 说明 |
|---|---|
| `build-openwrt.yml` | 主编译工作流。手动触发（Actions 页面 Run workflow 或 `gh workflow run build-openwrt.yml`），或被 Update Checker 唤起。编译成功自动发布 Release，失败不发版 |
| `update-checker.yml` | 每周一凌晨 3 点（北京时间）检查上游 LEDE 是否有新提交，有则自动触发编译；支持手动触发；编译已在运行时自动跳过 |

**失败重试机制**：上游 SHA 通过 `upstream-tracker` 标签记录，仅在编译成功后更新。构建失败不会更新标签，下一个检查点会自动重试。

## 自定义

1. **调整插件**：编辑 `.config`（`CONFIG_PACKAGE_xxx=y`）。注意核对名称是否存在于已配置的 feed 中，透明代理类插件同时只能运行一个；
2. **添加第三方源**：编辑 `diy-part1.sh`（在 feeds 更新前执行），源码里预置了 iStore、kenzok8/openwrt-packages、kenzok8/small 三个常用源；
3. **构建期定制**：编辑 `diy-part2.sh`（feeds 更新后执行），当前包含：修改默认 IP、清除 root 密码、shortcut-fe Linux 6.18+ 内核兼容补丁。

修改后推送并在 Actions 页手动触发即可；或等待每周自动检查。

## 致谢

- [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) — Lean's LEDE 源码
- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt) — 云编译模板
- [kenzok8/openwrt-packages](https://github.com/kenzok8/openwrt-packages) & [kenzok8/small](https://github.com/kenzok8/small) — 插件源
- [linkease/istore](https://github.com/linkease/istore) — iStore 应用商店

## License

[MIT](https://github.com/Samre/OpenWrt-x86_64/blob/main/README.md) © 2019-2020 P3TERX（编译模板部分），其余修改遵循相同协议。
