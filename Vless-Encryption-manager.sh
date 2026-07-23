#!/bin/sh

# Xray VLESS Encryption node manager for Debian and Alpine Linux.
# POSIX sh only. Xray-core is downloaded from the official XTLS/Xray-core releases.

set -eu
umask 077

SCRIPT_VERSION="1.0.1"
PROGRAM_NAME="xray-vless-manager"

INSTALL_DIR="${XRAY_MANAGER_DIR:-/etc/xray-vless-manager}"
CONFIG_DIR="${INSTALL_DIR}/nodes"
META_DIR="${INSTALL_DIR}/meta"
VERSION_FILE="${INSTALL_DIR}/xray-version"
BINARY_PATH="${XRAY_BINARY_PATH:-/usr/local/bin/xray}"
SHARE_DIR="${XRAY_SHARE_DIR:-/usr/local/share/xray}"
LOG_DIR="${XRAY_LOG_DIR:-/var/log/xray-vless-manager}"
SYSTEMD_DIR="${XRAY_SYSTEMD_DIR:-/etc/systemd/system}"
OPENRC_DIR="${XRAY_OPENRC_DIR:-/etc/init.d}"
OS_RELEASE_FILE="${XRAY_OS_RELEASE_FILE:-/etc/os-release}"
GITHUB_API="${XRAY_GITHUB_API:-https://api.github.com/repos/XTLS/Xray-core}"
SERVICE_USER="${XRAY_SERVICE_USER:-xray-vless}"

DEFAULT_AUTH="mlkem768"
DEFAULT_APPEARANCE="native"
DEFAULT_RTT="0rtt"

TEMP_DIR=""
OS_FAMILY=""
INIT_SYSTEM=""

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
Xray VLESS Encryption 节点管理脚本（Debian / Alpine）

用法：
  xray-vless-manager.sh                       打开交互式管理菜单
  xray-vless-manager.sh create [选项]         安装 Xray 并创建节点
  xray-vless-manager.sh install [版本]        只安装/更新 Xray
  xray-vless-manager.sh update [版本]         更新 Xray，并重启运行中的节点
  xray-vless-manager.sh list                  列出节点
  xray-vless-manager.sh show <名称>           显示分享链接和客户端 JSON
  xray-vless-manager.sh start <名称>          启动节点
  xray-vless-manager.sh stop <名称>           停止节点
  xray-vless-manager.sh restart <名称>        重启节点
  xray-vless-manager.sh status <名称>         查看节点和监听状态
  xray-vless-manager.sh logs <名称> [行数]    查看节点日志
  xray-vless-manager.sh delete <名称> [--yes] 删除节点（保留 Xray）
  xray-vless-manager.sh version               显示脚本和 Xray 版本

create 选项：
  --name NAME              节点名；大写会自动转为小写
  --port PORT              TCP 端口；默认随机选择 10000-65535
  --host HOST              分享链接中的公网 IP 或域名；默认自动探测
  --listen ADDRESS         监听地址；默认自动选择 0.0.0.0 或双栈 ::
  --auth TYPE              mlkem768（默认，抗量子）或 x25519
  --appearance MODE        native（默认）、xorpub 或 random
  --rtt MODE               0rtt（默认）或 1rtt
  --uuid UUID              指定 UUID；默认由 Xray 随机生成
  --version VERSION        指定 Xray 版本；默认 latest
  --force                  覆盖同名节点
  --no-start               只写配置，不启用和启动服务

示例：
  ./xray-vless-manager.sh
  ./xray-vless-manager.sh create --name hk-1 --port 443 --host 203.0.113.10
  ./xray-vless-manager.sh create --name relay --auth x25519 --appearance xorpub

说明：
  本脚本创建 VLESS Encryption + XTLS Vision + RAW 节点，不配置 TLS/REALITY。
  VLESS Encryption 官方定位是 CDN、中转、non-TLS 等场景，不建议单独用于直连抗封锁。
EOF
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 身份运行。"
}

detect_system() {
    [ -r "$OS_RELEASE_FILE" ] || die "无法读取 $OS_RELEASE_FILE。"
    # shellcheck disable=SC1090
    . "$OS_RELEASE_FILE"

    case "${ID:-}" in
        alpine)
            OS_FAMILY="alpine"
            INIT_SYSTEM="openrc"
            command -v apk >/dev/null 2>&1 || die "检测到 Alpine，但未找到 apk。"
            ;;
        debian|ubuntu)
            OS_FAMILY="debian"
            INIT_SYSTEM="systemd"
            command -v apt-get >/dev/null 2>&1 || die "检测到 ${ID}，但未找到 apt-get。"
            ;;
        *)
            case " ${ID_LIKE:-} " in
                *" debian "*)
                    OS_FAMILY="debian"
                    INIT_SYSTEM="systemd"
                    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。"
                    ;;
                *)
                    die "不支持当前系统：${ID:-未知}。仅支持 Debian/Ubuntu 和 Alpine。"
                    ;;
            esac
            ;;
    esac

    if [ -n "${XRAY_INIT_SYSTEM:-}" ]; then
        case "$XRAY_INIT_SYSTEM" in
            systemd|openrc) INIT_SYSTEM=$XRAY_INIT_SYSTEM ;;
            *) die "XRAY_INIT_SYSTEM 只能是 systemd 或 openrc。" ;;
        esac
    fi
}

ensure_dependencies() {
    missing=0
    for required_command in curl jq unzip ss setcap; do
        command -v "$required_command" >/dev/null 2>&1 || missing=1
    done
    [ -s /etc/ssl/certs/ca-certificates.crt ] || missing=1

    case "$INIT_SYSTEM" in
        systemd) command -v systemctl >/dev/null 2>&1 || missing=1 ;;
        openrc)
            command -v rc-service >/dev/null 2>&1 || missing=1
            command -v rc-update >/dev/null 2>&1 || missing=1
            ;;
    esac

    if [ "$missing" -eq 1 ]; then
        case "$OS_FAMILY" in
            alpine)
                info "安装 Alpine 依赖：curl jq unzip ca-certificates iproute2 libcap openrc"
                apk add --no-cache curl jq unzip ca-certificates iproute2 libcap openrc
                update-ca-certificates >/dev/null 2>&1 || true
                ;;
            debian)
                info "安装 Debian 依赖：curl jq unzip ca-certificates iproute2 libcap2-bin"
                apt-get update
                DEBIAN_FRONTEND=noninteractive apt-get install -y \
                    curl jq unzip ca-certificates iproute2 libcap2-bin
                ;;
        esac
    fi

    for required_command in curl jq unzip ss setcap; do
        command -v "$required_command" >/dev/null 2>&1 ||
            die "依赖安装失败：$required_command"
    done
    case "$INIT_SYSTEM" in
        systemd) command -v systemctl >/dev/null 2>&1 || die "未找到 systemctl。" ;;
        openrc)
            command -v rc-service >/dev/null 2>&1 || die "未找到 rc-service。"
            [ -x /sbin/openrc-run ] || die "未找到 /sbin/openrc-run。"
            ;;
    esac
}

ensure_service_user() {
    if id "$SERVICE_USER" >/dev/null 2>&1; then
        return 0
    fi

    info "创建低权限服务用户：$SERVICE_USER"
    case "$OS_FAMILY" in
        alpine)
            addgroup -S "$SERVICE_USER" >/dev/null 2>&1 || true
            adduser -S -D -H -s /sbin/nologin -G "$SERVICE_USER" "$SERVICE_USER"
            ;;
        debian)
            adduser --system --group --no-create-home --home /nonexistent \
                --shell /usr/sbin/nologin "$SERVICE_USER"
            ;;
    esac
}

ensure_layout() {
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$META_DIR" "$LOG_DIR" "$SHARE_DIR"
    chown root:"$SERVICE_USER" "$INSTALL_DIR" "$CONFIG_DIR"
    chmod 0750 "$INSTALL_DIR" "$CONFIG_DIR"
    chown root:root "$META_DIR"
    chmod 0700 "$META_DIR"
    chown "$SERVICE_USER":"$SERVICE_USER" "$LOG_DIR"
    chmod 0750 "$LOG_DIR"
    chmod 0755 "$SHARE_DIR"
}

make_temp_dir() {
    if [ -z "$TEMP_DIR" ]; then
        TEMP_DIR=$(mktemp -d /tmp/xray-vless-manager.XXXXXX) ||
            die "无法创建临时目录。"
    fi
}

detect_asset_name() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'Xray-linux-64.zip\n' ;;
        aarch64|arm64) printf 'Xray-linux-arm64-v8a.zip\n' ;;
        armv7l|armv7) printf 'Xray-linux-arm32-v7a.zip\n' ;;
        armv6l|armv6) printf 'Xray-linux-arm32-v6.zip\n' ;;
        i386|i486|i586|i686) printf 'Xray-linux-32.zip\n' ;;
        s390x) printf 'Xray-linux-s390x.zip\n' ;;
        *) die "Xray 官方预编译包不支持当前架构：$(uname -m)" ;;
    esac
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

    info "读取 XTLS/Xray-core 官方发布信息……"
    curl -fL --retry 3 --connect-timeout 10 \
        -H 'Accept: application/vnd.github+json' \
        -H "User-Agent: ${PROGRAM_NAME}/${SCRIPT_VERSION}" \
        -o "$release_file" "$endpoint" ||
        die "无法读取 GitHub 发布信息。"

    RELEASE_TAG=$(jq -er '.tag_name' "$release_file") ||
        die "发布信息中没有有效版本号。"
    ASSET_NAME=$(detect_asset_name)
    ASSET_URL=$(jq -r --arg name "$ASSET_NAME" \
        '.assets[] | select(.name == $name) | .browser_download_url' \
        "$release_file" | head -n 1)
    ASSET_DIGEST=$(jq -r --arg name "$ASSET_NAME" \
        '.assets[] | select(.name == $name) | (.digest // "")' \
        "$release_file" | head -n 1)

    [ -n "$ASSET_URL" ] && [ "$ASSET_URL" != "null" ] ||
        die "${RELEASE_TAG} 没有适用于当前架构的官方包：$ASSET_NAME"
}

install_binary() {
    requested=${1:-latest}
    ensure_dependencies
    ensure_service_user
    ensure_layout
    fetch_release "$requested"

    archive="$TEMP_DIR/$ASSET_NAME"
    extract_dir="$TEMP_DIR/extract"
    mkdir -p "$extract_dir"

    info "下载 $ASSET_NAME（$RELEASE_TAG）"
    curl -fL --retry 3 --connect-timeout 10 \
        -o "$archive" "$ASSET_URL" ||
        die "Xray 下载失败。"

    case "$ASSET_DIGEST" in
        sha256:*)
            expected_digest=${ASSET_DIGEST#sha256:}
            actual_digest=$(sha256sum "$archive" | awk '{print $1}')
            [ "$actual_digest" = "$expected_digest" ] ||
                die "下载文件的 SHA-256 校验失败。"
            info "SHA-256 校验通过。"
            ;;
        *)
            warn "该发布的 API 元数据没有 SHA-256 digest；已通过 HTTPS 下载。"
            ;;
    esac

    unzip -q "$archive" -d "$extract_dir" ||
        die "无法解压 $ASSET_NAME。"
    candidate="$extract_dir/xray"
    if [ ! -f "$candidate" ]; then
        candidate=$(find "$extract_dir" -type f -name xray | head -n 1)
    fi
    [ -n "$candidate" ] && [ -f "$candidate" ] ||
        die "官方包中没有 xray 二进制。"

    chmod 0755 "$candidate"
    "$candidate" version >/dev/null 2>&1 ||
        die "下载的 Xray 无法执行，可能选错了架构。"
    "$candidate" vlessenc 2>/dev/null | grep -q '"decryption":' ||
        die "$RELEASE_TAG 不支持 VLESS Encryption；请安装较新的版本。"

    mkdir -p "$(dirname "$BINARY_PATH")"
    new_binary="${BINARY_PATH}.new.$$"
    cp "$candidate" "$new_binary"
    chown root:root "$new_binary"
    chmod 0755 "$new_binary"
    mv -f "$new_binary" "$BINARY_PATH"

    for data_file in geoip.dat geosite.dat; do
        if [ -f "$extract_dir/$data_file" ]; then
            cp "$extract_dir/$data_file" "$SHARE_DIR/$data_file"
            chown root:root "$SHARE_DIR/$data_file"
            chmod 0644 "$SHARE_DIR/$data_file"
        fi
    done

    if ! setcap 'cap_net_bind_service=+ep' "$BINARY_PATH"; then
        warn "无法给 Xray 设置低端口能力；非 root 的 OpenRC 服务可能无法监听 1-1023 端口。"
    fi

    printf '%s\n' "$RELEASE_TAG" > "$VERSION_FILE"
    chown root:root "$VERSION_FILE"
    chmod 0644 "$VERSION_FILE"
    info "Xray $RELEASE_TAG 已安装到 $BINARY_PATH"
}

binary_supports_vless_encryption() {
    [ -x "$BINARY_PATH" ] || return 1
    "$BINARY_PATH" vlessenc 2>/dev/null | grep -q '"decryption":'
}

ensure_binary() {
    requested=${1:-latest}

    if ! binary_supports_vless_encryption; then
        install_binary "$requested"
        return 0
    fi

    case "$requested" in
        ''|latest) return 0 ;;
    esac

    requested_tag="v${requested#v}"
    installed_tag=""
    if [ -r "$VERSION_FILE" ]; then
        installed_tag=$(tr -d '\r\n ' < "$VERSION_FILE")
    fi
    if [ "$installed_tag" != "$requested_tag" ]; then
        install_binary "$requested"
    fi
}

validate_node_name() {
    value=$1
    case "$value" in
        ''|*[!a-z0-9_-]*|-*|_*|*[-_]) return 1 ;;
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

validate_uuid() {
    value=$1
    case "$value" in
        ????????-????-????-????-????????????)
            case "$value" in
                *[!0-9A-Fa-f-]*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        *) return 1 ;;
    esac
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

validate_auth() {
    case "$1" in
        mlkem768|x25519) return 0 ;;
        *) return 1 ;;
    esac
}

validate_appearance() {
    case "$1" in
        native|xorpub|random) return 0 ;;
        *) return 1 ;;
    esac
}

validate_rtt() {
    case "$1" in
        0rtt|1rtt) return 0 ;;
        *) return 1 ;;
    esac
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

service_name() {
    printf 'xray-vless-%s\n' "$1"
}

service_file_path() {
    name=$1
    service=$(service_name "$name")
    case "$INIT_SYSTEM" in
        systemd) printf '%s/%s.service\n' "$SYSTEMD_DIR" "$service" ;;
        openrc) printf '%s/%s\n' "$OPENRC_DIR" "$service" ;;
    esac
}

default_listen_address() {
    if [ -r /proc/sys/net/ipv6/bindv6only ] &&
       [ "$(cat /proc/sys/net/ipv6/bindv6only)" = "0" ] &&
       ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 '; then
        printf '::\n'
    else
        printf '0.0.0.0\n'
    fi
}

port_claimed_by_node() {
    wanted_port=$1
    excluded_name=${2:-}

    for node_file in "$CONFIG_DIR"/*.json; do
        [ -f "$node_file" ] || continue
        configured_name=$(basename "$node_file" .json)
        [ "$configured_name" = "$excluded_name" ] && continue
        configured_port=$(jq -r '.inbounds[0].port // empty' "$node_file" 2>/dev/null || true)
        [ "$configured_port" = "$wanted_port" ] && return 0
    done
    return 1
}

port_in_use() {
    wanted_port=$1
    ss -H -lnt 2>/dev/null |
        awk -v wanted="$wanted_port" '{
            address=$4
            sub(/^.*:/, "", address)
            if (address == wanted) found=1
        } END { exit found ? 0 : 1 }'
}

random_port() {
    attempts=0
    while [ "$attempts" -lt 100 ]; do
        random_value=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
        candidate_port=$((10000 + random_value % 55536))
        if ! port_claimed_by_node "$candidate_port" "" &&
           ! port_in_use "$candidate_port"; then
            printf '%s\n' "$candidate_port"
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

detect_public_host() {
    for endpoint in \
        https://api.ipify.org \
        https://api64.ipify.org \
        https://ifconfig.co/ip \
        https://icanhazip.com; do
        detected_host=$(curl -fsSL --connect-timeout 4 --max-time 8 \
            "$endpoint" 2>/dev/null | tr -d '\r\n ' || true)
        case "$detected_host" in
            ''|*[!0-9A-Fa-f:.]*) ;;
            *) printf '%s\n' "$detected_host"; return 0 ;;
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

urlencode() {
    printf '%s' "$1" | jq -sRr @uri
}

make_share_uri() {
    name=$1
    host=$2
    port=$3
    uuid=$4
    encryption=$5

    endpoint=$(uri_host "$host")
    encryption_query=$(urlencode "$encryption")
    name_fragment=$(urlencode "$name")
    printf 'vless://%s@%s:%s?encryption=%s&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none#%s\n' \
        "$uuid" "$endpoint" "$port" "$encryption_query" "$name_fragment"
}

generate_encryption_pair() {
    auth=$1
    appearance=$2
    rtt=$3

    generator_output=$("$BINARY_PATH" vlessenc 2>/dev/null) ||
        die "Xray 无法生成 VLESS Encryption 密钥。"

    case "$auth" in
        x25519)
            decryption=$(printf '%s\n' "$generator_output" |
                awk -F'"' '
                    /Authentication: X25519/ { active=1; next }
                    /Authentication: ML-KEM/ { active=0 }
                    active && /"decryption":/ { print $4; exit }
                ')
            encryption=$(printf '%s\n' "$generator_output" |
                awk -F'"' '
                    /Authentication: X25519/ { active=1; next }
                    /Authentication: ML-KEM/ { active=0 }
                    active && /"encryption":/ { print $4; exit }
                ')
            ;;
        mlkem768)
            decryption=$(printf '%s\n' "$generator_output" |
                awk -F'"' '
                    /Authentication: ML-KEM-768/ { active=1; next }
                    active && /"decryption":/ { print $4; exit }
                ')
            encryption=$(printf '%s\n' "$generator_output" |
                awk -F'"' '
                    /Authentication: ML-KEM-768/ { active=1; next }
                    active && /"encryption":/ { print $4; exit }
                ')
            ;;
    esac

    [ -n "$decryption" ] && [ -n "$encryption" ] ||
        die "无法解析 xray vlessenc 的输出。"

    if [ "$appearance" != "native" ]; then
        decryption=$(printf '%s\n' "$decryption" |
            sed "s/\\.native\\./.${appearance}./")
        encryption=$(printf '%s\n' "$encryption" |
            sed "s/\\.native\\./.${appearance}./")
    fi
    if [ "$rtt" = "1rtt" ]; then
        decryption=$(printf '%s\n' "$decryption" | sed 's/\.600s\./.0s./')
        encryption=$(printf '%s\n' "$encryption" | sed 's/\.0rtt\./.1rtt./')
    fi

    case "$decryption" in
        mlkem768x25519plus.*) ;;
        *) die "服务端 decryption 格式异常。" ;;
    esac
    case "$encryption" in
        mlkem768x25519plus.*) ;;
        *) die "客户端 encryption 格式异常。" ;;
    esac
}

write_node_files() {
    name=$1
    port=$2
    listen=$3
    host=$4
    uuid=$5
    auth=$6
    appearance=$7
    rtt=$8
    decryption=$9
    shift 9
    encryption=$1

    ensure_layout
    config=$(config_path "$name")
    meta=$(meta_path "$name")
    config_tmp=$(mktemp "$CONFIG_DIR/.${name}.config.XXXXXX") ||
        die "无法创建临时配置。"
    meta_tmp=$(mktemp "$META_DIR/.${name}.meta.XXXXXX") ||
        die "无法创建临时元数据。"

    jq -n \
        --arg name "$name" \
        --arg listen "$listen" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg decryption "$decryption" \
        '{
            log: {
                loglevel: "warning"
            },
            inbounds: [
                {
                    tag: ("vless-" + $name),
                    listen: $listen,
                    port: $port,
                    protocol: "vless",
                    settings: {
                        clients: [
                            {
                                id: $uuid,
                                flow: "xtls-rprx-vision",
                                email: $name
                            }
                        ],
                        decryption: $decryption
                    },
                    streamSettings: {
                        network: "raw",
                        security: "none"
                    },
                    sniffing: {
                        enabled: true,
                        destOverride: ["http", "tls", "quic"],
                        routeOnly: true
                    }
                }
            ],
            outbounds: [
                {
                    tag: "direct",
                    protocol: "freedom"
                },
                {
                    tag: "blocked",
                    protocol: "blackhole"
                }
            ]
        }' > "$config_tmp" ||
        die "生成 Xray JSON 配置失败。"

    created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    jq -n \
        --arg name "$name" \
        --arg host "$host" \
        --arg uuid "$uuid" \
        --arg auth "$auth" \
        --arg appearance "$appearance" \
        --arg rtt "$rtt" \
        --arg encryption "$encryption" \
        --arg created_at "$created_at" \
        '{
            name: $name,
            public_host: $host,
            uuid: $uuid,
            authentication: $auth,
            appearance: $appearance,
            rtt: $rtt,
            encryption: $encryption,
            created_at: $created_at
        }' > "$meta_tmp" ||
        die "生成节点元数据失败。"

    if ! validation_output=$("$BINARY_PATH" run -test -format json -c "$config_tmp" 2>&1); then
        rm -f -- "$config_tmp" "$meta_tmp"
        die "Xray 拒绝生成的配置：$validation_output"
    fi

    chown root:"$SERVICE_USER" "$config_tmp"
    chmod 0640 "$config_tmp"
    chown root:root "$meta_tmp"
    chmod 0600 "$meta_tmp"
    mv -f "$config_tmp" "$config"
    mv -f "$meta_tmp" "$meta"
}

write_service_file() {
    name=$1
    service=$(service_name "$name")
    config=$(config_path "$name")
    service_file=$(service_file_path "$name")
    service_tmp="${service_file}.new.$$"
    mkdir -p "$(dirname "$service_file")"

    case "$INIT_SYSTEM" in
        systemd)
            cat > "$service_tmp" <<EOF
[Unit]
Description=Xray VLESS Encryption node: ${name}
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${BINARY_PATH} run -c ${config}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
            chmod 0644 "$service_tmp"
            mv -f "$service_tmp" "$service_file"
            systemctl daemon-reload
            ;;
        openrc)
            stdout_log="$LOG_DIR/$name.log"
            stderr_log="$LOG_DIR/$name.err.log"
            touch "$stdout_log" "$stderr_log"
            chown "$SERVICE_USER":"$SERVICE_USER" "$stdout_log" "$stderr_log"
            chmod 0640 "$stdout_log" "$stderr_log"
            cat > "$service_tmp" <<EOF
#!/sbin/openrc-run

name="Xray VLESS Encryption node: ${name}"
description="Xray VLESS Encryption server (${name})"

command="${BINARY_PATH}"
command_args="run -c ${config}"
command_user="${SERVICE_USER}:${SERVICE_USER}"
command_background="yes"
pidfile="/run/${service}.pid"
start_stop_daemon_args="--stdout ${stdout_log} --stderr ${stderr_log}"
retry="TERM/10/KILL/5"

depend() {
    need net
    after firewall
}
EOF
            chmod 0755 "$service_tmp"
            mv -f "$service_tmp" "$service_file"
            ;;
    esac
}

service_is_active() {
    name=$1
    service=$(service_name "$name")
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet "${service}.service" ;;
        openrc) rc-service "$service" status >/dev/null 2>&1 ;;
    esac
}

enable_and_start_node() {
    name=$1
    service=$(service_name "$name")

    case "$INIT_SYSTEM" in
        systemd)
            if service_is_active "$name"; then
                systemctl restart "${service}.service" ||
                    die "$service 重启失败。"
            else
                systemctl enable --now "${service}.service" ||
                    die "$service 启用或启动失败。"
            fi
            ;;
        openrc)
            rc-update add "$service" default >/dev/null ||
                die "无法把 $service 加入 OpenRC default runlevel。"
            if service_is_active "$name"; then
                rc-service "$service" restart ||
                    die "$service 重启失败。"
            else
                rc-service "$service" start ||
                    die "$service 启动失败。"
            fi
            ;;
    esac

    sleep 1
    if ! service_is_active "$name"; then
        warn "$service 启动后立即退出。"
        show_logs "$name" 30 || true
        die "请根据上面的日志排查。"
    fi
    info "$service 已设为开机启动并正在运行。"
}

show_node() {
    name=$(normalize_node_name "$1")
    validate_node_name "$name" || die "无效节点名称：$name"
    node_exists "$name" || die "节点不存在：$name"

    config=$(config_path "$name")
    meta=$(meta_path "$name")
    [ -f "$meta" ] || die "节点元数据不存在：$meta"

    port=$(jq -er '.inbounds[0].port' "$config") ||
        die "节点配置损坏：$config"
    listen=$(jq -er '.inbounds[0].listen' "$config") ||
        die "节点配置损坏：$config"
    uuid=$(jq -er '.uuid' "$meta") || die "节点元数据损坏：$meta"
    encryption=$(jq -er '.encryption' "$meta") ||
        die "节点元数据损坏：$meta"
    auth=$(jq -r '.authentication // "?"' "$meta")
    appearance=$(jq -r '.appearance // "?"' "$meta")
    rtt=$(jq -r '.rtt // "?"' "$meta")
    host=$(jq -r '.public_host // ""' "$meta")

    if [ -z "$host" ]; then
        host=$(detect_public_host || true)
    fi
    if service_is_active "$name"; then
        state="运行中"
    else
        state="已停止"
    fi

    printf '%b节点：%b%s\n' "$C_CYAN" "$C_RESET" "$name"
    printf '状态：%s\n监听：%s:%s（VLESS 的 UDP 通过 XUDP 隧道传输）\n' \
        "$state" "$listen" "$port"
    printf '认证：%s\n外观：%s\n模式：%s\nUUID：%s\n' \
        "$auth" "$appearance" "$rtt" "$uuid"
    printf '客户端 encryption：%s\n' "$encryption"

    if [ -z "$host" ]; then
        warn "无法自动探测公网地址；以下配置使用 SERVER_IP 占位符。"
        host="SERVER_IP"
    fi
    printf '公网地址：%s\n' "$host"
    printf '分享链接：%s\n' \
        "$(make_share_uri "$name" "$host" "$port" "$uuid" "$encryption")"
    printf '\n客户端 Xray JSON（把本地入站按你的客户端需要合并进去）：\n'
    jq -n \
        --arg host "$host" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg encryption "$encryption" \
        '{
            outbounds: [
                {
                    tag: "proxy",
                    protocol: "vless",
                    settings: {
                        vnext: [
                            {
                                address: $host,
                                port: $port,
                                users: [
                                    {
                                        id: $uuid,
                                        encryption: $encryption,
                                        flow: "xtls-rprx-vision"
                                    }
                                ]
                            }
                        ]
                    },
                    streamSettings: {
                        network: "raw",
                        security: "none"
                    }
                }
            ]
        }'
    printf '服务端配置：%s\n服务：%s\n' \
        "$config" "$(service_name "$name")"
}

list_nodes() {
    found=0
    printf '%-28s %-8s %-11s %-8s %s\n' \
        "名称" "端口" "认证" "外观" "状态"
    printf '%-28s %-8s %-11s %-8s %s\n' \
        "----------------------------" "--------" "-----------" "--------" "------"
    for node_file in "$CONFIG_DIR"/*.json; do
        [ -f "$node_file" ] || continue
        found=1
        name=$(basename "$node_file" .json)
        port=$(jq -r '.inbounds[0].port // "?"' "$node_file")
        meta=$(meta_path "$name")
        auth=$(jq -r '.authentication // "?"' "$meta" 2>/dev/null || true)
        appearance=$(jq -r '.appearance // "?"' "$meta" 2>/dev/null || true)
        if service_is_active "$name"; then state="运行中"; else state="已停止"; fi
        printf '%-28s %-8s %-11s %-8s %s\n' \
            "$name" "$port" "$auth" "$appearance" "$state"
    done
    [ "$found" -eq 1 ] || info "尚未创建节点。"
}

show_status() {
    name=$(normalize_node_name "$1")
    validate_node_name "$name" || die "无效节点名称：$name"
    node_exists "$name" || die "节点不存在：$name"
    service=$(service_name "$name")
    port=$(jq -er '.inbounds[0].port' "$(config_path "$name")")

    case "$INIT_SYSTEM" in
        systemd) systemctl status "${service}.service" --no-pager || true ;;
        openrc) rc-service "$service" status || true ;;
    esac

    if service_is_active "$name"; then
        printf '服务状态：运行中\n'
    else
        printf '服务状态：已停止\n'
    fi
    if port_in_use "$port"; then
        printf 'TCP 端口：%s 正在监听\n' "$port"
        ss -H -lntp 2>/dev/null |
            awk -v wanted="$port" '{
                address=$4
                sub(/^.*:/, "", address)
                if (address == wanted) print
            }' || true
    else
        printf 'TCP 端口：%s 未监听\n' "$port"
    fi
}

show_logs() {
    name=$(normalize_node_name "$1")
    lines=${2:-100}
    validate_node_name "$name" || die "无效节点名称：$name"
    node_exists "$name" || die "节点不存在：$name"
    case "$lines" in
        ''|*[!0-9]*) die "日志行数必须是正整数。" ;;
    esac
    [ "$lines" -ge 1 ] && [ "$lines" -le 10000 ] ||
        die "日志行数必须在 1-10000 之间。"

    service=$(service_name "$name")
    case "$INIT_SYSTEM" in
        systemd)
            journalctl -u "${service}.service" -n "$lines" --no-pager
            ;;
        openrc)
            printf '%s\n' "----- stdout -----"
            tail -n "$lines" "$LOG_DIR/$name.log" 2>/dev/null || true
            printf '%s\n' "----- stderr -----"
            tail -n "$lines" "$LOG_DIR/$name.err.log" 2>/dev/null || true
            ;;
    esac
}

control_node() {
    action=$1
    name=$(normalize_node_name "$2")
    validate_node_name "$name" || die "无效节点名称：$name"
    node_exists "$name" || die "节点不存在：$name"
    service=$(service_name "$name")

    case "$INIT_SYSTEM:$action" in
        systemd:start) systemctl enable --now "${service}.service" ;;
        systemd:stop) systemctl stop "${service}.service" ;;
        systemd:restart) systemctl restart "${service}.service" ;;
        openrc:start)
            rc-update add "$service" default >/dev/null
            rc-service "$service" start
            ;;
        openrc:stop) rc-service "$service" stop ;;
        openrc:restart) rc-service "$service" restart ;;
        *) die "内部错误：未知服务操作 $action" ;;
    esac
}

create_node() {
    node_name=""
    port=""
    host=""
    listen=""
    auth="$DEFAULT_AUTH"
    appearance="$DEFAULT_APPEARANCE"
    rtt="$DEFAULT_RTT"
    uuid=""
    requested_version="latest"
    force=0
    no_start=0
    auth_set=0
    appearance_set=0
    rtt_set=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name|--port|--host|--listen|--auth|--appearance|--rtt|--uuid|--version)
                option=$1
                shift
                [ "$#" -gt 0 ] || die "$option 缺少参数。"
                case "$option" in
                    --name) node_name=$1 ;;
                    --port) port=$1 ;;
                    --host) host=$1 ;;
                    --listen) listen=$1 ;;
                    --auth) auth=$1; auth_set=1 ;;
                    --appearance) appearance=$1; appearance_set=1 ;;
                    --rtt) rtt=$1; rtt_set=1 ;;
                    --uuid) uuid=$1 ;;
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
    ensure_service_user
    ensure_layout

    if [ -z "$listen" ]; then
        listen=$(default_listen_address)
        if [ "$listen" = "::" ]; then
            info "检测到全局 IPv6 且内核允许双栈，使用 :: 监听 IPv4/IPv6。"
        else
            info "使用 0.0.0.0 监听 IPv4；如需 IPv6，请显式传入 --listen ::。"
        fi
    fi
    case "$listen" in
        ''|*[[:space:]]*) die "无效监听地址：$listen" ;;
    esac

    if [ -z "$port" ]; then
        suggested_port=$(random_port)
        if [ -t 0 ]; then
            port=$(prompt_value "端口" "$suggested_port")
        else
            port=$suggested_port
        fi
    fi
    validate_port "$port" || die "端口必须是 1-65535 之间的整数。"

    if [ -z "$node_name" ]; then
        default_name="node-$port"
        if [ -t 0 ]; then
            node_name=$(prompt_value "节点名称" "$default_name")
        else
            node_name=$default_name
        fi
    fi
    original_name=$node_name
    node_name=$(normalize_node_name "$node_name")
    if [ "$original_name" != "$node_name" ]; then
        info "节点名称已自动转换为小写：$node_name"
    fi
    validate_node_name "$node_name" ||
        die "节点名须为 1-32 个小写字母、数字、下划线或连字符，且首尾为字母或数字。"

    if [ "$auth_set" -eq 0 ] && [ -t 0 ]; then
        printf '认证方式：\n  1) ML-KEM-768（默认，抗量子，链接较长）\n  2) X25519（链接较短）\n' >&2
        auth_input=$(prompt_value "选择" "1")
        case "$auth_input" in
            1) auth="mlkem768" ;;
            2) auth="x25519" ;;
            *) auth=$auth_input ;;
        esac
    fi
    validate_auth "$auth" || die "--auth 只能是 mlkem768 或 x25519。"

    if [ "$appearance_set" -eq 0 ] && [ -t 0 ]; then
        printf '流量外观：\n  1) native（默认，性能最好）\n  2) xorpub（隐藏公钥特征）\n  3) random（全随机外观）\n' >&2
        appearance_input=$(prompt_value "选择" "1")
        case "$appearance_input" in
            1) appearance="native" ;;
            2) appearance="xorpub" ;;
            3) appearance="random" ;;
            *) appearance=$appearance_input ;;
        esac
    fi
    validate_appearance "$appearance" ||
        die "--appearance 只能是 native、xorpub 或 random。"

    if [ "$rtt_set" -eq 0 ] && [ -t 0 ]; then
        printf '连接模式：\n  1) 0-RTT（默认，服务端 ticket 复用 300-600 秒）\n  2) 仅 1-RTT\n' >&2
        rtt_input=$(prompt_value "选择" "1")
        case "$rtt_input" in
            1) rtt="0rtt" ;;
            2) rtt="1rtt" ;;
            *) rtt=$rtt_input ;;
        esac
    fi
    validate_rtt "$rtt" || die "--rtt 只能是 0rtt 或 1rtt。"

    if [ -n "$host" ]; then
        host=$(normalize_host "$host")
        validate_host "$host" || die "无效公网地址或域名：$host"
    fi

    config=$(config_path "$node_name")
    old_port=""
    if [ -f "$config" ]; then
        [ "$force" -eq 1 ] ||
            die "节点 $node_name 已存在；覆盖请使用 --force。"
        old_port=$(jq -r '.inbounds[0].port // ""' "$config" 2>/dev/null || true)
    fi
    port_claimed_by_node "$port" "$node_name" &&
        die "端口 $port 已被另一个节点使用。"
    if [ "$old_port" != "$port" ] && port_in_use "$port"; then
        die "TCP 端口 $port 已被系统中的其他进程占用。"
    fi

    ensure_binary "$requested_version"

    if [ -z "$uuid" ]; then
        uuid=$("$BINARY_PATH" uuid 2>/dev/null | tr -d '\r\n ')
    fi
    validate_uuid "$uuid" || die "无效 UUID：$uuid"

    generate_encryption_pair "$auth" "$appearance" "$rtt"
    if [ -z "$host" ]; then
        host=$(detect_public_host || true)
    fi

    write_node_files "$node_name" "$port" "$listen" "$host" "$uuid" \
        "$auth" "$appearance" "$rtt" "$decryption" "$encryption"
    write_service_file "$node_name"

    if [ "$no_start" -eq 0 ]; then
        enable_and_start_node "$node_name"
    else
        info "已按 --no-start 跳过启用和启动服务。"
    fi

    printf '\n'
    show_node "$node_name"
    printf '\n'
    warn "脚本不会修改云安全组或防火墙；请放行 TCP $port。"
    warn "VLESS Encryption 不等同于 REALITY；官方不建议把它单独用于直连抗封锁。"
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
        case "$answer" in
            y|Y|yes|YES) ;;
            *) info "已取消。"; return 0 ;;
        esac
    fi

    service=$(service_name "$name")
    service_file=$(service_file_path "$name")
    case "$INIT_SYSTEM" in
        systemd)
            systemctl disable --now "${service}.service" >/dev/null 2>&1 || true
            rm -f -- "$service_file"
            systemctl daemon-reload
            ;;
        openrc)
            rc-service "$service" stop >/dev/null 2>&1 || true
            rc-update del "$service" default >/dev/null 2>&1 || true
            rm -f -- "$service_file"
            ;;
    esac
    rm -f -- "$(config_path "$name")" "$(meta_path "$name")"
    info "节点 $name 已删除；Xray 二进制和历史日志仍保留。"
}

update_binary_and_nodes() {
    requested=${1:-latest}
    install_binary "$requested"

    for node_file in "$CONFIG_DIR"/*.json; do
        [ -f "$node_file" ] || continue
        name=$(basename "$node_file" .json)
        if service_is_active "$name"; then
            info "重启 $(service_name "$name")"
            control_node restart "$name" ||
                warn "$(service_name "$name") 重启失败。"
        fi
    done
}

show_versions() {
    printf '%s %s\n' "$PROGRAM_NAME" "$SCRIPT_VERSION"
    if [ -x "$BINARY_PATH" ]; then
        "$BINARY_PATH" version
    else
        printf 'Xray 未安装\n'
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
    ensure_service_user
    ensure_layout

    while true; do
        if [ -t 1 ] && command -v clear >/dev/null 2>&1; then
            clear
        fi
        printf '%b================================================%b\n' "$C_CYAN" "$C_RESET"
        printf '%b        Xray VLESS Encryption Manager%b\n' "$C_CYAN" "$C_RESET"
        printf '%b        Debian / Alpine · systemd / OpenRC%b\n' "$C_CYAN" "$C_RESET"
        printf '%b================================================%b\n' "$C_CYAN" "$C_RESET"
        printf '  1. 创建节点\n'
        printf '  2. 查看节点列表\n'
        printf '  3. 查看节点配置和分享链接\n'
        printf '  4. 启动节点\n'
        printf '  5. 停止节点\n'
        printf '  6. 重启节点\n'
        printf '  7. 查看节点状态\n'
        printf '  8. 查看节点日志\n'
        printf '  9. 删除节点\n'
        printf ' 10. 更新 Xray\n'
        printf ' 11. 查看版本\n'
        printf '  0. 退出\n'
        printf '%b================================================%b\n' "$C_CYAN" "$C_RESET"
        printf '请选择 [0-11]：' >&2
        IFS= read -r menu_choice || menu_choice="0"

        case "$menu_choice" in
            1) create_node; menu_pause ;;
            2) list_nodes; menu_pause ;;
            3)
                if choose_existing_node; then show_node "$selected_node"; fi
                menu_pause
                ;;
            4)
                if choose_existing_node; then
                    control_node start "$selected_node" || warn "节点启动失败。"
                fi
                menu_pause
                ;;
            5)
                if choose_existing_node; then
                    control_node stop "$selected_node" || warn "节点停止失败。"
                fi
                menu_pause
                ;;
            6)
                if choose_existing_node; then
                    control_node restart "$selected_node" || warn "节点重启失败。"
                fi
                menu_pause
                ;;
            7)
                if choose_existing_node; then show_status "$selected_node"; fi
                menu_pause
                ;;
            8)
                if choose_existing_node; then show_logs "$selected_node" 100; fi
                menu_pause
                ;;
            9)
                if choose_existing_node; then delete_node "$selected_node"; fi
                menu_pause
                ;;
            10) update_binary_and_nodes latest; menu_pause ;;
            11) show_versions; menu_pause ;;
            0) info "已退出。"; return 0 ;;
            *) warn "请输入 0-11 之间的数字。"; menu_pause ;;
        esac
    done
}

main() {
    if [ "$#" -eq 0 ]; then
        require_root
        detect_system
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
    detect_system

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
            ensure_service_user
            ensure_layout
            list_nodes
            ;;
        show)
            [ "$#" -eq 1 ] || die "show 需要一个节点名称。"
            ensure_dependencies
            show_node "$1"
            ;;
        start|stop|restart)
            [ "$#" -eq 1 ] || die "$command 需要一个节点名称。"
            control_node "$command" "$1"
            ;;
        status)
            [ "$#" -eq 1 ] || die "status 需要一个节点名称。"
            ensure_dependencies
            show_status "$1"
            ;;
        logs)
            [ "$#" -ge 1 ] && [ "$#" -le 2 ] ||
                die "logs 需要节点名称，可选日志行数。"
            show_logs "$1" "${2:-100}"
            ;;
        delete|remove) delete_node "$@" ;;
        *)
            usage >&2
            die "未知命令：$command"
            ;;
    esac
}

main "$@"
