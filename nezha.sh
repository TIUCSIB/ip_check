#!/bin/bash

# ==========================================
# 用户自定义配置
echo -e "--- 自定义设置 ---"
read -p "1. 请输入你想要显示的进程/目录名称 (建议英文，如: nezha): " CUSTOM_NAME
CUSTOM_NAME=${CUSTOM_NAME:-nezha}
read -p "2. 请输入你想要使用的管理命令名称 (建议简短，如: nz): " CUSTOM_CMD
CUSTOM_CMD=${CUSTOM_CMD:-nz}
echo -e "------------------\n"
# ==========================================

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
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
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates -y >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        # --- 关键修复：安装 gcompat 以支持在 Alpine 运行 Linux 二进制程序 ---
        apk update
        apk add wget curl unzip tar socat ca-certificates gcompat libc6-compat >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    else
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    fi
}

install_V2bX() {
    [[ -e /usr/local/${CUSTOM_NAME}/ ]] && rm -rf /usr/local/${CUSTOM_NAME}/
    mkdir /usr/local/${CUSTOM_NAME}/ -p
    cd /usr/local/${CUSTOM_NAME}/

    last_version=$(curl -Ls "https://api.github.com/repos/wyx2685/V2bX/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ ! -n "$last_version" ]] && echo -e "${red}检测版本失败${plain}" && exit 1
    
    wget --no-check-certificate -N -O package.zip https://github.com/wyx2685/V2bX/releases/download/${last_version}/V2bX-linux-${arch}.zip
    unzip package.zip && rm package.zip -f
    mv V2bX ${CUSTOM_NAME}
    chmod +x ${CUSTOM_NAME}
    
    mkdir /etc/${CUSTOM_NAME}/ -p
    cp geoip.dat geosite.dat /etc/${CUSTOM_NAME}/

    # --- Alpine (OpenRC) 启动脚本修复 ---
    if [[ x"${release}" == x"alpine" ]]; then
        rm /etc/init.d/${CUSTOM_NAME} -f
        cat <<EOF > /etc/init.d/${CUSTOM_NAME}
#!/sbin/openrc-run

name="${CUSTOM_NAME}"
description="${CUSTOM_NAME} Service"

# 关键：指定工作目录，否则程序找不到 geoip 等文件
directory="/usr/local/${CUSTOM_NAME}"
command="/usr/local/${CUSTOM_NAME}/${CUSTOM_NAME}"
command_args="server -c /etc/${CUSTOM_NAME}/config.json"
command_user="root"

pidfile="/run/${CUSTOM_NAME}.pid"
command_background="yes"

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/${CUSTOM_NAME}
        rc-update add ${CUSTOM_NAME} default
    else
        # Systemd 修复 (Debian/Ubuntu/CentOS)
        cat <<EOF > /etc/systemd/system/${CUSTOM_NAME}.service
[Unit]
Description=${CUSTOM_NAME} Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
WorkingDirectory=/usr/local/${CUSTOM_NAME}/
ExecStart=/usr/local/${CUSTOM_NAME}/${CUSTOM_NAME} server -c /etc/${CUSTOM_NAME}/config.json
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ${CUSTOM_NAME}
    fi

    # 处理管理脚本
    curl -o /usr/bin/${CUSTOM_CMD} -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/V2bX.sh
    chmod +x /usr/bin/${CUSTOM_CMD}
    sed -i "s/V2bX/${CUSTOM_NAME}/g" /usr/bin/${CUSTOM_CMD}
    sed -i "s/v2bx/${CUSTOM_CMD}/g" /usr/bin/${CUSTOM_CMD}
    sed -i "s/\/etc\/V2bX/\/etc\/${CUSTOM_NAME}/g" /usr/bin/${CUSTOM_CMD}
    sed -i "s/\/usr\/local\/V2bX/\/usr\/local\/${CUSTOM_NAME}/g" /usr/bin/${CUSTOM_CMD}

    # 处理初始化配置脚本
    if [[ ! -f /etc/${CUSTOM_NAME}/config.json ]]; then
        cp config.json /etc/${CUSTOM_NAME}/
        echo -e "${green}正在下载初始化配置脚本...${plain}"
        curl -o ./initconfig.sh -Ls https://raw.githubusercontent.com/wyx2685/V2bX-script/master/initconfig.sh
        sed -i "s/v2bx/${CUSTOM_CMD}/g" ./initconfig.sh
        sed -i "s/V2bX/${CUSTOM_NAME}/g" ./initconfig.sh
        sed -i "s/\/etc\/V2bX/\/etc\/${CUSTOM_NAME}/g" ./initconfig.sh
        source initconfig.sh
        generate_config_file
        rm initconfig.sh -f
    fi

    # 启动服务
    if [[ x"${release}" == x"alpine" ]]; then
        service ${CUSTOM_NAME} restart
    else
        systemctl restart ${CUSTOM_NAME}
    fi
    
    echo -e "${green}${CUSTOM_NAME} 安装并启动成功！管理命令: ${CUSTOM_CMD}${plain}"
}

install_base
install_V2bX $1
