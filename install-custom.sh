#!/bin/bash

# =========================================================
# 深度自定义安装脚本 - 隐藏原始名称
# =========================================================

# --- 你可以在这里修改为你想要的名称 ---
CUSTOM_APP_NAME="nezha-agent"       # 安装目录名和程序文件名
CUSTOM_CLI_NAME="nz"              # 你在命令行输入的管理命令名称
CUSTOM_SERVICE_NAME="nezha-agent"    # 系统服务名称
# -----------------------------------

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# 路径定义
INSTALL_DIR="/usr/local/${CUSTOM_APP_NAME}"
BIN_PATH="${INSTALL_DIR}/${CUSTOM_APP_NAME}"
CONF_DIR="/etc/${CUSTOM_APP_NAME}"
CONF_FILE="${CONF_DIR}/config.json"
CLI_BIN="/usr/bin/${CUSTOM_CLI_NAME}"

cur_dir=$(pwd)
if [[ -n "${BASH_SOURCE[0]}" ]]; then
    self_path="${BASH_SOURCE[0]}"
else
    self_path="$0"
fi

# 基础检查
[[ $EUID -ne 0 ]] && echo -e "${red}Error: root privileges required.${plain}" && exit 1

# 系统检测 (简化版)
if [[ -f /etc/redhat-release ]]; then release="centos"
elif grep -Eqi "alpine" /etc/issue; then release="alpine"
elif grep -Eqi "debian|ubuntu" /proc/version; then release="debian"
else release="linux"; fi

arch=$(uname -m)
case $arch in
    x86_64|amd64) arch="64" ;;
    aarch64|arm64) arch="arm64-v8a" ;;
    *) arch="64" ;;
esac

########################
# 功能函数
########################

parse_args() {
    VERSION_ARG=""
    API_HOST_ARG=""
    NODE_ID_ARG=""
    API_KEY_ARG=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-host) API_HOST_ARG="$2"; shift 2 ;;
            --node-id)  NODE_ID_ARG="$2"; shift 2 ;;
            --api-key)  API_KEY_ARG="$2"; shift 2 ;;
            *) [[ -z "$VERSION_ARG" ]] && VERSION_ARG="$1"; shift ;;
        esac
    done
}

install_base() {
    echo -e "${green}Installing dependencies...${plain}"
    if [[ "$release" == "centos" ]]; then
        yum install -y wget curl unzip tar ca-certificates pv
    elif [[ "$release" == "alpine" ]]; then
        apk add --no-cache wget curl unzip tar ca-certificates pv
    else
        apt-get update -y && apt-get install -y wget curl unzip tar ca-certificates pv
    fi
}

check_status() {
    if [[ x"${release}" == x"alpine" ]]; then
        service "${CUSTOM_SERVICE_NAME}" status 2>/dev/null | grep -q "started" && return 0 || return 1
    else
        systemctl is-active --quiet "${CUSTOM_SERVICE_NAME}" && return 0 || return 1
    fi
}

# 核心安装逻辑
install_core() {
    local version="$1"
    mkdir -p "$INSTALL_DIR" "$CONF_DIR"
    cd "$INSTALL_DIR" || exit

    # 获取版本并下载 (从原始仓库下载，但本地改名)
    if [[ -z "$version" ]]; then
        version=$(curl -Ls "https://api.github.com/repos/wyx2685/v2node/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    
    echo -e "${green}Target version: ${version}${plain}"
    local url="https://github.com/wyx2685/v2node/releases/download/${version}/v2node-linux-${arch}.zip"
    
    curl -sL "$url" | pv -N "Downloading" > tmp.zip
    unzip -o tmp.zip && rm -f tmp.zip

    # --- 关键：重命名二进制文件 ---
    mv -f v2node "${CUSTOM_APP_NAME}"
    chmod +x "${CUSTOM_APP_NAME}"
    
    # 移动资源文件
    [[ -f geoip.dat ]] && mv -f geoip.dat "${CONF_DIR}/"
    [[ -f geosite.dat ]] && mv -f geosite.dat "${CONF_DIR}/"

    # --- 关键：自定义服务文件 ---
    if [[ "$release" == "alpine" ]]; then
        cat <<EOF > "/etc/init.d/${CUSTOM_SERVICE_NAME}"
#!/sbin/openrc-run
name="${CUSTOM_SERVICE_NAME}"
command="${BIN_PATH}"
command_args="server"
command_background="yes"
pidfile="/run/${CUSTOM_SERVICE_NAME}.pid"
depend() { need net; }
EOF
        chmod +x "/etc/init.d/${CUSTOM_SERVICE_NAME}"
        rc-update add "${CUSTOM_SERVICE_NAME}" default
    else
        cat <<EOF > "/etc/systemd/system/${CUSTOM_SERVICE_NAME}.service"
[Unit]
Description=System Monitoring Agent
After=network.target
[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} server
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "${CUSTOM_SERVICE_NAME}"
    fi

    # --- 关键：自克隆为管理工具 ---
    if [[ -f "$self_path" ]]; then
        cat "$self_path" > "$CLI_BIN"
    else
        # 兜底：如果是管道安装，请修改下方 URL 为你自己的 GitHub 脚本地址
        curl -Ls -o "$CLI_BIN" https://raw.githubusercontent.com/TIUCSIB/ip_check/master/install-custom.sh
    fi
    chmod +x "$CLI_BIN"

    # 配置初始化
    if [[ ! -f "$CONF_FILE" ]]; then
        if [[ -n "$API_HOST_ARG" ]]; then
            # 自动生成
            cat > "$CONF_FILE" <<EOF
{
    "Log": { "Level": "warning", "Output": "", "Access": "none" },
    "Nodes": [ { "ApiHost": "${API_HOST_ARG}", "NodeID": ${NODE_ID_ARG}, "ApiKey": "${API_KEY_ARG}", "Timeout": 15 } ]
}
EOF
        else
            # 默认模板
            cat > "$CONF_FILE" <<EOF
{
    "Log": { "Level": "warning" },
    "Nodes": []
}
EOF
        fi
    fi

    # 启动
    if [[ "$release" == "alpine" ]]; then service "${CUSTOM_SERVICE_NAME}" restart; else systemctl restart "${CUSTOM_SERVICE_NAME}"; fi
    
    echo "------------------------------------------"
    echo -e "${green}Installation success!${plain}"
    echo -e "Command: ${yellow}${CUSTOM_CLI_NAME}${plain}"
    echo -e "Service: ${yellow}${CUSTOM_SERVICE_NAME}${plain}"
    echo "------------------------------------------"
}

uninstall() {
    read -rp "Are you sure to uninstall? (y/n): " res
    [[ "$res" != "y" ]] && exit 0
    if [[ "$release" == "alpine" ]]; then
        service "${CUSTOM_SERVICE_NAME}" stop
        rc-update del "${CUSTOM_SERVICE_NAME}" default
        rm -f "/etc/init.d/${CUSTOM_SERVICE_NAME}"
    else
        systemctl disable "${CUSTOM_SERVICE_NAME}"
        systemctl stop "${CUSTOM_SERVICE_NAME}"
        rm -f "/etc/systemd/system/${CUSTOM_SERVICE_NAME}.service"
    fi
    rm -rf "$INSTALL_DIR" "$CONF_DIR" "$CLI_BIN"
    echo -e "${green}Cleanup finished.${plain}"
}

########################
# 主入口
########################

main() {
    local cmd="$1"
    parse_args "$@"

    case "$cmd" in
        install|update) install_base && install_core "$VERSION_ARG" ;;
        uninstall)      uninstall ;;
        start|stop|restart)
            if [[ "$release" == "alpine" ]]; then service "${CUSTOM_SERVICE_NAME}" "$cmd"; else systemctl "$cmd" "${CUSTOM_SERVICE_NAME}"; fi ;;
        status)
            check_status && echo -e "Status: ${green}Running${plain}" || echo -e "Status: ${red}Not Running${plain}" ;;
        log)
            if [[ "$release" == "alpine" ]]; then echo "Check logs in /var/log/"; else journalctl -u "${CUSTOM_SERVICE_NAME}" -e --no-pager -f; fi ;;
        config)
            ${EDITOR:-vi} "$CONF_FILE" ;;
        "")
            if [[ ! -f "$CLI_BIN" ]]; then
                install_base && install_core "$VERSION_ARG"
            else
                echo -e "${green}${CUSTOM_APP_NAME} Control Tool${plain}"
                echo "Usage: ${CUSTOM_CLI_NAME} {start|stop|restart|status|log|config|uninstall}"
            fi ;;
        *)
            echo "Unknown command: $cmd" ;;
    esac
}

main "$@"
