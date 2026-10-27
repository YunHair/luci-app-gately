# luci-app-gately — Gately 管理插件 for OpenWrt

`luci-app-gately` 是一个为 OpenWrt 定制的 LuCI 界面插件，用于管理开源网络网关工具 [Gately](https://github.com/wangwanjie/gately)。本插件由 `luci-app-lucky` 适配而来，在固件更新、进程守护、目录定制与架构适配方面保持了同等能力，更新源已切换为 Gately 官方发布地址。

Gately 以单二进制方式运行，启动命令为：

```bash
./gately -c /etc/gately
```

---

## ✨ 特性亮点

- **在线更新（核心）**
  从 Gately 官方发布地址（[GitHub Releases](https://github.com/wangwanjie/gately/releases)）自动检测新版本，一键下载、校验并安装，无需手动寻找对应架构的包。

- **自定义二进制目录位置**
  可在界面中自定义 Gately 程序的完整路径（默认 `/usr/bin/gately`），更新时会将新二进制安装到该位置。

- **自定义配置文件目录**
  可在界面中自定义数据/配置目录（默认 `/etc/gately`），该目录通过启动参数 `-c` 传入；更新前会自动备份该目录。

- **进程守护（Respawn）**
  基于 procd respawn，主进程异常退出时自动重新拉起；崩溃阈值、守护延迟、最大重试次数均可自定义。

- **智能架构适配**
  自动识别设备架构并下载匹配的二进制（amd64 / arm64 / arm / mips / mipsle / riscv64）。Gately 为静态链接的 Go 程序，不依赖系统 libc。

- **自动更新**
  可开启定时任务，周期性检查并安装最新版本，间隔天数可配置。

- **备份与恢复**
  每次更新前自动备份配置目录；可在界面列出历史备份并一键恢复。

- **重置密码**
  忘记密码时，可将管理员密码重置为默认密码（`gately.cn`），随后自动重启服务。

- **界面主题**
  支持浅色 / 深色 / 跟随系统主题，以及自定义配色与背景装饰。

---

## 📌 安装须知

- 本 LuCI 插件基于 **UCODE（非 Lua）** 开发。
- 需要的最低 OpenWrt 版本：**OpenWrt 22.03 及以上**。
- 依赖：`luci-base`、`curl`。
- 不兼容基于 OpenWrt 21.02 的系统。

---

## 📦 安装

### 方式一：使用 OpenWrt SDK / 源码编译

将本目录放入 OpenWrt 源码树的 `package/` 目录：

```bash
cd openwrt
cp -a luci-app-gately package/
./scripts/feeds update luci
./scripts/feeds install luci
make package/luci-app-gately/compile V=s
```

生成的安装包位于 `bin/packages/.../packages_ci/`，使用 `opkg install` 或 `apk add --allow-untrusted` 安装。

也可直接使用 GitHub Actions（`Build luci-app-gately` 工作流）一键构建。

### 方式二：手动部署（不打包）

将文件按 `root/` 目录结构复制到目标系统：

```bash
# 假设当前为本插件目录
cp -a root/. /
chmod 755 /etc/init.d/gately /usr/libexec/gately-*.sh /usr/libexec/rpcd/luci.gately
/etc/init.d/rpcd reload
# 自行把 gately 二进制放到 /usr/bin/gately 后：
/etc/init.d/gately enable && /etc/init.d/gately start
```

安装后可在 OpenWrt 管理页面的 **服务 → Gately** 菜单中找到配置入口。

---

## ⚙️ 配置说明

通过 **服务 → Gately** 进入：

- **基本设置**
  - Web UI 端口（默认 16680，仅用于页面快捷跳转；实际端口请在 Gately 后台设置中修改）
  - 延迟启动（秒）
  - 数据目录、二进制路径、架构
  - 发布通道（稳定版 / 包含预发布版本 rc）
  - 进程守护策略、自动更新
- **运行状态**：查看运行状态、CPU/内存/进程、版本信息，启停与重启服务，打开 Web 界面。
- **下载与更新**：检查上游、选择版本与文件、一键安装；查看自动更新日志与运行日志。

---

## 🔄 更新地址

- 核心二进制更新源：`https://api.github.com/repos/wangwanjie/gately/releases`
- 下载地址：`https://github.com/wangwanjie/gately/releases/download/<tag>/...`
- 校验文件：每个发布附带 `checksums.txt`（标准 `sha256sum` 格式），安装前自动校验。

---

## 📝 与 luci-app-lucky 的差异（适配说明）

由于 Gately 与 Lucky 的发布方式、命令行能力不同，本插件做了如下适配：

| 项目 | luci-app-lucky | luci-app-gately |
| --- | --- | --- |
| 管理对象 | Lucky（gdy666/lucky） | Gately（wangwanjie/gately） |
| 二进制名 / 路径 | lucky / `/usr/bin/lucky` | gately `/usr/bin/gately` |
| 配置目录 | `/etc/config/lucky.daji` | `/etc/gately` |
| 启动参数 | `-cd <dir>` | `-c <dir>` |
| 默认端口 | 16601 | 16680 |
| 版本查询 | `-info`（JSON） | `-version`（JSON） |
| 重置密码 | 重置为 666 | 重置为默认密码 gately.cn |
| 架构命名 | x86_64 / arm64 / armv7 / mips_hardfloat… | amd64 / arm64 / arm / mips / mipsle / riscv64 |
| 校验方式 | release 内嵌 sha256 | `checksums.txt` |

**已裁剪的功能**（Gately 不提供对应能力或发布产物）：

- 官方备用镜像（`release.66666.host`）：Gately 仅通过 GitHub 发布。
- 多版本变体（标准版 / 万吉版 / 小聚 / xiaoman / Docker 等）：Gately 仅单一发布。
- 安全入口、允许外网访问的命令行写入：Gately 不提供对应命令行参数，这些请在 Gately 后台设置。
- LuCI 插件自身的在线更新区块：Gately 发布地址中不包含独立的 `luci-app-gately` 包，故该区块移除；核心更新完整保留。如后续建立独立发布地址，可再补回。
