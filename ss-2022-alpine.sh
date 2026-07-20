#!/bin/sh

# Alpine Linux Shadowsocks 2022 node manager.
# POSIX sh only: no Bash, systemd, ShadowTLS, plugin, firewall, or traffic-manager code.

set -eu
umask 077

SCRIPT_VERSION="1.1.0"
PROGRAM_NAME="ss-2022-alpine"

INSTALL_DIR="${SS_INSTALL_DIR:-/etc/ss-rust}"
CONFIG_DIR="${INSTALL_DIR}/nodes"
META_DIR="${INSTALL_DIR}/meta"
VERSION_FILE="${INSTALL_DIR}/version"
BINARY_PATH="${SS_BINARY_PATH:-/usr/local/bin/ssserver}"
INIT_DIR="${SS_INIT_DIR:-/etc/init.d}"
LOG_DIR="${SS_LOG_DIR:-/var/log/ss-rust}"
GITHUB_API="${SS_GITHUB_API:-https://api.github.com/repos/shadowsocks/shadowsocks-rust}"

DEFAULT_METHOD="2022-blake3-aes-128-gcm"
TEMP_DIR=""

if [ -t 1 ]; then
    C_RED='\033[31m'
    C_GREEN='\033[32m'
    C_YELLOW='\033[33m'
    C_CYAN='\033[36m'
    C_RESET='\033[0m'
else
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_CYAN=''
    C_RESET=''
fi

info() {
    printf '%b[信息]%b %s\n' "$C_GREEN" "$C_RESET" "$*"
}

warn() {
    printf '%b[警告]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

die() {
    printf '%b[错误]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

usage() {
    cat <<'EOF'
Alpine Linux 原生 Shadowsocks 2022 节点管理脚本

用法：
  ss-2022-alpine.sh                     打开交互式管理菜单
  ss-2022-alpine.sh create [选项]       安装 ssserver 并创建节点
  ss-2022-alpine.sh install [版本]      只安装/更新 ssserver
  ss-2022-alpine.sh update [版本]       更新 ssserver，并重启运行中的节点
  ss-2022-alpine.sh list                列出节点
  ss-2022-alpine.sh show <名称>         显示节点配置和分享链接
  ss-2022-alpine.sh start <名称>        启动节点
  ss-2022-alpine.sh stop <名称>         停止节点
  ss-2022-alpine.sh restart <名称>      重启节点
  ss-2022-alpine.sh status <名称>       查看节点状态
  ss-2022-alpine.sh delete <名称> [--yes]
                                        删除节点（保留 ssserver）
  ss-2022-alpine.sh version             显示脚本和 ssserver 版本

create 选项：
  --name NAME           节点名称；大写会自动转小写
  --port PORT           TCP/UDP 端口；默认随机选择 10000-65535
  --method METHOD       SS 2022 加密方式；默认 2022-blake3-aes-128-gcm
  --password PASSWORD   Base64 密钥；省略时按加密方式安全生成
  --host HOST           分享链接中的公网 IP 或域名；省略时自动探测
  --listen ADDRESS      服务监听地址；默认自动选择 IPv4 或 IPv4/IPv6 双栈
  --version VERSION     安装指定 ssserver 版本；默认 latest
  --force               覆盖同名节点
  --no-start            写入配置但不启用/启动 OpenRC 服务

支持的加密方式：
  2022-blake3-aes-128-gcm
  2022-blake3-aes-256-gcm
  2022-blake3-chacha20-poly1305

示例：
  ./ss-2022-alpine.sh
  ./ss-2022-alpine.sh create --name hk --port 443
  SS_PASSWORD='Base64密钥' ./ss-2022-alpine.sh create --name hk --port 443
EOF
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 身份运行。"
}

require_alpine() {
    [ -r /etc/os-release ] || die "无法读取 /etc/os-release；本脚本只支持 Alpine Linux。"
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "alpine" ] || die "检测到 ${ID:-未知系统}；本脚本只支持 Alpine Linux。"
    command -v apk >/dev/null 2>&1 || die "未找到 apk。"
}

validate_node_name() {
    value=$1
    case "$value" in
        ''|*[!a-z0-9_-]*|-*|_*|*[-_])
            return 1
            ;;
    esac
    [ "${#value}" -le 32 ]
}

normalize_node_name() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

validate_port() {
    value=$1
    case "$value" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$value" -ge 1 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null
}

validate_method() {
    case "$1" in
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

key_length_for_method() {
    case "$1" in
        2022-blake3-aes-128-gcm) printf '16\n' ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) printf '32\n' ;;
        *) return 1 ;;
    esac
}

generate_password() {
    length=$(key_length_for_method "$1")
    openssl rand -base64 "$length" | tr -d '\r\n'
}

validate_password() {
    method=$1
    password=$2
    expected=$(key_length_for_method "$method")
    case "$password" in
        ''|*[!A-Za-z0-9+/=]*) return 1 ;;
    esac
    canonical=$(printf '%s' "$password" | base64 -d 2>/dev/null | base64 | tr -d '\r\n')
    [ "$canonical" = "$password" ] || return 1
    actual=$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
    [ "$actual" = "$expected" ]
}

validate_host() {
    value=$1
    case "$value" in
        ''|*[!A-Za-z0-9:._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

normalize_host() {
    value=$1
    case "$value" in
        \[*\]) value=${value#\[}; value=${value%\]} ;;
    esac
    printf '%s\n' "$value"
}

detect_target() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64-unknown-linux-musl\n' ;;
        aarch64|arm64) printf 'aarch64-unknown-linux-musl\n' ;;
        armv7l|armv7) printf 'armv7-unknown-linux-musleabihf\n' ;;
        armv6l|armhf) printf 'arm-unknown-linux-musleabihf\n' ;;
        i386|i486|i586|i686) printf 'i686-unknown-linux-musl\n' ;;
        *) die "官方预编译包不支持当前架构：$(uname -m)" ;;
    esac
}

default_listen_address() {
    if [ -r /proc/sys/net/ipv6/bindv6only ] && \
       [ "$(cat /proc/sys/net/ipv6/bindv6only)" = "0" ] && \
       ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 '; then
        printf '::\n'
    else
        printf '0.0.0.0\n'
    fi
}

ensure_dependencies() {
    packages=""

    command -v curl >/dev/null 2>&1 || packages="$packages curl"
    command -v jq >/dev/null 2>&1 || packages="$packages jq"
    command -v xz >/dev/null 2>&1 || packages="$packages xz"
    command -v openssl >/dev/null 2>&1 || packages="$packages openssl"
    command -v ss >/dev/null 2>&1 || packages="$packages iproute2"
    command -v rc-service >/dev/null 2>&1 || packages="$packages openrc"
    [ -s /etc/ssl/certs/ca-certificates.crt ] || packages="$packages ca-certificates"

    if [ -n "$packages" ]; then
        info "安装 Alpine 依赖：$packages"
        # $packages is a fixed internal package list, intentionally split here.
        # shellcheck disable=SC2086
        apk add --no-cache $packages
    fi

    command -v curl >/dev/null 2>&1 || die "curl 安装失败。"
    command -v jq >/dev/null 2>&1 || die "jq 安装失败。"
    command -v rc-service >/dev/null 2>&1 || die "OpenRC 安装失败。"
    [ -x /sbin/openrc-run ] || die "未找到 /sbin/openrc-run。"
}

ensure_time_sync() {
    for service in chronyd openntpd ntpd; do
        if rc-service "$service" status >/dev/null 2>&1; then
            info "时间同步服务已运行：$service"
            return 0
        fi
    done

    if ! command -v chronyd >/dev/null 2>&1; then
        info "安装 chrony；SS 2022 要求客户端与服务端时间准确。"
        apk add --no-cache chrony
    fi

    rc-update add chronyd default >/dev/null 2>&1 || true
    if rc-service chronyd start >/dev/null 2>&1; then
        info "chronyd 已启动。"
    else
        warn "chronyd 未能自动启动。请在使用节点前确认系统时间误差小于 30 秒。"
    fi
}

make_temp_dir() {
    if [ -z "$TEMP_DIR" ]; then
        TEMP_DIR=$(mktemp -d /tmp/ss-2022-alpine.XXXXXX) || die "无法创建临时目录。"
    fi
}

fetch_release() {
    requested=${1:-latest}
    make_temp_dir
    release_file="$TEMP_DIR/release.json"

    case "$requested" in
        ''|latest)
            endpoint="$GITHUB_API/releases/latest"
            ;;
        *)
            requested=${requested#v}
            case "$requested" in
                ''|*[!0-9A-Za-z._-]*) die "无效版本号：$requested" ;;
            esac
            endpoint="$GITHUB_API/releases/tags/v${requested}"
            ;;
    esac

    info "读取 Shadowsocks Rust 发布信息……"
    curl -fL --retry 3 --connect-timeout 10 \
        -H 'Accept: application/vnd.github+json' \
        -H "User-Agent: ${PROGRAM_NAME}/${SCRIPT_VERSION}" \
        -o "$release_file" "$endpoint" || die "无法读取 GitHub 发布信息。"

    RELEASE_TAG=$(jq -er '.tag_name' "$release_file") || die "发布信息中没有有效版本号。"
    RELEASE_VERSION=${RELEASE_TAG#v}
    TARGET=$(detect_target)
    suffix=".${TARGET}.tar.xz"

    ASSET_NAME=$(jq -r --arg suffix "$suffix" \
        '.assets[] | select(.name | endswith($suffix)) | .name' "$release_file" | head -n 1)
    [ -n "$ASSET_NAME" ] || die "版本 ${RELEASE_TAG} 没有适用于 ${TARGET} 的官方预编译包。"

    ASSET_URL=$(jq -r --arg name "$ASSET_NAME" \
        '.assets[] | select(.name == $name) | .browser_download_url' "$release_file" | head -n 1)
    ASSET_DIGEST=$(jq -r --arg name "$ASSET_NAME" \
        '.assets[] | select(.name == $name) | (.digest // "")' "$release_file" | head -n 1)
    [ -n "$ASSET_URL" ] && [ "$ASSET_URL" != "null" ] || die "无法获得预编译包下载地址。"
}

install_binary() {
    requested=${1:-latest}
    ensure_dependencies
    fetch_release "$requested"

    archive="$TEMP_DIR/$ASSET_NAME"
    extract_dir="$TEMP_DIR/extract"
    mkdir -p "$extract_dir" "$INSTALL_DIR"

    info "下载 $ASSET_NAME"
    curl -fL --retry 3 --connect-timeout 10 -o "$archive" "$ASSET_URL" || die "ssserver 下载失败。"

    case "$ASSET_DIGEST" in
        sha256:*)
            expected=${ASSET_DIGEST#sha256:}
            actual=$(sha256sum "$archive" | awk '{print $1}')
            [ "$actual" = "$expected" ] || die "下载文件的 SHA-256 校验失败。"
            info "SHA-256 校验通过。"
            ;;
        *)
            warn "该 GitHub 发布未提供 SHA-256 digest；已通过 HTTPS 下载，但无法做额外摘要校验。"
            ;;
    esac

    tar -xJf "$archive" -C "$extract_dir" || die "无法解压 $ASSET_NAME。"
    candidate=$(find "$extract_dir" -type f -name ssserver | head -n 1)
    [ -n "$candidate" ] || die "预编译包中没有 ssserver。"
    chmod 0755 "$candidate"
    "$candidate" --version >/dev/null 2>&1 || die "下载的 ssserver 无法执行；可能选错了架构。"

    new_binary="${BINARY_PATH}.new.$$"
    mkdir -p "$(dirname "$BINARY_PATH")"
    cp "$candidate" "$new_binary"
    chmod 0755 "$new_binary"
    mv -f "$new_binary" "$BINARY_PATH"
    printf '%s\n' "$RELEASE_VERSION" > "$VERSION_FILE"
    chmod 0644 "$VERSION_FILE"

    info "Shadowsocks Rust ${RELEASE_VERSION} 已安装到 $BINARY_PATH"
}

ensure_binary() {
    version=${1:-latest}
    if [ ! -x "$BINARY_PATH" ]; then
        install_binary "$version"
        return 0
    fi

    case "$version" in
        ''|latest) return 0 ;;
    esac
    requested=${version#v}
    installed=""
    if [ -r "$VERSION_FILE" ]; then
        installed=$(tr -d '\r\n ' < "$VERSION_FILE")
    fi
    if [ "$installed" != "$requested" ]; then
        install_binary "$requested"
    fi
}

service_name() {
    printf 'ss-rust.%s\n' "$1"
}

config_path() {
    printf '%s/%s.json\n' "$CONFIG_DIR" "$1"
}

meta_path() {
    printf '%s/%s.json\n' "$META_DIR" "$1"
}

node_exists() {
    [ -f "$(config_path "$1")" ]
}

port_claimed_by_node() {
    wanted_port=$1
    excluded_name=${2:-}

    for file in "$CONFIG_DIR"/*.json; do
        [ -f "$file" ] || continue
        name=$(basename "$file" .json)
        [ "$name" = "$excluded_name" ] && continue
        configured_port=$(jq -r '.server_port // empty' "$file" 2>/dev/null || true)
        [ "$configured_port" = "$wanted_port" ] && return 0
    done
    return 1
}

port_in_use() {
    wanted_port=$1
    ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${wanted_port}$"
}

random_port() {
    attempts=0
    while [ "$attempts" -lt 100 ]; do
        random_value=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
        candidate=$((10000 + random_value % 55536))
        if ! port_claimed_by_node "$candidate" "" && ! port_in_use "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
        attempts=$((attempts + 1))
    done
    die "尝试 100 次后仍无法找到空闲端口。"
}

prompt_value() {
    prompt=$1
    default=$2
    printf '%s [%s]：' "$prompt" "$default" >&2
    IFS= read -r answer || answer=""
    if [ -n "$answer" ]; then
        printf '%s\n' "$answer"
    else
        printf '%s\n' "$default"
    fi
}

write_node_config() {
    name=$1
    port=$2
    method=$3
    password=$4
    listen=$5
    host=$6

    mkdir -p "$CONFIG_DIR" "$META_DIR" "$LOG_DIR"
    chmod 0700 "$INSTALL_DIR" "$CONFIG_DIR" "$META_DIR"
    chmod 0750 "$LOG_DIR"
    touch "$LOG_DIR/$name.log" "$LOG_DIR/$name.err.log"
    chmod 0640 "$LOG_DIR/$name.log" "$LOG_DIR/$name.err.log"

    config=$(config_path "$name")
    meta=$(meta_path "$name")
    config_tmp=$(mktemp "$CONFIG_DIR/.${name}.config.XXXXXX") || die "无法创建临时配置。"
    meta_tmp=$(mktemp "$META_DIR/.${name}.meta.XXXXXX") || die "无法创建临时元数据。"

    jq -n \
        --arg server "$listen" \
        --argjson port "$port" \
        --arg password "$password" \
        --arg method "$method" \
        '{
            server: $server,
            server_port: $port,
            password: $password,
            method: $method,
            mode: "tcp_and_udp",
            timeout: 300,
            fast_open: false,
            user: "nobody"
        }' > "$config_tmp" || die "生成 ssserver JSON 配置失败。"

    created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    jq -n --arg name "$name" --arg host "$host" --arg created_at "$created_at" \
        '{name: $name, public_host: $host, created_at: $created_at}' > "$meta_tmp" || die "生成节点元数据失败。"

    chmod 0600 "$config_tmp" "$meta_tmp"
    mv -f "$config_tmp" "$config"
    mv -f "$meta_tmp" "$meta"
}

write_openrc_service() {
    name=$1
    service=$(service_name "$name")
    config=$(config_path "$name")
    service_file="$INIT_DIR/$service"
    service_tmp="${service_file}.new.$$"

    mkdir -p "$INIT_DIR"
    cat > "$service_tmp" <<EOF
#!/sbin/openrc-run

name="Shadowsocks Rust node: ${name}"
description="Native Shadowsocks 2022 server (${name})"

command="${BINARY_PATH}"
command_args="-c ${config}"
command_background="yes"
pidfile="/run/${service}.pid"
start_stop_daemon_args="--stdout ${LOG_DIR}/${name}.log --stderr ${LOG_DIR}/${name}.err.log"
retry="TERM/10/KILL/5"

depend() {
    need net
    after firewall
}
EOF
    chmod 0755 "$service_tmp"
    mv -f "$service_tmp" "$service_file"
}

start_and_enable_node() {
    name=$1
    service=$(service_name "$name")

    rc-update add "$service" default >/dev/null || die "无法把 $service 加入 OpenRC default runlevel。"
    if rc-service "$service" status >/dev/null 2>&1; then
        rc-service "$service" restart || die "$service 重启失败；请检查 ${LOG_DIR}/${name}.err.log。"
    else
        rc-service "$service" start || die "$service 启动失败；请检查 ${LOG_DIR}/${name}.err.log。"
    fi

    sleep 1
    rc-service "$service" status >/dev/null 2>&1 || die "$service 启动后立即退出；请检查 ${LOG_DIR}/${name}.err.log。"
    info "OpenRC 服务 $service 已启用并启动。"
}

detect_public_host() {
    for endpoint in \
        https://api64.ipify.org \
        https://ifconfig.co/ip \
        https://icanhazip.com; do
        detected=$(curl -fsSL --connect-timeout 4 --max-time 8 "$endpoint" 2>/dev/null | tr -d '\r\n ' || true)
        case "$detected" in
            ''|*[!0-9A-Fa-f:.]*) ;;
            *) printf '%s\n' "$detected"; return 0 ;;
        esac
    done
    return 1
}

uri_host() {
    value=$1
    case "$value" in
        *:*) printf '[%s]\n' "$value" ;;
        *) printf '%s\n' "$value" ;;
    esac
}

make_share_uri() {
    name=$1
    host=$2
    port=$3
    method=$4
    password=$5

    userinfo=$(printf '%s:%s' "$method" "$password" | base64 | tr '+/' '-_' | tr -d '=\r\n')
    endpoint=$(uri_host "$host")
    printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$endpoint" "$port" "$name"
}

show_node() {
    name=$(normalize_node_name "$1")
    validate_node_name "$name" || die "无效节点名称：$name"
    node_exists "$name" || die "节点不存在：$name"

    config=$(config_path "$name")
    meta=$(meta_path "$name")
    port=$(jq -er '.server_port' "$config") || die "节点配置损坏：$config"
    method=$(jq -er '.method' "$config") || die "节点配置损坏：$config"
    password=$(jq -er '.password' "$config") || die "节点配置损坏：$config"
    listen=$(jq -er '.server' "$config") || die "节点配置损坏：$config"
    host=""
    if [ -f "$meta" ]; then
        host=$(jq -r '.public_host // ""' "$meta" 2>/dev/null || true)
    fi
    if [ -z "$host" ]; then
        host=$(detect_public_host || true)
    fi

    service=$(service_name "$name")
    if rc-service "$service" status >/dev/null 2>&1; then
        state="运行中"
    else
        state="已停止"
    fi

    printf '%b节点：%b%s\n' "$C_CYAN" "$C_RESET" "$name"
    printf '状态：%s\n监听：%s\n端口：%s（TCP + UDP）\n加密：%s\n密码：%s\n' \
        "$state" "$listen" "$port" "$method" "$password"
    if [ -n "$host" ]; then
        printf '公网地址：%s\n分享链接：%s\n' "$host" "$(make_share_uri "$name" "$host" "$port" "$method" "$password")"
    else
        warn "无法自动探测公网地址。节点已创建；请用服务器 IP 替换下面的占位符。"
        printf '分享链接：%s\n' "$(make_share_uri "$name" 'SERVER_IP' "$port" "$method" "$password")"
    fi
    printf '配置：%s\n服务：%s\n日志：%s/%s.err.log\n' "$config" "$service" "$LOG_DIR" "$name"
}

create_node() {
    node_name=""
    port=""
    method="$DEFAULT_METHOD"
    password="${SS_PASSWORD:-}"
    host=""
    listen=""
    requested_version="latest"
    force=0
    no_start=0
    method_set=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name|--port|--method|--password|--host|--listen|--version)
                option=$1
                shift
                [ "$#" -gt 0 ] || die "$option 缺少参数。"
                case "$option" in
                    --name) node_name=$1 ;;
                    --port) port=$1 ;;
                    --method) method=$1; method_set=1 ;;
                    --password) password=$1 ;;
                    --host) host=$1 ;;
                    --listen) listen=$1 ;;
                    --version) requested_version=$1 ;;
                esac
                ;;
            --force) force=1 ;;
            --no-start) no_start=1 ;;
            -h|--help) usage; return 0 ;;
            *) die "未知 create 选项：$1" ;;
        esac
        shift
    done

    ensure_dependencies
    if [ -z "$listen" ]; then
        listen=$(default_listen_address)
        if [ "$listen" = "::" ]; then
            info "检测到全局 IPv6，使用 :: 同时监听 IPv4 和 IPv6。"
        else
            info "使用 0.0.0.0 监听 IPv4。"
        fi
    fi

    if [ -z "$port" ]; then
        suggested_port=$(random_port)
        if [ -t 0 ]; then
            port=$(prompt_value "端口" "$suggested_port")
        else
            port=$suggested_port
        fi
    fi
    validate_port "$port" || die "端口必须是 1-65535 之间的整数。"

    if [ "$method_set" -eq 0 ] && [ -t 0 ]; then
        printf '加密方式：\n  1) 2022-blake3-aes-128-gcm\n  2) 2022-blake3-aes-256-gcm\n  3) 2022-blake3-chacha20-poly1305\n' >&2
        method_input=$(prompt_value "选择" "1")
        case "$method_input" in
            1) method="2022-blake3-aes-128-gcm" ;;
            2) method="2022-blake3-aes-256-gcm" ;;
            3) method="2022-blake3-chacha20-poly1305" ;;
            *) method=$method_input ;;
        esac
    fi
    validate_method "$method" || die "不支持的 SS 2022 加密方式：$method"

    if [ -z "$password" ]; then
        password=$(generate_password "$method")
    fi
    validate_password "$method" "$password" || \
        die "$method 的密码必须是 $(key_length_for_method "$method") 字节密钥的标准 Base64 编码。"

    if [ -z "$node_name" ]; then
        default_name="node-$port"
        if [ -t 0 ]; then
            node_name=$(prompt_value "节点名称" "$default_name")
        else
            node_name=$default_name
        fi
    fi
    original_node_name=$node_name
    node_name=$(normalize_node_name "$node_name")
    if [ "$node_name" != "$original_node_name" ]; then
        info "节点名称已自动转换为小写：$node_name"
    fi
    validate_node_name "$node_name" || \
        die "节点名称必须为 1-32 个小写字母、数字、下划线或连字符，且首尾必须是字母或数字。"

    case "$listen" in
        ''|*[[:space:]]*) die "无效监听地址：$listen" ;;
    esac
    if [ -n "$host" ]; then
        host=$(normalize_host "$host")
        validate_host "$host" || die "无效公网地址或域名：$host"
    fi

    config=$(config_path "$node_name")
    old_port=""
    if [ -f "$config" ]; then
        [ "$force" -eq 1 ] || die "节点 $node_name 已存在；如需覆盖请使用 --force。"
        old_port=$(jq -r '.server_port // ""' "$config" 2>/dev/null || true)
    fi
    port_claimed_by_node "$port" "$node_name" && die "端口 $port 已被另一个节点使用。"
    if [ "$old_port" != "$port" ] && port_in_use "$port"; then
        die "端口 $port 已被系统中的其他进程占用。"
    fi

    ensure_binary "$requested_version"
    ensure_time_sync

    if [ -z "$host" ]; then
        host=$(detect_public_host || true)
    fi

    write_node_config "$node_name" "$port" "$method" "$password" "$listen" "$host"
    write_openrc_service "$node_name"

    if [ "$no_start" -eq 0 ]; then
        start_and_enable_node "$node_name"
    else
        info "已按 --no-start 跳过启用和启动服务。"
    fi

    printf '\n'
    show_node "$node_name"
    printf '\n'
    warn "脚本不会擅自修改防火墙；请在云安全组和本机防火墙中放行 TCP/UDP $port。"
}

list_nodes() {
    found=0
    printf '%-32s %-8s %-28s %s\n' "名称" "端口" "加密方式" "状态"
    printf '%-32s %-8s %-28s %s\n' "--------------------------------" "--------" "----------------------------" "------"
    for file in "$CONFIG_DIR"/*.json; do
        [ -f "$file" ] || continue
        found=1
        name=$(basename "$file" .json)
        port=$(jq -r '.server_port // "?"' "$file")
        method=$(jq -r '.method // "?"' "$file")
        service=$(service_name "$name")
        if rc-service "$service" status >/dev/null 2>&1; then state="运行中"; else state="已停止"; fi
        printf '%-32s %-8s %-28s %s\n' "$name" "$port" "$method" "$state"
    done
    [ "$found" -eq 1 ] || info "尚未创建节点。"
}

control_node() {
    action=$1
    name=$(normalize_node_name "$2")
    validate_node_name "$name" || die "无效节点名称：$name"
    node_exists "$name" || die "节点不存在：$name"
    service=$(service_name "$name")

    case "$action" in
        start)
            rc-update add "$service" default >/dev/null || die "无法启用 $service。"
            rc-service "$service" start
            ;;
        stop) rc-service "$service" stop ;;
        restart) rc-service "$service" restart ;;
        status) rc-service "$service" status ;;
        *) die "内部错误：未知服务操作 $action" ;;
    esac
}

delete_node() {
    [ "$#" -ge 1 ] || die "delete 需要节点名称。"
    name=$(normalize_node_name "$1")
    shift
    assume_yes=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes|-y) assume_yes=1 ;;
            *) die "未知 delete 选项：$1" ;;
        esac
        shift
    done

    validate_node_name "$name" || die "无效节点名称：$name"
    node_exists "$name" || die "节点不存在：$name"

    if [ "$assume_yes" -ne 1 ]; then
        [ -t 0 ] || die "非交互删除必须显式添加 --yes。"
        printf '确定删除节点 %s？[y/N]：' "$name" >&2
        IFS= read -r answer || answer=""
        case "$answer" in y|Y|yes|YES) ;; *) info "已取消。"; return 0 ;; esac
    fi

    service=$(service_name "$name")
    rc-service "$service" stop >/dev/null 2>&1 || true
    rc-update del "$service" default >/dev/null 2>&1 || true
    rm -f -- "$INIT_DIR/$service" "$(config_path "$name")" "$(meta_path "$name")"
    info "节点 $name 已删除；ssserver 二进制和日志仍保留。"
}

update_binary_and_nodes() {
    requested=${1:-latest}
    install_binary "$requested"

    for file in "$CONFIG_DIR"/*.json; do
        [ -f "$file" ] || continue
        name=$(basename "$file" .json)
        service=$(service_name "$name")
        if rc-service "$service" status >/dev/null 2>&1; then
            info "重启 $service"
            rc-service "$service" restart || warn "$service 重启失败。"
        fi
    done
}

show_versions() {
    printf '%s %s\n' "$PROGRAM_NAME" "$SCRIPT_VERSION"
    if [ -x "$BINARY_PATH" ]; then
        "$BINARY_PATH" --version
    else
        printf 'ssserver 未安装\n'
    fi
}

menu_pause() {
    printf '\n按回车键返回主菜单……' >&2
    IFS= read -r menu_answer || true
}

choose_existing_node() {
    list_nodes
    printf '\n请输入节点名称：' >&2
    IFS= read -r selected_node || selected_node=""
    selected_node=$(normalize_node_name "$selected_node")
    if ! validate_node_name "$selected_node" || ! node_exists "$selected_node"; then
        warn "节点不存在：${selected_node:-空}"
        return 1
    fi
    return 0
}

interactive_menu() {
    ensure_dependencies

    while true; do
        if [ -t 1 ] && command -v clear >/dev/null 2>&1; then
            clear
        fi
        printf '%b========================================%b\n' "$C_CYAN" "$C_RESET"
        printf '%b       Shadowsocks 2022 - Alpine%b\n' "$C_CYAN" "$C_RESET"
        printf '%b========================================%b\n' "$C_CYAN" "$C_RESET"
        printf '  1. 创建节点\n'
        printf '  2. 查看节点列表\n'
        printf '  3. 查看节点配置和分享链接\n'
        printf '  4. 启动节点\n'
        printf '  5. 停止节点\n'
        printf '  6. 重启节点\n'
        printf '  7. 删除节点\n'
        printf '  8. 更新 Shadowsocks Rust\n'
        printf '  9. 查看版本\n'
        printf '  0. 退出\n'
        printf '%b========================================%b\n' "$C_CYAN" "$C_RESET"
        printf '请选择 [0-9]：' >&2
        IFS= read -r menu_choice || menu_choice="0"

        case "$menu_choice" in
            1)
                create_node
                menu_pause
                ;;
            2)
                list_nodes
                menu_pause
                ;;
            3)
                if choose_existing_node; then show_node "$selected_node"; fi
                menu_pause
                ;;
            4)
                if choose_existing_node; then control_node start "$selected_node" || warn "节点启动失败。"; fi
                menu_pause
                ;;
            5)
                if choose_existing_node; then control_node stop "$selected_node" || warn "节点停止失败。"; fi
                menu_pause
                ;;
            6)
                if choose_existing_node; then control_node restart "$selected_node" || warn "节点重启失败。"; fi
                menu_pause
                ;;
            7)
                if choose_existing_node; then delete_node "$selected_node"; fi
                menu_pause
                ;;
            8)
                update_binary_and_nodes latest
                menu_pause
                ;;
            9)
                show_versions
                menu_pause
                ;;
            0)
                info "已退出。"
                return 0
                ;;
            *)
                warn "请输入 0-9 之间的数字。"
                menu_pause
                ;;
        esac
    done
}

main() {
    if [ "$#" -eq 0 ]; then
        require_root
        require_alpine
        interactive_menu
        return 0
    fi

    command=$1
    shift

    case "$command" in
        help|-h|--help) usage; return 0 ;;
        version) show_versions; return 0 ;;
    esac
    case "${1:-}" in
        -h|--help) usage; return 0 ;;
    esac

    require_root
    require_alpine

    case "$command" in
        create|add) create_node "$@" ;;
        install)
            [ "$#" -le 1 ] || die "install 最多接受一个版本号。"
            install_binary "${1:-latest}"
            ;;
        update)
            [ "$#" -le 1 ] || die "update 最多接受一个版本号。"
            update_binary_and_nodes "${1:-latest}"
            ;;
        list)
            [ "$#" -eq 0 ] || die "list 不接受参数。"
            ensure_dependencies
            list_nodes
            ;;
        show)
            [ "$#" -eq 1 ] || die "show 需要一个节点名称。"
            ensure_dependencies
            show_node "$1"
            ;;
        start|stop|restart|status)
            [ "$#" -eq 1 ] || die "$command 需要一个节点名称。"
            control_node "$command" "$1"
            ;;
        delete|remove)
            delete_node "$@"
            ;;
        *)
            usage >&2
            die "未知命令：$command"
            ;;
    esac
}

main "$@"
