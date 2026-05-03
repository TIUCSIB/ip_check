#!/bin/bash

# ==========================================
# 自定义区域：在这里修改你想要的命令、进程名和路径名
MY_CMD="nz" 
MY_DIR="nezha-agent"      # 这里的名字将代替 v2node 文件夹名
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
    echo -e "${red}未检测到系统版本${plain}\n" && exit 1
fi

arch=$(uname -m)
if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
else
    arch="64"
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install -y wget curl unzip tar cronie socat ca-certificates pv >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add --no-cache wget curl unzip tar socat ca-certificates pv >/dev/null 2>&1
    else
        apt-get update -y >/dev/null 2>&1
        apt-get install -y wget curl unzip tar cron socat ca-certificates pv >/dev/null 2>&1
    fi
}

install_v2node() {
    # 彻底清理旧的残留（如果存在）
    rm -rf /usr/local/v2node /etc/v2node /usr/bin/v2node >/dev/null 2>&1
    
    # 1. 创建自定义路径
    local install_path="/usr/local/${MY_DIR}"
    local config_path="/etc/${MY_DIR}"
    
    mkdir -p $install_path
    mkdir -p $config_path
    cd $install_path

    # 2. 下载与重命名
    last_version=$(curl -Ls "https://api.github.com/repos/wyx2685/v2node/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    url="https://github.com/wyx2685/v2node/releases/download/${last_version}/v2node-linux-${arch}.zip"
    
    curl -sL "$url" | pv -s 30M -W -N "下载进度" > package.zip
    unzip package.zip && rm package.zip -f

    # 将二进制改名为自定义命令名
    mv v2node ${MY_CMD}
    chmod +x ${MY_CMD}
    cp geoip.dat geosite.dat $config_path/

    # 3. 写入配置文件模板 (使用新路径)
    cat > $config_path/config.json <<EOF
{
    "Log": { "Level": "warning", "Output": "", "Access": "none" },
    "Nodes": [ { "ApiHost": "https://example.com", "NodeID": 1, "ApiKey": "yourkey", "Timeout": 15 } ]
}
EOF

    # 4. 设置系统服务 (指向新路径、新进程名)
    if [[ x"${release}" == x"alpine" ]]; then
        cat <<EOF > /etc/init.d/${MY_CMD}
#!/sbin/openrc-run
name="${MY_CMD}"
command="${install_path}/${MY_CMD}"
command_args="server --config ${config_path}/config.json"
pidfile="/run/${MY_CMD}.pid"
command_background="yes"
depend() { need net; }
EOF
        chmod +x /etc/init.d/${MY_CMD}
        rc-update add ${MY_CMD} default
    else
        cat <<EOF > /etc/systemd/system/${MY_CMD}.service
[Unit]
Description=${MY_CMD} Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${install_path}
ExecStart=${install_path}/${MY_CMD} server --config ${config_path}/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ${MY_CMD}
        systemctl start ${MY_CMD}
    fi

    # 5. 生成管理脚本
    curl -o /usr/bin/${MY_CMD} -Ls https://raw.githubusercontent.com/wyx2685/v2node/main/script/v2node.sh
    # 替换脚本内的所有 v2node 字样，包括路径和命令
    sed -i "s/v2node/${MY_CMD}/g" /usr/bin/${MY_CMD}
    sed -i "s/V2node/${MY_CMD}/g" /usr/bin/${MY_CMD}
    sed -i "s/\/etc\/${MY_CMD}/\/etc\/${MY_DIR}/g" /usr/bin/${MY_CMD}
    sed -i "s/\/usr\/local\/${MY_CMD}/\/usr\/local\/${MY_DIR}/g" /usr/bin/${MY_CMD}
    chmod +x /usr/bin/${MY_CMD}

    # 6. 原版排版帮助菜单
    echo "------------------------------------------"
    echo -e "管理脚本使用方法: "
    echo "------------------------------------------"
    echo "${MY_CMD}              - 显示管理菜单 (功能更多)"
    echo "${MY_CMD} start        - 启动 ${MY_CMD}"
    echo "${MY_CMD} stop         - 停止 ${MY_CMD}"
    echo "${MY_CMD} restart      - 重启 ${MY_CMD}"
    echo "${MY_CMD} status       - 查看 ${MY_CMD} 状态"
    echo "${MY_CMD} enable       - 设置 ${MY_CMD} 开机自启"
    echo "${MY_CMD} disable      - 取消 ${MY_CMD} 开机自启"
    echo "${MY_CMD} log          - 查看 ${MY_CMD} 日志"
    echo "${MY_CMD} generate     - 生成 ${MY_CMD} 配置文件"
    echo "${MY_CMD} update       - 更新 ${MY_CMD}"
    echo "${MY_CMD} update x.x.x - 更新 ${MY_CMD} 指定版本"
    echo "${MY_CMD} install      - 安装 ${MY_CMD}"
    echo "${MY_CMD} uninstall    - 卸载 ${MY_CMD}"
    echo "${MY_CMD} version      - 查看 ${MY_CMD} 版本"
    echo "------------------------------------------"
}

echo -e "${green}开始隐身安装...${plain}"
install_base
install_v2node
