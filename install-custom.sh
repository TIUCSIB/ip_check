#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

########################
# 这里只改外部显示名/服务名/命令名
########################
APP_NAME="nezha-agent"
SERVICE_NAME="nezha-agent"
CMD_NAME="nz"

# 这两个保持原程序默认，不要改
REAL_INSTALL_DIR="/usr/local/v2node"
REAL_CONFIG_DIR="/etc/v2node"

########################
# 参数解析
########################
VERSION_ARG=""
API_HOST_ARG=""
NODE_ID_ARG=""
API_KEY_ARG=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-host)
                API_HOST_ARG="$2"; shift 2 ;;
            --node-id)
                NODE_ID_ARG="$2"; shift 2 ;;
            --api-key)
                API_KEY_ARG="$2"; shift 2 ;;
            -h|--help)
                echo "用法: $0 [版本号] [--api-host URL] [--node-id ID] [--api-key KEY]"
                exit 0 ;;
            --*)
                echo "未知参数: $1"; exit 1 ;;
            *)
                if [[ -z "$VERSION_ARG" ]]; then
                    VERSION_ARG="$1"; shift
                else
                    shift
                fi ;;
        esac
    done
}

[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)"
    exit 2
fi

if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

install_base() {
    need_install_apt() {
        local packages=("$@")
        local missing=()
        local installed_list
        installed_list=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)

        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    need_install_yum() {
        local packages=("$@")
        local missing=()
        local installed_list
        installed_list=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | sort)

        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            yum install -y "${missing[@]}" >/dev/null 2>&1
        fi
    }

    need_install_apk() {
        local packages=("$@")
        local missing=()
        local installed_list
        installed_list=$(apk info 2>/dev/null | sort)

        for p in "${packages[@]}"; do
            if ! echo "$installed_list" | grep -q "^${p}$"; then
                missing+=("$p")
            fi
        done

        if [[ ${#missing[@]} -gt 0 ]]; then
            apk add --no-cache "${missing[@]}" >/dev/null 2>&1
        fi
    }

    if [[ x"${release}" == x"centos" ]]; then
        if ! rpm -q epel-release >/dev/null 2>&1; then
            yum install -y epel-release >/dev/null 2>&1
        fi
        need_install_yum wget curl unzip tar cronie socat ca-certificates pv
        update-ca-trust force-enable >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"alpine" ]]; then
        need_install_apk wget curl unzip tar socat ca-certificates pv bash
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"debian" ]]; then
        need_install_apt wget curl unzip tar cron socat ca-certificates pv bash
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"ubuntu" ]]; then
        need_install_apt wget curl unzip tar cron socat ca-certificates pv bash
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cronie socat ca-certificates pv bash >/dev/null 2>&1
    fi
}

service_start() {
    if [[ x"${release}" == x"alpine" ]]; then
        service "${SERVICE_NAME}" start
    else
        systemctl start "${SERVICE_NAME}"
    fi
}

service_stop() {
    if [[ x"${release}" == x"alpine" ]]; then
        service "${SERVICE_NAME}" stop
    else
        systemctl stop "${SERVICE_NAME}"
    fi
}

service_restart() {
    if [[ x"${release}" == x"alpine" ]]; then
        service "${SERVICE_NAME}" restart
    else
        systemctl restart "${SERVICE_NAME}"
    fi
}

check_status() {
    if [[ ! -f "${REAL_INSTALL_DIR}/v2node" ]]; then
        return 2
    fi

    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service "${SERVICE_NAME}" status 2>/dev/null | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status "${SERVICE_NAME}" 2>/dev/null | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

generate_v2node_config() {
    local api_host="$1"
    local node_id="$2"
    local api_key="$3"

    mkdir -p "${REAL_CONFIG_DIR}" >/dev/null 2>&1
    cat > "${REAL_CONFIG_DIR}/config.json" <<EOF
{
    "Log": {
        "Level": "warning",
        "Output": "",
        "Access": "none"
    },
    "Nodes": [
        {
            "ApiHost": "${api_host}",
            "NodeID": ${node_id},
            "ApiKey": "${api_key}",
            "Timeout": 15
        }
    ]
}
EOF

    echo -e "${green}${APP_NAME} 配置文件生成完成, 正在重新启动服务${plain}"
    service_restart
    sleep 2
    check_status
    echo
    if [[ $? == 0 ]]; then
        echo -e "${green}${APP_NAME} 重启成功${plain}"
    else
        echo -e "${red}${APP_NAME} 可能启动失败，请使用 ${CMD_NAME} log 查看日志${plain}"
    fi
}

install_v2node() {
    local version_param="$1"

    if [[ -e "${REAL_INSTALL_DIR}/" ]]; then
        rm -rf "${REAL_INSTALL_DIR}/"
    fi

    mkdir -p "${REAL_INSTALL_DIR}"
    cd "${REAL_INSTALL_DIR}" || exit 1

    if [[ -z "$version_param" ]]; then
        last_version=$(curl -Ls "https://api.github.com/repos/wyx2685/v2node/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}检测 v2node 版本失败${plain}"
            exit 1
        fi
        echo -e "${green}检测到最新版本：${last_version}，开始安装...${plain}"
        url="https://github.com/wyx2685/v2node/releases/download/${last_version}/v2node-linux-${arch}.zip"
        curl -sL "$url" | pv -s 30M -W -N "下载进度" > "${REAL_INSTALL_DIR}/v2node-linux.zip"
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载失败，请确保服务器可访问 Github${plain}"
            exit 1
        fi
    else
        last_version=$version_param
        url="https://github.com/wyx2685/v2node/releases/download/${last_version}/v2node-linux-${arch}.zip"
        curl -sL "$url" | pv -s 30M -W -N "下载进度" > "${REAL_INSTALL_DIR}/v2node-linux.zip"
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 v2node ${version_param} 失败${plain}"
            exit 1
        fi
    fi

    unzip v2node-linux.zip
    rm -f v2node-linux.zip
    chmod +x v2node
    mkdir -p "${REAL_CONFIG_DIR}"
    cp geoip.dat "${REAL_CONFIG_DIR}/"
    cp geosite.dat "${REAL_CONFIG_DIR}/"

    if [[ x"${release}" == x"alpine" ]]; then
        rm -f "/etc/init.d/${SERVICE_NAME}"
        cat <<EOF > "/etc/init.d/${SERVICE_NAME}"
#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="${APP_NAME}"

command="${REAL_INSTALL_DIR}/v2node"
command_args="server"
command_user="root"

pidfile="/run/${SERVICE_NAME}.pid"
command_background="yes"

depend() {
    need net
}
EOF
        chmod +x "/etc/init.d/${SERVICE_NAME}"
        rc-update add "${SERVICE_NAME}" default
        echo -e "${green}${APP_NAME} ${last_version}${plain} 安装完成，已设置开机自启"
    else
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        cat <<EOF > "/etc/systemd/system/${SERVICE_NAME}.service"
[Unit]
Description=${APP_NAME} Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=${REAL_INSTALL_DIR}
ExecStart=${REAL_INSTALL_DIR}/v2node server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
        systemctl enable "${SERVICE_NAME}"
        echo -e "${green}${APP_NAME} ${last_version}${plain} 安装完成，已设置开机自启"
    fi

    if [[ ! -f "${REAL_CONFIG_DIR}/config.json" ]]; then
        if [[ -n "$API_HOST_ARG" && -n "$NODE_ID_ARG" && -n "$API_KEY_ARG" ]]; then
            generate_v2node_config "$API_HOST_ARG" "$NODE_ID_ARG" "$API_KEY_ARG"
            echo -e "${green}已根据参数生成 ${REAL_CONFIG_DIR}/config.json${plain}"
            first_install=false
        else
            cp config.json "${REAL_CONFIG_DIR}/"
            first_install=true
        fi
    else
        service_start
        sleep 2
        check_status
        echo
        if [[ $? == 0 ]]; then
            echo -e "${green}${APP_NAME} 重启成功${plain}"
        else
            echo -e "${red}${APP_NAME} 可能启动失败，请使用 ${CMD_NAME} log 查看日志${plain}"
        fi
        first_install=false
    fi

    cat > "/usr/bin/${CMD_NAME}" <<EOF
#!/bin/sh

SERVICE_NAME="${SERVICE_NAME}"
APP_NAME="${APP_NAME}"

show_help() {
    echo "------------------------------------------"
    echo "管理命令使用方法:"
    echo "------------------------------------------"
    echo "${CMD_NAME} start        - 启动 \$APP_NAME"
    echo "${CMD_NAME} stop         - 停止 \$APP_NAME"
    echo "${CMD_NAME} restart      - 重启 \$APP_NAME"
    echo "${CMD_NAME} status       - 查看 \$APP_NAME 状态"
    echo "${CMD_NAME} enable       - 设置开机自启"
    echo "${CMD_NAME} disable      - 取消开机自启"
    echo "${CMD_NAME} log          - 查看日志"
    echo "${CMD_NAME} generate     - 配置文件在 ${REAL_CONFIG_DIR}/config.json"
    echo "${CMD_NAME} version      - 查看版本"
    echo "------------------------------------------"
}

if [ -z "\$1" ]; then
    show_help
    exit 0
fi

case "\$1" in
    start)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl start "\$SERVICE_NAME"
        else
            service "\$SERVICE_NAME" start
        fi
        ;;
    stop)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop "\$SERVICE_NAME"
        else
            service "\$SERVICE_NAME" stop
        fi
        ;;
    restart)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart "\$SERVICE_NAME"
        else
            service "\$SERVICE_NAME" restart
        fi
        ;;
    status)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl status "\$SERVICE_NAME" --no-pager
        else
            service "\$SERVICE_NAME" status
        fi
        ;;
    enable)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable "\$SERVICE_NAME"
        else
            rc-update add "\$SERVICE_NAME" default
        fi
        ;;
    disable)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable "\$SERVICE_NAME"
        else
            rc-update del "\$SERVICE_NAME" default
        fi
        ;;
    log)
        if command -v journalctl >/dev/null 2>&1; then
            journalctl -u "\$SERVICE_NAME" -n 100 --no-pager
        else
            echo "OpenRC 环境请直接执行: ${REAL_INSTALL_DIR}/v2node server"
        fi
        ;;
    version)
        ${REAL_INSTALL_DIR}/v2node version 2>/dev/null || echo "无法获取版本"
        ;;
    *)
        show_help
        ;;
esac
EOF

    chmod +x "/usr/bin/${CMD_NAME}"

    cd "${cur_dir}" || exit 1

    echo "------------------------------------------"
    echo "管理命令使用方法:"
    echo "------------------------------------------"
    echo "${CMD_NAME} start        - 启动 ${APP_NAME}"
    echo "${CMD_NAME} stop         - 停止 ${APP_NAME}"
    echo "${CMD_NAME} restart      - 重启 ${APP_NAME}"
    echo "${CMD_NAME} status       - 查看 ${APP_NAME} 状态"
    echo "${CMD_NAME} enable       - 设置 ${APP_NAME} 开机自启"
    echo "${CMD_NAME} disable      - 取消 ${APP_NAME} 开机自启"
    echo "${CMD_NAME} log          - 查看 ${APP_NAME} 日志"
    echo "${CMD_NAME} generate     - 生成 ${APP_NAME} 配置文件"
    echo "${CMD_NAME} version      - 查看 ${APP_NAME} 版本"
    echo "------------------------------------------"

    if [[ $first_install == true ]]; then
        read -rp "检测到首次安装 ${APP_NAME}，是否自动生成 ${REAL_CONFIG_DIR}/config.json？(y/n): " if_generate
        if [[ "$if_generate" =~ ^[Yy]$ ]]; then
            read -rp "面板API地址[格式: https://example.com/]: " api_host
            api_host=${api_host:-https://example.com/}
            read -rp "节点ID: " node_id
            node_id=${node_id:-1}
            read -rp "节点通讯密钥: " api_key
            generate_v2node_config "$api_host" "$node_id" "$api_key"
        else
            echo -e "${green}已跳过自动生成配置。请手动编辑 ${REAL_CONFIG_DIR}/config.json${plain}"
        fi
    fi
}

parse_args "$@"
echo -e "${green}开始安装 ${APP_NAME}${plain}"
install_base
install_v2node "$VERSION_ARG"
