# ss-2022-alpine

面向 Alpine Linux 的纯 Shadowsocks 2022 节点脚本。这是独立重写版，使用 Alpine 默认的 POSIX `sh`、`apk` 和 OpenRC，不依赖 Bash、apt/yum 或 systemd。

它只处理原生 Shadowsocks 2022 节点，不包含 ShadowTLS、simple-obfs、流量统计、地区 IP 阻断或第三方管理菜单。

## 支持范围

- Alpine Linux 3.18 及更新版本
- OpenRC 系统（不适用于未运行 OpenRC 的普通 Docker 容器）
- 官方 Shadowsocks Rust 预编译包提供的常见 Alpine/musl 架构：x86_64、aarch64、armv7/armhf、x86
- TCP 和 UDP；检测到全局 IPv6 时默认使用 `::` 双栈监听
- 多节点；每个节点有独立 JSON 配置和 OpenRC 服务

支持三种标准 SS 2022 加密方式：

- `2022-blake3-aes-128-gcm`（默认）
- `2022-blake3-aes-256-gcm`
- `2022-blake3-chacha20-poly1305`

## 快速开始

在 Alpine 服务器上进入 root shell 后，一键交互运行：

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/Sora3QwQ/ss-2022-alpine/main/ss-2022-alpine.sh)"
```

如果需要保留脚本用于后续管理，可下载本仓库后在目录中以 root 身份执行：

```sh
chmod +x ss-2022-alpine.sh
./ss-2022-alpine.sh
```

不带参数时会打开交互式管理菜单，可创建、查看、启停、重启、删除和更新节点。选择“创建节点”后，脚本会：

1. 使用 `apk` 安装缺失依赖；
2. 从 Shadowsocks Rust 官方 GitHub Release 选择当前架构的 musl 包；
3. 在发布 API 提供 digest 时校验 SHA-256；
4. 生成符合所选 SS 2022 方法长度要求的随机 Base64 密钥；
5. 写入节点配置并创建 OpenRC 服务；
6. 启用时间同步并输出 SIP002 `ss://` 分享链接。

也可以完全非交互创建：

```sh
./ss-2022-alpine.sh create \
  --name hk \
  --port 443 \
  --method 2022-blake3-aes-128-gcm \
  --host ss.example.com
```

如果需要传入密码，推荐使用环境变量，避免密码出现在进程参数中：

```sh
SS_PASSWORD='你的标准Base64密钥' \
  ./ss-2022-alpine.sh create --name hk --port 443
```

AES-128 方法的密钥解码后必须为 16 字节；AES-256 和 ChaCha20 方法必须为 32 字节。省略密码最安全，脚本会自动生成合法密钥。

节点名称允许输入大写字母，脚本会自动转换为小写；例如 `OVHupload-1` 会保存为 `ovhupload-1`。

监听地址会自动选择：服务器具有全局 IPv6 且内核允许双栈套接字时使用 `::`，同时接受 IPv4 和 IPv6；否则使用 `0.0.0.0`。也可以通过 `--listen` 显式指定。

## 常用命令

```sh
# 创建第二个节点
./ss-2022-alpine.sh create --name sg --port 8443

# 查看所有节点
./ss-2022-alpine.sh list

# 查看配置和分享链接
./ss-2022-alpine.sh show hk

# 管理服务
./ss-2022-alpine.sh status hk
./ss-2022-alpine.sh restart hk
./ss-2022-alpine.sh stop hk
./ss-2022-alpine.sh start hk

# 更新到 Shadowsocks Rust 最新稳定版，并重启原本在运行的节点
./ss-2022-alpine.sh update

# 安装指定版本
./ss-2022-alpine.sh install 1.24.0

# 删除节点（保留 ssserver 和日志）
./ss-2022-alpine.sh delete hk
```

运行 `./ss-2022-alpine.sh help` 可查看全部参数。

## 文件布局

```text
/usr/local/bin/ssserver          官方 Shadowsocks Rust 服务端
/etc/ss-rust/version             已安装版本
/etc/ss-rust/nodes/NAME.json     节点配置（权限 0600）
/etc/ss-rust/meta/NAME.json      分享地址等本地元数据（权限 0600）
/etc/init.d/ss-rust.NAME         节点的 OpenRC 服务
/var/log/ss-rust/NAME.log        标准输出
/var/log/ss-rust/NAME.err.log    错误日志
```

## 防火墙和时间

脚本不会猜测或改写你的 nftables/iptables 规则。创建后必须在云厂商安全组和服务器本机防火墙中同时放行节点端口的 TCP 与 UDP。

SS 2022 会校验时间戳。脚本会复用已经运行的时间同步服务；如果没有，则安装并尝试启动 `chronyd`。客户端和服务端的系统时间应保持准确。

示例 OpenRC 排错命令：

```sh
rc-service ss-rust.hk status
tail -n 100 /var/log/ss-rust/hk.err.log
ss -lntu | grep ':443'
```

## 安全说明

- 配置和元数据目录权限为 `0700`，包含密钥的文件权限为 `0600`。
- 下载只使用 Shadowsocks Rust 官方 GitHub Release；如果 GitHub API 返回 `sha256:` digest，脚本会强制校验。
- `--force` 会覆盖同名节点，请谨慎使用。
- `ss://` 分享链接包含节点密钥，不要发到公开渠道。

上游项目：<https://github.com/shadowsocks/shadowsocks-rust>

## 开发检查

在带有 Bash、OpenSSL 和常见 Unix 工具的开发机上，可运行不需要 root、不会改动系统的基础测试：

```sh
bash tests/smoke.sh
```

真实安装仍应在运行 OpenRC 的 Alpine 测试机或虚拟机中验证。
