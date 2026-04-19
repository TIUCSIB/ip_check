#!/bin/bash

echo "--- 自定义设置 ---"
read -p "1. 显示名称 (默认: v2node): " CUSTOM_NAME
CUSTOM_NAME=${CUSTOM_NAME:-v2node}

read -p "2. 管理命令名称 (默认: vn): " CUSTOM_CMD
CUSTOM_CMD=${CUSTOM_CMD:-vn}
echo "------------------"

red='\033[0;31m'
green='\033[0;32m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${red}必须 root 运行${plain}" && exit 1

# ===== 系统判断 =====
if grep -qi alpine /etc/issue; then
    release="alpine"
else
    release="other"
fi

arch=$(uname -m)
[[ "$arch" == "x86_64" ]] && arch="64"
[[ "$arch" == "aarch64" ]] && arch="arm64-v8a"

# ===== 安装依赖 =====
if [[ "$release" == "alpine" ]]; then
    apk update
    apk add wget curl unzip tar socat ca-certificates gcompat libc6-compat bash
else
    apt update -y
    apt install -y wget curl unzip tar socat ca-certificates bash
fi

# ===== 安装原版 v2node =====
rm -rf /usr/local/v2node
mkdir -p /usr/local/v2node
cd /usr/local/v2node || exit

version=$(curl -s https://api.github.com/repos/wyx2685/v2node/releases/latest | grep tag_name | cut -d '"' -f4)

wget -O v2node.zip https://github.com/wyx2685/v2node/releases/download/${version}/v2node-linux-${arch}.zip
unzip v2node.zip
rm -f v2node.zip
chmod +x v2node

mkdir -p /etc/v2node
cp geoip.dat geosite.dat /etc/v2node

# ===== 服务（自定义名称）=====
if [[ "$release" == "alpine" ]]; then

cat > /etc/init.d/${CUSTOM_NAME} <<EOF
#!/sbin/openrc-run

name="${CUSTOM_NAME}"
description="${CUSTOM_NAME}"

directory="/usr/local/v2node"
command="/usr/local/v2node/v2node"
command_args="server -c /etc/v2node/config.json"
command_user="root"

pidfile="/run/${CUSTOM_NAME}.pid"
command_background="yes"
start_stop_daemon_args="--make-pidfile --pidfile \${pidfile}"

depend() {
    need net
}
EOF

chmod +x /etc/init.d/${CUSTOM_NAME}
rc-update add ${CUSTOM_NAME} default

else

cat > /etc/systemd/system/${CUSTOM_NAME}.service <<EOF
[Unit]
Description=${CUSTOM_NAME} Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
WorkingDirectory=/usr/local/v2node/
ExecStart=/usr/local/v2node/v2node server -c /etc/v2node/config.json
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ${CUSTOM_NAME}

fi

# ===== 下载官方菜单脚本 =====
curl -o /usr/bin/${CUSTOM_CMD} -Ls https://raw.githubusercontent.com/wyx2685/v2node/main/script/v2node.sh
chmod +x /usr/bin/${CUSTOM_CMD}

# ===== 替换菜单中的名称 =====
sed -i "s/v2node/${CUSTOM_CMD}/g" /usr/bin/${CUSTOM_CMD}
sed -i "s/V2node/${CUSTOM_NAME}/g" /usr/bin/${CUSTOM_CMD}
sed -i "s/service v2node/service ${CUSTOM_NAME}/g" /usr/bin/${CUSTOM_CMD}
sed -i "s/systemctl .* v2node/systemctl restart ${CUSTOM_NAME}/g" /usr/bin/${CUSTOM_CMD}

# ===== 初始化配置 =====
if [[ ! -f /etc/v2node/config.json ]]; then
    cp config.json /etc/v2node/config.json
fi

# ===== 启动 =====
if [[ "$release" == "alpine" ]]; then
    service ${CUSTOM_NAME} restart
else
    systemctl restart ${CUSTOM_NAME}
fi

echo -e "${green}安装完成！${plain}"
echo "命令: ${CUSTOM_CMD}"
