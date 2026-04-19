#!/bin/bash

# ========================
# Customizable section
# ========================
APP_NAME="${APP_NAME:-nezha-agent}"
DISPLAY_NAME="${DISPLAY_NAME:-$APP_NAME}"
CLI_NAME="${CLI_NAME:-$APP_NAME}"
SERVICE_NAME="${SERVICE_NAME:-$APP_NAME}"
BIN_NAME="${BIN_NAME:-$APP_NAME}"
RUN_USER="${RUN_USER:-root}"
RUN_GROUP="${RUN_GROUP:-root}"

UPSTREAM_REPO="${UPSTREAM_REPO:-wyx2685/v2node}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_RELEASE_ASSET_PREFIX="${UPSTREAM_RELEASE_ASSET_PREFIX:-v2node-linux}"
UPSTREAM_RELEASE_BIN_NAME="${UPSTREAM_RELEASE_BIN_NAME:-v2node}"

INSTALL_DIR="${INSTALL_DIR:-/usr/local/$APP_NAME}"
CONFIG_DIR="${CONFIG_DIR:-/etc/$APP_NAME}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.json}"
CLI_PATH="${CLI_PATH:-/usr/bin/$CLI_NAME}"
SCRIPT_STORE_PATH="${SCRIPT_STORE_PATH:-$INSTALL_DIR/scripts/manage.sh}"
PID_FILE="${PID_FILE:-/run/$SERVICE_NAME.pid}"
KEEP_CONFIG_ON_UNINSTALL="${KEEP_CONFIG_ON_UNINSTALL:-0}"
AUTO_OPEN_PORTS="${AUTO_OPEN_PORTS:-0}"

ENABLE_LEGACY_COMPAT="${ENABLE_LEGACY_COMPAT:-1}"
LEGACY_COMPAT_DIR="${LEGACY_COMPAT_DIR:-/etc/v2node}"
# ========================

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# --- 修复路径获取逻辑 ---
if [[ -n "${BASH_SOURCE[0]}" ]]; then
    self_path="${BASH_SOURCE[0]}"
else
    self_path="$0"
fi
# -----------------------

RELEASE_API_URL="https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest"

VERSION_ARG=""
API_HOST_ARG=""
NODE_ID_ARG=""
API_KEY_ARG=""

[[ $EUID -ne 0 ]] && echo -e "${red}Error:${plain} this script must be run as root.\n" && exit 1

# 操作系统检测逻辑 (保持原样)
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue 2>/dev/null | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue 2>/dev/null | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue 2>/dev/null | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue 2>/dev/null | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version 2>/dev/null | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version 2>/dev/null | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version 2>/dev/null | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version 2>/dev/null | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}Unable to detect the OS version.${plain}\n" && exit 1
fi

arch=$(uname -m)
if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
else
    arch="64"
fi

# 基础函数 (安装依赖、检测状态等)
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-host) API_HOST_ARG="$2"; shift 2 ;;
            --node-id) NODE_ID_ARG="$2"; shift 2 ;;
            --api-key) API_KEY_ARG="$2"; shift 2 ;;
            -h|--help) show_usage; exit 0 ;;
            *) [[ -z "$VERSION_ARG" ]] && VERSION_ARG="$1"; shift ;;
        esac
    done
}

install_base() {
    echo -e "${green}Installing base dependencies...${plain}"
    if [[ x"${release}" == x"centos" ]]; then
        yum install -y wget curl unzip tar socat ca-certificates pv
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates pv
    else
        apt-get update -y && apt-get install -y wget curl unzip tar cron socat ca-certificates pv
    fi
}

service_action() {
    if [[ x"${release}" == x"alpine" ]]; then
        service "$SERVICE_NAME" "$1"
    else
        systemctl "$1" "$SERVICE_NAME"
    fi
}

check_status() {
    if [[ ! -x "${INSTALL_DIR}/${BIN_NAME}" ]]; then return 2; fi
    if [[ x"${release}" == x"alpine" ]]; then
        service "$SERVICE_NAME" status >/dev/null 2>&1 && return 0 || return 1
    else
        systemctl is-active --quiet "$SERVICE_NAME" && return 0 || return 1
    fi
}

resolve_version() {
    local version_param="$1"
    [[ -n "$version_param" ]] && echo "$version_param" && return 0
    local last_version=$(curl -fsSL "$RELEASE_API_URL" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$last_version" ]] && return 1
    echo "$last_version"
}

download_release() {
    local version="$1"
    local zip_path="$2"
    local url="https://github.com/${UPSTREAM_REPO}/releases/download/${version}/${UPSTREAM_RELEASE_ASSET_PREFIX}-${arch}.zip"
    echo -e "${green}Downloading: ${url}${plain}"
    curl -fL --progress-bar "$url" -o "$zip_path"
}

# --- 关键修复：管理脚本包装器 ---
install_wrapper() {
    local source_script="$1"
    mkdir -p "$(dirname "$SCRIPT_STORE_PATH")"
    
    # 检查源脚本是否为空
    if [[ ! -s "$source_script" ]]; then
        echo -e "${red}Error: Source script is empty. Try running with 'bash script.sh' instead of piping.${plain}"
        # 如果是空的，尝试从当前正在运行的进程中恢复（针对某些环境）
        cat "$0" > "$SCRIPT_STORE_PATH"
    else
        cat "$source_script" > "$SCRIPT_STORE_PATH"
    fi
    
    chmod +x "$SCRIPT_STORE_PATH"

    cat > "$CLI_PATH" <<EOF
#!/bin/bash
export APP_NAME='${APP_NAME}'
export DISPLAY_NAME='${DISPLAY_NAME}'
export CLI_NAME='${CLI_NAME}'
export SERVICE_NAME='${SERVICE_NAME}'
export BIN_NAME='${BIN_NAME}'
export RUN_USER='${RUN_USER}'
export RUN_GROUP='${RUN_GROUP}'
export UPSTREAM_REPO='${UPSTREAM_REPO}'
export INSTALL_DIR='${INSTALL_DIR}'
export CONFIG_DIR='${CONFIG_DIR}'
export CONFIG_FILE='${CONFIG_FILE}'
export CLI_PATH='${CLI_PATH}'
export SCRIPT_STORE_PATH='${SCRIPT_STORE_PATH}'
export PID_FILE='${PID_FILE}'
export ENABLE_LEGACY_COMPAT='${ENABLE_LEGACY_COMPAT}'
export LEGACY_COMPAT_DIR='${LEGACY_COMPAT_DIR}'
exec "\$SCRIPT_STORE_PATH" "\$@"
EOF
    chmod +x "$CLI_PATH"
}

write_systemd_service() {
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=${DISPLAY_NAME} Service
After=network.target
[Service]
User=${RUN_USER}
Group=${RUN_GROUP}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/${BIN_NAME} server -c ${CONFIG_FILE}
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

write_openrc_service() {
    cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/sbin/openrc-run
name="${DISPLAY_NAME}"
command="${INSTALL_DIR}/${BIN_NAME}"
command_args="server -c ${CONFIG_FILE}"
command_user="${RUN_USER}:${RUN_GROUP}"
pidfile="${PID_FILE}"
command_background="yes"
depend() { need net; }
EOF
    chmod +x "/etc/init.d/${SERVICE_NAME}"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
}

install_app() {
    local version_param="$1"
    local release_version=$(resolve_version "$version_param") || exit 1
    
    # 在删除前先保存当前脚本内容到内存/临时文件，防止自毁后无法复制
    local temp_self="/tmp/nezha_bak.sh"
    cat "$self_path" > "$temp_self"

    mkdir -p "$INSTALL_DIR"
    local zip_file="${INSTALL_DIR}/pkg.zip"
    
    download_release "$release_version" "$zip_file" || exit 1
    unzip -o "$zip_file" -d "$INSTALL_DIR" >/dev/null
    rm -f "$zip_file"

    cd "$INSTALL_DIR" || exit 1
    [[ "$UPSTREAM_RELEASE_BIN_NAME" != "$BIN_NAME" ]] && mv -f "$UPSTREAM_RELEASE_BIN_NAME" "$BIN_NAME"
    chmod +x "$BIN_NAME"

    mkdir -p "$CONFIG_DIR"
    [[ -f geoip.dat ]] && cp -f geoip.dat "$CONFIG_DIR/"
    [[ -f geosite.dat ]] && cp -f geosite.dat "$CONFIG_DIR/"

    if [[ x"${release}" == x"alpine" ]]; then write_openrc_service; else write_systemd_service; fi
    
    install_wrapper "$temp_self"
    rm -f "$temp_self"

    echo -e "${green}${DISPLAY_NAME} ${release_version} installed successfully.${plain}"
}

# --- 逻辑入口 ---
main() {
    case "$1" in
        install|update) shift; install_base; install_app "$@"; ;;
        status) check_status; 
                case $? in 
                    0) echo -e "Status: ${green}Running${plain}" ;;
                    1) echo -e "Status: ${yellow}Stopped${plain}" ;;
                    2) echo -e "Status: ${red}Not Installed${plain}" ;;
                esac ;;
        start|stop|restart) service_action "$1" ;;
        uninstall) 
            read -p "Are you sure? (y/n) " res
            [[ "$res" == "y" ]] && service_action stop && rm -rf "$INSTALL_DIR" "$CLI_PATH" && echo "Uninstalled." ;;
        *)
            if [[ ! -f "$CLI_PATH" ]]; then
                install_base && install_app "$@"
            else
                echo "Usage: $CLI_NAME {start|stop|restart|status|uninstall}"
            fi
            ;;
    esac
}

main "$@"
