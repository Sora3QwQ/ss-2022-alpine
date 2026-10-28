#!/bin/ash
# cloudflared-manager: Alpine Linux / OpenRC
# Install the latest GitHub release and manage a supervised Cloudflare Tunnel.
set -eu
umask 027

BIN=/usr/local/bin/cloudflared
INIT=/etc/init.d/cloudflared
CONF=/etc/conf.d/cloudflared
CFGDIR=/etc/cloudflared
TOKEN=/etc/cloudflared/token
LOGDIR=/var/log/cloudflared
LOG=/var/log/cloudflared/cloudflared.log
USER=cloudflared
GROUP=cloudflared

say() { printf '[cloudflared] %s\n' "$*"; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

check_system() {
    [ -r /etc/os-release ] || die '无法读取 /etc/os-release。'
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = alpine ] || die "本脚本仅支持 Alpine Linux，检测到：${ID:-unknown}"
    command -v apk >/dev/null 2>&1 || die '未找到 apk。'
    command -v rc-service >/dev/null 2>&1 || die '未找到 rc-service（OpenRC）。'
    command -v rc-update >/dev/null 2>&1 || die '未找到 rc-update（OpenRC）。'
}

need_root() { [ "$(id -u)" -eq 0 ] || die '需要 root 权限，请用 root 运行。'; }

asset_name() {
    case "$(uname -m)" in
        x86_64|amd64)   printf 'cloudflared-linux-amd64\n' ;;
        aarch64|arm64)  printf 'cloudflared-linux-arm64\n' ;;
        armv6l|armv7l|armv8l|armhf) printf 'cloudflared-linux-arm\n' ;;
        i386|i486|i586|i686) printf 'cloudflared-linux-386\n' ;;
        *) die "不支持的 CPU 架构：$(uname -m)" ;;
    esac
}

prepare_runtime() {
    if ! command -v curl >/dev/null 2>&1; then
        say '安装 curl 和 CA 证书...'
        apk add --no-cache curl ca-certificates
    elif ! apk info -e ca-certificates >/dev/null 2>&1; then
        apk add --no-cache ca-certificates
    fi
    [ -x /sbin/supervise-daemon ] || die 'OpenRC supervise-daemon 不可用，请检查 openrc 安装。'
}

prepare_dirs() {
    if ! grep -q '^cloudflared:' /etc/group; then
        addgroup -S "$GROUP"
    fi
    if ! id "$USER" >/dev/null 2>&1; then
        adduser -S -D -H -G "$GROUP" -s /sbin/nologin "$USER"
    fi
    mkdir -p /usr/local/bin /etc/conf.d "$CFGDIR" "$LOGDIR"
    chown root:"$GROUP" "$CFGDIR"
    chmod 0750 "$CFGDIR"
    chown "$USER":"$GROUP" "$LOGDIR"
    chmod 0750 "$LOGDIR"
    touch "$LOG"
    chown "$USER":"$GROUP" "$LOG"
    chmod 0640 "$LOG"
    if [ -f "$TOKEN" ]; then
        chown root:"$GROUP" "$TOKEN"
        chmod 0640 "$TOKEN"
    fi
}

default_conf() {
    if [ ! -e "$CONF" ]; then
        cat > "$CONF" <<'EOF'
# Tunnel transport: http2 | quic | auto
CLOUDFLARED_PROTOCOL="http2"
# Edge IP preference: 4 | 6 | auto
CLOUDFLARED_IP_VERSION="4"
EOF
        chmod 0644 "$CONF"
    fi
}

write_service() {
    if [ -f "$INIT" ] && ! grep -q 'Managed by cloudflared-manager' "$INIT"; then
        backup="${INIT}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -p "$INIT" "$backup"
        say "已备份原服务文件：$backup"
    fi
    cat > "$INIT" <<'EOF'
#!/sbin/openrc-run
# Managed by cloudflared-manager
name="cloudflared"
description="Cloudflare Tunnel (supervised)"
supervisor="supervise-daemon"
command="/usr/local/bin/cloudflared"
command_user="cloudflared:cloudflared"
command_args="--no-autoupdate tunnel --logfile /var/log/cloudflared/cloudflared.log --protocol ${CLOUDFLARED_PROTOCOL:-http2} --edge-ip-version ${CLOUDFLARED_IP_VERSION:-4} run --token-file /etc/cloudflared/token"
respawn_delay=5
respawn_max=0
respawn_period=60

depend() {
    use net
    after firewall
}

start_pre() {
    if [ ! -s /etc/cloudflared/token ]; then
        eerror "缺少 Tunnel Token：/etc/cloudflared/token"
        return 1
    fi
}
EOF
    chmod 0755 "$INIT"
}

fetch_latest() {
    asset="$(asset_name)"
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/$asset"
    tempdir="$(mktemp -d /tmp/cloudflared.XXXXXX)" || die '无法创建临时目录。'
    trap 'rm -rf "$tempdir"' EXIT
    trap 'exit 1' HUP INT TERM
    say "系统：Alpine / $(uname -m)，下载资产：$asset"
    say "下载地址：$url"
    curl --fail --location --show-error --silent \
         --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
         --output "$tempdir/cloudflared" "$url" \
         || die '下载失败，请检查网络、DNS 或 GitHub 可访问性。'
    chmod 0755 "$tempdir/cloudflared"
    version="$("$tempdir/cloudflared" --version 2>&1)" \
         || die "下载的文件无法执行：$version"
    case "$version" in
        *cloudflared*version*) : ;;
        *) die "下载文件的版本输出异常：$version" ;;
    esac
    cp "$tempdir/cloudflared" "${BIN}.new.$$"
    chmod 0755 "${BIN}.new.$$"
    mv -f "${BIN}.new.$$" "$BIN"
    rm -rf "$tempdir"
    trap - EXIT HUP INT TERM
    say "已安装：$version"
}

save_token() {
    value="$1"
    [ -n "$value" ] || die 'Token 不能为空。'
    tmpfile="$(mktemp "$CFGDIR/.token.XXXXXX")" || die '无法创建临时 Token 文件。'
    chmod 0600 "$tmpfile"
    printf '%s\n' "$value" > "$tmpfile"
    chown root:"$GROUP" "$tmpfile"
    chmod 0640 "$tmpfile"
    mv -f "$tmpfile" "$TOKEN"
    unset value
    say "Token 已安全写入 $TOKEN（root:cloudflared，0640）。"
}

ask_token() {
    [ -t 0 ] || return 0
    printf '粘贴 Cloudflare Tunnel Token（不回显，直接回车则跳过）：' >&2
    value=''
    IFS= read -rs value || true
    printf '\n' >&2
    if [ -n "$value" ]; then
        save_token "$value"
    fi
    unset value
}

running() { [ -x "$INIT" ] && rc-service cloudflared status >/dev/null 2>&1; }

start_or_restart() {
    [ -s "$TOKEN" ] || {
        say '尚未设置 Token，未启用自启动，也未启动服务。'
        say '设置方式：cloudflared-manager.sh set-token'
        return 0
    }
    rc-update add cloudflared default
    if running; then
        rc-service cloudflared restart
    else
        rc-service cloudflared start
    fi
    say '已启用开机自启和 OpenRC 守护（异常退出会自动重启）。'
}

install_all() {
    need_root
    prepare_runtime
    prepare_dirs
    default_conf
    fetch_latest
    write_service
    [ -s "$TOKEN" ] || ask_token
    start_or_restart
}

update_binary() {
    need_root
    [ -x "$INIT" ] || die '尚未安装服务，请先执行 install。'
    prepare_runtime
    was_running=0
    if running; then was_running=1; fi
    fetch_latest
    if [ "$was_running" -eq 1 ]; then
        rc-service cloudflared restart
        say '更新成功，服务已重启。'
    else
        say '更新成功；服务此前未运行，未擅自启动。'
    fi
}

set_token_cmd() {
    need_root
    prepare_dirs
    if [ "${1:-}" != '' ]; then
        [ -r "$1" ] || die "Token 文件不可读：$1"
        value="$(cat "$1")"
        save_token "$value"
        unset value
    else
        [ -t 0 ] || die '非交互环境请使用：set-token /path/to/token-file'
        ask_token
    fi
    if [ -s "$TOKEN" ] && [ -x "$INIT" ]; then
        start_or_restart
    elif [ ! -x "$INIT" ]; then
        say 'Token 已保存，请执行 install 安装服务。'
    fi
}

config_cmd() {
    need_root
    [ -t 0 ] || die 'config 需要在交互终端运行。'
    default_conf
    # shellcheck disable=SC1090
    . "$CONF"
    old_proto="${CLOUDFLARED_PROTOCOL:-http2}"
    old_ip="${CLOUDFLARED_IP_VERSION:-4}"
    printf '协议 http2/quic/auto [%s]：' "$old_proto"
    IFS= read -r proto || true
    proto="${proto:-$old_proto}"
    case "$proto" in http2|quic|auto) : ;; *) die '协议必须为 http2、quic 或 auto。' ;; esac
    printf '边缘 IP 版本 4/6/auto [%s]：' "$old_ip"
    IFS= read -r ip || true
    ip="${ip:-$old_ip}"
    case "$ip" in 4|6|auto) : ;; *) die 'IP 版本必须为 4、6 或 auto。' ;; esac
    printf 'CLOUDFLARED_PROTOCOL="%s"\nCLOUDFLARED_IP_VERSION="%s"\n' "$proto" "$ip" > "$CONF"
    chmod 0644 "$CONF"
    say "已配置：协议 $proto，边缘 IP $ip"
    if running; then rc-service cloudflared restart; fi
}

status_cmd() {
    say "系统：$(uname -m) / Alpine Linux"
    if [ -x "$BIN" ]; then "$BIN" --version; else say '未安装 cloudflared 二进制。'; fi
    if [ -x "$INIT" ]; then
        rc-service cloudflared status || true
    else
        say '未安装 OpenRC 服务。'
    fi
    if rc-update show default 2>/dev/null | grep -Eq '(^|[[:space:]])cloudflared([[:space:]]|$)'; then
        say '开机自启：已启用（default）。'
    else
        say '开机自启：未启用。'
    fi
    if [ -s "$TOKEN" ]; then say 'Token：已配置（不显示内容）。'; else say 'Token：未配置。'; fi
    if [ -f "$CONF" ]; then
        # shellcheck disable=SC1090
        . "$CONF"
        say "连接配置：${CLOUDFLARED_PROTOCOL:-http2} / IPv${CLOUDFLARED_IP_VERSION:-4}"
    fi
}

logs_cmd() {
    [ -f "$LOG" ] || die "日志文件不存在：$LOG"
    case "${1:-}" in
        -f|follow) tail -n 100 -f "$LOG" ;;
        '') tail -n 100 "$LOG" ;;
        *) die 'logs 仅支持 -f 或不带参数。' ;;
    esac
}

uninstall_cmd() {
    need_root
    purge=0
    if [ "${1:-}" = '--purge' ]; then
        [ -t 0 ] || die '清除 Token 需要交互终端确认。'
        printf '将卸载服务并永久删除 Token 和日志，输入 DELETE 确认：'
        answer=''
        IFS= read -r answer || true
        [ "$answer" = DELETE ] || { say '已取消卸载及数据清除。'; return 0; }
        purge=1
    fi
    [ -x "$INIT" ] && rc-service cloudflared stop >/dev/null 2>&1 || true
    rc-update del cloudflared default >/dev/null 2>&1 || true
    rm -f "$INIT" "$BIN" "$CONF"
    if [ "$purge" -eq 1 ]; then
        rm -rf "$CFGDIR" "$LOGDIR"
        say '服务、Token 和日志均已删除。'
    else
        say "已卸载；保留 $CFGDIR 和 $LOGDIR，以便需要时恢复。"
        say '彻底清除：cloudflared-manager.sh uninstall --purge'
    fi
}

help_cmd() {
    cat <<'EOF'
Alpine cloudflared 管理器（OpenRC + supervise-daemon）
用法：sh cloudflared-manager.sh <命令>

  install                 自动下载最新版，部署 OpenRC 服务并启动
  update                  更新到 GitHub 最新稳定版（运行中则重启）
  set-token [文件路径]     安全设置 Tunnel Token，自动启用并重启
  config                  交互设置 http2/quic/auto、IPv4/IPv6
  start | stop | restart  启动、停止、重启
  status                  查看版本、服务状态和开机自启
  logs [-f]               查看最后 100 行日志；-f 持续跟踪
  enable | disable        设置/取消开机自启
  uninstall [--purge]     卸载；默认保留 Token 和日志
  menu                    交互管理菜单
  help                    显示帮助

默认：HTTP/2 + IPv4，Token 文件 /etc/cloudflared/token
EOF
}

main_command() {
    cmd="${1:-menu}"
    shift || true
    case "$cmd" in
        install) install_all ;;
        update) update_binary ;;
        set-token) set_token_cmd "${1:-}" ;;
        config) config_cmd ;;
        start) need_root; rc-service cloudflared start ;;
        stop) need_root; rc-service cloudflared stop ;;
        restart) need_root; rc-service cloudflared restart ;;
        status) status_cmd ;;
        logs) logs_cmd "${1:-}" ;;
        enable)
            need_root
            [ -x "$INIT" ] || die '请先运行 install。'
            [ -s "$TOKEN" ] || die '请先设置 Token。'
            rc-update add cloudflared default
            ;;
        disable) need_root; rc-update del cloudflared default ;;
        uninstall) uninstall_cmd "${1:-}" ;;
        help|-h|--help) help_cmd ;;
        *) die "未知命令：$cmd（运行 help 查看命令）" ;;
    esac
}

menu() {
    [ -t 0 ] || { help_cmd; return 0; }
    while :; do
        printf '\n===== Alpine cloudflared 管理器 =====\n'
        printf ' 1) 安装/重装最新版本\n 2) 更新版本\n 3) 设置 Token\n'
        printf ' 4) 启动服务\n 5) 停止服务\n 6) 重启服务\n'
        printf ' 7) 查看状态\n 8) 查看日志\n 9) 调整协议/IP\n'
        printf '10) 开机自启\n11) 取消开机自启\n12) 卸载\n 0) 退出\n'
        printf '请选择：'
        IFS= read -r choice || break
        case "$choice" in
            1) main_command install ;;
            2) main_command update ;;
            3) main_command set-token ;;
            4) main_command start ;;
            5) main_command stop ;;
            6) main_command restart ;;
            7) main_command status ;;
            8) main_command logs ;;
            9) main_command config ;;
            10) main_command enable ;;
            11) main_command disable ;;
            12) main_command uninstall ;;
            0) break ;;
            *) say '无效选项。' ;;
        esac
    done
}

check_system
if [ "${1:-menu}" = menu ]; then menu; else main_command "$@"; fi
