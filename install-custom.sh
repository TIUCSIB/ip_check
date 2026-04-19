#!/bin/bash

# =========================================================
# 深度自定义安装脚本 - 彻底隐藏原始痕迹
# =========================================================

# --- 【自定义区域】在此修改你想要的伪装名称 ---
CUSTOM_APP_NAME="nezhe-agent"       # 二进制文件名和安装目录名
CUSTOM_CLI_NAME="nz"              # 你在命令行输入的命令 (例如: ctl status)
CUSTOM_SERVICE_NAME="nezhe-agent"    # 系统服务名 (systemctl start agent-svc)
# ----------------------------------------------

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# 路径变量
INSTALL_DIR="/usr/local/${CUSTOM_APP_NAME}"
BIN_PATH="${INSTALL_DIR}/${CUSTOM_APP_NAME}"
CONF_DIR="/etc/${CUSTOM_APP_NAME}"
CONF_FILE="${CONF_DIR}/config.json"
CLI_BIN="/usr/bin/${CUSTOM_CLI_NAME}"

# 环境准备
if [[ -n "${BASH_SOURCE[0]}" ]]; then
    self_path="${BASH_SOURCE[0]}"
else
    self_path="$0"
fi

[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用 root 用户运行！\n" && exit 1

# 系统检测
if [[ -f /etc/redhat-release ]]; then release="centos"
elif grep -Eqi "alpine" /etc/issue; then release="alpine"
elif grep -Eqi "debian|ubuntu" /proc/version; then release="debian"
elif grep -Eqi "arch" /proc/version; then release="arch"
else release="linux"; fi

# 架构检测
arch=$(uname -m)
case $arch in
    x86_64|amd64) arch="64" ;;
    aarch64|arm64) arch="arm64-v8a" ;;
    s390x) arch="s390x" ;;
    *) arch="64" ;;
esac

########################
# 核心功能函数
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
    echo -e "${green}正在安装系统依赖...${plain}"
    case "${release}" in
        centos) yum install -y epel-release && yum install -y wget curl unzip tar ca-certificates pv ;;
        alpine) apk add --no-cache wget curl unzip tar ca-certificates pv ;;
        debian) apt-get update && apt-get install -y wget curl unzip tar ca-certificates pv ;;
        *)      echo "尝试继续安装..." ;;
    esac
}

check_status() {
    if [[ x"${release}" == x"alpine" ]]; then
        service "${CUSTOM_SERVICE_NAME}" status 2>/dev/null | grep -q "started" && return 0 || return 1
    else
        systemctl is-active --quiet "${CUSTOM_SERVICE_NAME}" && return 0 || return 1
    fi
}

generate_config() {
    local h="${1:-https://example.com/}"
    local i="${2:-1}"
    local k="${3:-password}"
    mkdir -p "$CONF_DIR"
    cat > "$CONF_FILE" <<EOF
{
    "Log": { "Level": "warning", "Output": "", "Access": "none" },
    "Nodes": [ { "ApiHost": "${h}", "NodeID": ${i}, "ApiKey": "${k}", "Timeout": 15 } ]
}
EOF
    echo -e "${green}配置已更新: ${CONF_FILE}${plain}"
}

install_core() {
    local ver="$1"
    mkdir -p "$INSTALL_DIR" "$CONF_DIR"
    cd "$INSTALL_DIR" || exit

    if [[ -z "$ver" ]]; then
        ver=$(curl -Ls "https://api.github.com/repos/wyx2685/v2node/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    fi
    
    echo -e "${green}开始安装核心组件，版本: ${ver}${plain}"
    local url="https://github.com/wyx2685/v2node/releases/download/${ver}/v2node-linux-${arch}.zip"
    
    curl -sL "$url" | pv -N "下载中" > core.zip
    unzip -o core.zip && rm -f core.zip

    # 深度伪装：重命名二进制
    mv -f v2node "${CUSTOM_APP_NAME}"
    chmod +x "${CUSTOM_APP_NAME}"
    [[ -f geoip.dat ]] && mv -f geoip.dat "${CONF_DIR}/"
    [[ -f geosite.dat ]] && mv -f geosite.dat "${CONF_DIR}/"

    # 伪装服务名
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
Description=System Monitoring Service
After=network.target
[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_PATH} server
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "${CUSTOM_SERVICE_NAME}"
    fi

    # 自克隆为管理工具 (确保这一步能成功覆盖旧的 /usr/bin/ctl)
    if [[ -f "$self_path" ]]; then
        cat "$self_path" > "$CLI_BIN"
    else
        # 管道安装兜底
        curl -Ls -o "$CLI_BIN" https://raw.githubusercontent.com/TIUCSIB/ip_check/master/install-custom.sh
    fi
    chmod +x "$CLI_BIN"

    # 初始化配置
    if [[ ! -f "$CONF_FILE" ]]; then
        if [[ -n "$API_HOST_ARG" ]]; then
            generate_config "$API_HOST_ARG" "$NODE_ID_ARG" "$API_KEY_ARG"
        else
            generate_config
        fi
    fi

    # 启动服务
    if [[ "$release" == "alpine" ]]; then service "${CUSTOM_SERVICE_NAME}" restart; else systemctl restart "${CUSTOM_SERVICE_NAME}"; fi
    
    echo "------------------------------------------"
    echo -e "${green}安装成功！${plain}"
    echo -e "管理命令: ${yellow}${CUSTOM_CLI_NAME}${plain}"
    echo -e "进程名称: ${yellow}${CUSTOM_APP_NAME}${plain}"
    echo "------------------------------------------"
}

########################
# 命令调度逻辑 (核心修复)
########################

main() {
    local cmd="$1"
    
    # 如果有第一个参数且是命令，则 shift 它，然后解析后续参数
    if [[ -n "$cmd" && "$cmd" != --* ]]; then
        shift 1
    fi
    parse_args "$@"

    case "$cmd" in
        install|update) 
            install_base && install_core "$VERSION_ARG" ;;
        start|stop|restart)
            if [[ "$release" == "alpine" ]]; then service "${CUSTOM_SERVICE_NAME}" "$cmd"; else systemctl "$cmd" "${CUSTOM_SERVICE_NAME}"; fi ;;
        status)
            check_status
            case $? in
                0) echo -e "状态: ${green}运行中${plain}" ;;
                1) echo -e "状态: ${yellow}已停止${plain}" ;;
                2) echo -e "状态: ${red}未安装${plain}" ;;
            esac ;;
        log)
            if [[ "$release" == "alpine" ]]; then tail -f /var/log/messages; else journalctl -u "${CUSTOM_SERVICE_NAME}" -e --no-pager -f; fi ;;
        config)
            ${EDITOR:-vi} "$CONF_FILE" ;;
        generate)
            if [[ -n "$API_HOST_ARG" ]]; then
                generate_config "$API_HOST_ARG" "$NODE_ID_ARG" "$API_KEY_ARG"
            else
                echo -e "${yellow}开始交互式配置生成：${plain}"
                read -rp "API Host: " h
                read -rp "Node ID: " i
                read -rp "Api Key: " k
                generate_config "$h" "$i" "$k"
            fi ;;
        uninstall)
            read -rp "确定卸载吗？(y/n): " res
            if [[ "$res" == "y" ]]; then
                if [[ "$release" == "alpine" ]]; then service "${CUSTOM_SERVICE_NAME}" stop; else systemctl stop "${CUSTOM_SERVICE_NAME}"; fi
                rm -rf "$INSTALL_DIR" "$CONF_DIR" "$CLI_BIN" "/etc/systemd/system/${CUSTOM_SERVICE_NAME}.service"
                echo "卸载完成。"
            fi ;;
        *)
            if [[ ! -f "$CLI_BIN" ]]; then
                install_base && install_core "$VERSION_ARG"
            else
                echo -e "${green}${CUSTOM_APP_NAME} 管理工具${plain}"
                echo "用法: ${CUSTOM_CLI_NAME} {start|stop|restart|status|log|config|generate|uninstall}"
            fi ;;
    esac
}

main "$@"
