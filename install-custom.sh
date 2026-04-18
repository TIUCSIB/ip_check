#!/bin/bash

# ========================
# Customizable section
# You can also override these via environment variables
# APP_NAME=agent CLI_NAME=ctl SERVICE_NAME=agent BIN_NAME=agent bash install-custom.sh
# ========================
APP_NAME="${APP_NAME:-nezha-agent}"
DISPLAY_NAME="${DISPLAY_NAME:-$APP_NAME}"
CLI_NAME="${CLI_NAME:-$APP_NAME}"
SERVICE_NAME="${SERVICE_NAME:-$APP_NAME}"
BIN_NAME="${BIN_NAME:-$APP_NAME}"
RUN_USER="${RUN_USER:-root}"
RUN_GROUP="${RUN_GROUP:-root}"

# Upstream binary source (still uses wyx2685/v2node releases by default)
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

# Compatibility mode: some builds may still read old geo/config paths
# Set to 0 if you want to remove /etc/v2node compatibility traces
ENABLE_LEGACY_COMPAT="${ENABLE_LEGACY_COMPAT:-1}"
LEGACY_COMPAT_DIR="${LEGACY_COMPAT_DIR:-/etc/v2node}"
# ========================

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)
self_path="${BASH_SOURCE[0]}"
RELEASE_API_URL="https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest"

VERSION_ARG=""
API_HOST_ARG=""
NODE_ID_ARG=""
API_KEY_ARG=""

[[ $EUID -ne 0 ]] && echo -e "${red}Error:${plain} this script must be run as root.\n" && exit 1

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
    echo -e "${red}Unable to detect the OS version. Please adapt the script manually.${plain}\n" && exit 1
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
    echo -e "${yellow}Architecture detection failed, using default: ${arch}${plain}"
fi

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ]; then
    echo "32-bit systems are not supported. Please use a 64-bit system."
    exit 2
fi

if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version:-7} -le 6 ]]; then
        echo -e "${red}Please use CentOS 7 or newer.${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version:-20} -lt 16 ]]; then
        echo -e "${red}Please use Ubuntu 16 or newer.${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version:-11} -lt 8 ]]; then
        echo -e "${red}Please use Debian 8 or newer.${plain}\n" && exit 1
    fi
fi

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
                show_usage
                exit 0 ;;
            --*)
                echo -e "${red}Unknown argument: $1${plain}"
                exit 1 ;;
            *)
                if [[ -z "$VERSION_ARG" ]]; then
                    VERSION_ARG="$1"
                fi
                shift ;;
        esac
    done
}

need_install_apt() {
    local packages=("$@")
    local missing=()
    local installed_list
    installed_list=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)
    for pkg in "${packages[@]}"; do
        echo "$installed_list" | grep -qx "$pkg" || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y "${missing[@]}"
    fi
}

need_install_yum() {
    local packages=("$@")
    local missing=()
    for pkg in "${packages[@]}"; do
        rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        yum install -y "${missing[@]}"
    fi
}

need_install_dnf() {
    local packages=("$@")
    local missing=()
    for pkg in "${packages[@]}"; do
        rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        dnf install -y "${missing[@]}"
    fi
}

need_install_apk() {
    local packages=("$@")
    local missing=()
    local installed_list
    installed_list=$(apk info 2>/dev/null | sort)
    for pkg in "${packages[@]}"; do
        echo "$installed_list" | grep -qx "$pkg" || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        apk add "${missing[@]}"
    fi
}

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        if command -v dnf >/dev/null 2>&1; then
            need_install_dnf wget curl unzip tar socat ca-certificates pv
        else
            need_install_yum wget curl unzip tar crontabs socat ca-certificates pv
        fi
        update-ca-trust force-enable >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"alpine" ]]; then
        need_install_apk wget curl unzip tar socat ca-certificates pv
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"debian" || x"${release}" == x"ubuntu" ]]; then
        need_install_apt wget curl unzip tar cron socat ca-certificates pv
        update-ca-certificates >/dev/null 2>&1 || true
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cronie socat ca-certificates pv >/dev/null 2>&1
    fi
}

print_banner() {
    echo "------------------------------------------"
    echo -e "${green}${DISPLAY_NAME}${plain} custom installer"
    echo "CLI name: ${CLI_NAME}"
    echo "Service name: ${SERVICE_NAME}"
    echo "Binary name: ${BIN_NAME}"
    echo "Install dir: ${INSTALL_DIR}"
    echo "Config file: ${CONFIG_FILE}"
    echo "Upstream repo: ${UPSTREAM_REPO}"
    echo "------------------------------------------"
}

service_action() {
    local action="$1"
    if [[ x"${release}" == x"alpine" ]]; then
        service "$SERVICE_NAME" "$action"
    else
        systemctl "$action" "$SERVICE_NAME"
    fi
}

check_status() {
    if [[ ! -x "${INSTALL_DIR}/${BIN_NAME}" ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        service "$SERVICE_NAME" status >/dev/null 2>&1 && return 0 || return 1
    else
        systemctl is-active --quiet "$SERVICE_NAME" && return 0 || return 1
    fi
}

check_enabled() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update show default 2>/dev/null | grep -qw "$SERVICE_NAME"
    else
        systemctl is-enabled --quiet "$SERVICE_NAME"
    fi
}

is_install_complete() {
    [[ -x "${INSTALL_DIR}/${BIN_NAME}" ]] || return 1
    [[ -x "${CLI_PATH}" ]] || return 1

    if [[ x"${release}" == x"alpine" ]]; then
        [[ -f "/etc/init.d/${SERVICE_NAME}" ]] || return 1
    else
        [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] || return 1
    fi

    return 0
}

show_status_line() {
    check_status
    case $? in
        0) echo -e "Status: ${green}running${plain}" ;;
        1) echo -e "Status: ${yellow}stopped${plain}" ;;
        2) echo -e "Status: ${red}not installed${plain}" ;;
    esac
    if check_enabled >/dev/null 2>&1; then
        echo -e "Autostart: ${green}enabled${plain}"
    else
        echo -e "Autostart: ${yellow}disabled${plain}"
    fi
}

resolve_version() {
    local version_param="$1"
    if [[ -n "$version_param" ]]; then
        echo "$version_param"
        return 0
    fi

    local last_version
    last_version=$(curl -fsSL "$RELEASE_API_URL" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$last_version" ]]; then
        echo -e "${red}Failed to detect the latest release. Please try again later or specify a version manually.${plain}"
        return 1
    fi
    echo "$last_version"
}

download_release() {
    local version="$1"
    local zip_path="$2"
    local url="https://github.com/${UPSTREAM_REPO}/releases/download/${version}/${UPSTREAM_RELEASE_ASSET_PREFIX}-${arch}.zip"

    echo -e "${green}Downloading: ${url}${plain}"
    curl -fL --progress-bar "$url" -o "$zip_path"
}

install_wrapper() {
    local source_script="${1:-$self_path}"
    mkdir -p "$(dirname "$SCRIPT_STORE_PATH")"
    cat "$source_script" > "$SCRIPT_STORE_PATH"
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
export UPSTREAM_BRANCH='${UPSTREAM_BRANCH}'
export UPSTREAM_RELEASE_ASSET_PREFIX='${UPSTREAM_RELEASE_ASSET_PREFIX}'
export UPSTREAM_RELEASE_BIN_NAME='${UPSTREAM_RELEASE_BIN_NAME}'
export INSTALL_DIR='${INSTALL_DIR}'
export CONFIG_DIR='${CONFIG_DIR}'
export CONFIG_FILE='${CONFIG_FILE}'
export CLI_PATH='${CLI_PATH}'
export SCRIPT_STORE_PATH='${SCRIPT_STORE_PATH}'
export PID_FILE='${PID_FILE}'
export KEEP_CONFIG_ON_UNINSTALL='${KEEP_CONFIG_ON_UNINSTALL}'
export AUTO_OPEN_PORTS='${AUTO_OPEN_PORTS}'
export ENABLE_LEGACY_COMPAT='${ENABLE_LEGACY_COMPAT}'
export LEGACY_COMPAT_DIR='${LEGACY_COMPAT_DIR}'
exec "$SCRIPT_STORE_PATH" "\$@"
EOF
    chmod +x "$CLI_PATH"
}

write_systemd_service() {
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=${DISPLAY_NAME} Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=${RUN_USER}
Group=${RUN_GROUP}
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/${BIN_NAME} server -c ${CONFIG_FILE}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

write_openrc_service() {
    cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/sbin/openrc-run

name="${DISPLAY_NAME}"
description="${DISPLAY_NAME}"
command="${INSTALL_DIR}/${BIN_NAME}"
command_args="server -c ${CONFIG_FILE}"
command_user="${RUN_USER}:${RUN_GROUP}"
pidfile="${PID_FILE}"
command_background="yes"

depend() {
    need net
}
EOF
    chmod +x "/etc/init.d/${SERVICE_NAME}"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
}

write_service_files() {
    if [[ x"${release}" == x"alpine" ]]; then
        rm -f "/etc/init.d/${SERVICE_NAME}"
        write_openrc_service
    else
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        write_systemd_service
    fi
}

sync_legacy_compat() {
    if [[ "$ENABLE_LEGACY_COMPAT" != "1" ]]; then
        return 0
    fi
    if [[ "$LEGACY_COMPAT_DIR" == "$CONFIG_DIR" ]]; then
        return 0
    fi

    mkdir -p "$LEGACY_COMPAT_DIR"
    [[ -f "${CONFIG_DIR}/geoip.dat" ]] && cp -f "${CONFIG_DIR}/geoip.dat" "$LEGACY_COMPAT_DIR/geoip.dat"
    [[ -f "${CONFIG_DIR}/geosite.dat" ]] && cp -f "${CONFIG_DIR}/geosite.dat" "$LEGACY_COMPAT_DIR/geosite.dat"
    if [[ -f "$CONFIG_FILE" ]]; then
        ln -sfn "$CONFIG_FILE" "$LEGACY_COMPAT_DIR/config.json"
    fi
}

cleanup_legacy_compat() {
    if [[ "$ENABLE_LEGACY_COMPAT" != "1" ]]; then
        return 0
    fi
    if [[ "$LEGACY_COMPAT_DIR" == "$CONFIG_DIR" ]]; then
        return 0
    fi

    rm -f "$LEGACY_COMPAT_DIR/config.json" "$LEGACY_COMPAT_DIR/geoip.dat" "$LEGACY_COMPAT_DIR/geosite.dat"
    rmdir "$LEGACY_COMPAT_DIR" >/dev/null 2>&1 || true
}

fix_permissions() {
    if id "$RUN_USER" >/dev/null 2>&1; then
        chown -R "$RUN_USER:$RUN_GROUP" "$INSTALL_DIR" >/dev/null 2>&1 || true
        chown -R "$RUN_USER:$RUN_GROUP" "$CONFIG_DIR" >/dev/null 2>&1 || true
    fi
}

report_service_status() {
    sleep 2
    check_status
    echo ""
    if [[ $? == 0 ]]; then
        echo -e "${green}${DISPLAY_NAME} started successfully${plain}"
    else
        echo -e "${red}${DISPLAY_NAME} may have failed to start. Run ${CLI_NAME} log to inspect it.${plain}"
    fi
}

generate_config() {
    local api_host="$1"
    local node_id="$2"
    local api_key="$3"

    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
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
    sync_legacy_compat

    echo -e "${green}Config file generated: ${CONFIG_FILE}${plain}"
    service_action restart >/dev/null 2>&1 || service_action start >/dev/null 2>&1 || true
    report_service_status
}

interactive_generate_config() {
    local api_host node_id api_key
    read -rp "API host [example: https://example.com/]: " api_host
    api_host=${api_host:-https://example.com/}
    read -rp "Node ID: " node_id
    node_id=${node_id:-1}
    read -rp "API key: " api_key

    generate_config "$api_host" "$node_id" "$api_key"
}

open_ports() {
    systemctl stop firewalld.service 2>/dev/null || true
    systemctl disable firewalld.service 2>/dev/null || true
    setenforce 0 2>/dev/null || true
    ufw disable 2>/dev/null || true
    iptables -P INPUT ACCEPT 2>/dev/null || true
    iptables -P FORWARD ACCEPT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    netfilter-persistent save 2>/dev/null || true
    echo -e "${green}Firewall rules have been relaxed.${plain}"
}

install_app() {
    local version_param="$1"
    local existed_config=0
    local first_install=0
    local release_version
    local zip_file
    local temp_self_copy

    [[ -f "$CONFIG_FILE" ]] && existed_config=1

    release_version=$(resolve_version "$version_param") || exit 1
    zip_file="${INSTALL_DIR}/${APP_NAME}-linux.zip"
    temp_self_copy="/tmp/${APP_NAME}-manage.$$.$RANDOM.sh"

    mkdir -p /tmp
    cat "$self_path" > "$temp_self_copy" || {
        echo -e "${red}Failed to save the current script. Installation cannot continue.${plain}"
        exit 1
    }

    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1

    download_release "$release_version" "$zip_file"
    if [[ $? -ne 0 || ! -s "$zip_file" ]]; then
        echo -e "${red}Download failed. Please check whether this server can access GitHub.${plain}"
        exit 1
    fi

    unzip -o "$zip_file" >/dev/null
    rm -f "$zip_file"

    if [[ ! -f "$UPSTREAM_RELEASE_BIN_NAME" ]]; then
        echo -e "${red}The binary was not found in the archive: ${UPSTREAM_RELEASE_BIN_NAME}${plain}"
        exit 1
    fi

    if [[ "$UPSTREAM_RELEASE_BIN_NAME" != "$BIN_NAME" ]]; then
        mv -f "$UPSTREAM_RELEASE_BIN_NAME" "$BIN_NAME"
    fi
    chmod +x "$BIN_NAME"

    mkdir -p "$CONFIG_DIR"
    [[ -f geoip.dat ]] && cp -f geoip.dat "$CONFIG_DIR/geoip.dat"
    [[ -f geosite.dat ]] && cp -f geosite.dat "$CONFIG_DIR/geosite.dat"

    fix_permissions
    sync_legacy_compat
    write_service_files
    install_wrapper "$temp_self_copy"
    rm -f "$temp_self_copy"

    if [[ "$AUTO_OPEN_PORTS" == "1" ]]; then
        open_ports
    fi

    echo -e "${green}${DISPLAY_NAME} ${release_version}${plain} install/update completed"

    if [[ $existed_config -eq 1 ]]; then
        service_action restart >/dev/null 2>&1 || service_action start >/dev/null 2>&1 || true
        report_service_status
    else
        first_install=1
        if [[ -n "$API_HOST_ARG" && -n "$NODE_ID_ARG" && -n "$API_KEY_ARG" ]]; then
            generate_config "$API_HOST_ARG" "$NODE_ID_ARG" "$API_KEY_ARG"
            first_install=0
        elif [[ -f "$INSTALL_DIR/config.json" && ! -f "$CONFIG_FILE" ]]; then
            cp -f "$INSTALL_DIR/config.json" "$CONFIG_FILE"
            sync_legacy_compat
        fi
    fi

    cd "$cur_dir" || exit 1
    echo "------------------------------------------"
    echo "Current settings:"
    echo "${CLI_NAME} start|stop|restart|status|enable|disable|log|generate|config|version|update|uninstall"
    echo "------------------------------------------"

    if [[ $first_install -eq 1 ]]; then
        read -rp "First install detected. Generate the config file now? (y/n): " if_generate
        if [[ "$if_generate" =~ ^[Yy]$ ]]; then
            interactive_generate_config
        else
            echo -e "${yellow}Skipped config generation. You can run ${CLI_NAME} generate later.${plain}"
        fi
    fi
}

start_app() {
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${yellow}${DISPLAY_NAME} is already running${plain}"
        return 0
    fi
    service_action start >/dev/null 2>&1 || true
    report_service_status
}

stop_app() {
    service_action stop >/dev/null 2>&1 || true
    sleep 2
    check_status
    if [[ $? == 1 || $? == 2 ]]; then
        echo -e "${green}${DISPLAY_NAME} stopped${plain}"
    else
        echo -e "${red}${DISPLAY_NAME} failed to stop${plain}"
    fi
}

restart_app() {
    service_action restart >/dev/null 2>&1 || service_action start >/dev/null 2>&1 || true
    report_service_status
}

status_app() {
    if [[ x"${release}" == x"alpine" ]]; then
        service "$SERVICE_NAME" status
    else
        systemctl status "$SERVICE_NAME" --no-pager -l
    fi
}

enable_app() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
    else
        systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}Autostart enabled${plain}"
    else
        echo -e "${red}Failed to change autostart setting${plain}"
    fi
}

disable_app() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1
    else
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}Autostart disabled${plain}"
    else
        echo -e "${red}Failed to change autostart setting${plain}"
    fi
}

show_log() {
    if [[ x"${release}" == x"alpine" ]]; then
        echo -e "${red}This log viewer is not supported on Alpine.${plain}"
        exit 1
    fi
    journalctl -u "${SERVICE_NAME}.service" -e --no-pager -f
}

edit_config() {
    mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${yellow}Config file is missing. Creating an empty template for you.${plain}"
        cat > "$CONFIG_FILE" <<EOF
{
    "Log": {
        "Level": "warning",
        "Output": "",
        "Access": "none"
    },
    "Nodes": []
}
EOF
    fi
    ${EDITOR:-vi} "$CONFIG_FILE"
    sync_legacy_compat
}

show_version() {
    if [[ ! -x "${INSTALL_DIR}/${BIN_NAME}" ]]; then
        echo -e "${red}Not installed${plain}"
        exit 1
    fi
    echo -n "${DISPLAY_NAME} version: "
    "${INSTALL_DIR}/${BIN_NAME}" version
}

uninstall_app() {
    read -rp "Uninstall ${DISPLAY_NAME}? (y/n): " answer
    [[ ! "$answer" =~ ^[Yy]$ ]] && exit 0

    service_action stop >/dev/null 2>&1 || true
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/${SERVICE_NAME}"
    else
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed >/dev/null 2>&1 || true
    fi

    rm -rf "$INSTALL_DIR"
    rm -f "$CLI_PATH"

    if [[ "$KEEP_CONFIG_ON_UNINSTALL" != "1" ]]; then
        rm -rf "$CONFIG_DIR"
    fi

    cleanup_legacy_compat
    echo -e "${green}Uninstall completed${plain}"
}

show_usage() {
    echo "${DISPLAY_NAME} usage:"
    echo "  bash $0 [version] [--api-host URL] [--node-id ID] [--api-key KEY]"
    echo "  ${CLI_NAME} install [version] [--api-host URL] [--node-id ID] [--api-key KEY]"
    echo "  ${CLI_NAME} update [version]"
    echo "  ${CLI_NAME} start|stop|restart|status|enable|disable|log|generate|config|version|uninstall"
    echo ""
    echo "Current settings:"
    echo "  APP_NAME=${APP_NAME}"
    echo "  CLI_NAME=${CLI_NAME}"
    echo "  SERVICE_NAME=${SERVICE_NAME}"
    echo "  BIN_NAME=${BIN_NAME}"
    echo "  INSTALL_DIR=${INSTALL_DIR}"
    echo "  CONFIG_FILE=${CONFIG_FILE}"
    echo "  UPSTREAM_REPO=${UPSTREAM_REPO}"
}

require_installed() {
    check_status
    if [[ $? == 2 ]]; then
        echo -e "${red}Please install ${DISPLAY_NAME} first${plain}"
        exit 1
    fi
}

main() {
    local cmd="${1:-}"

    case "$cmd" in
        install)
            shift
            parse_args "$@"
            print_banner
            install_base
            install_app "$VERSION_ARG"
            ;;
        update)
            shift
            parse_args "$@"
            require_installed
            print_banner
            install_base
            install_app "$VERSION_ARG"
            ;;
        start)
            require_installed
            start_app
            ;;
        stop)
            require_installed
            stop_app
            ;;
        restart)
            require_installed
            restart_app
            ;;
        status)
            require_installed
            status_app
            ;;
        enable)
            require_installed
            enable_app
            ;;
        disable)
            require_installed
            disable_app
            ;;
        log)
            require_installed
            show_log
            ;;
        generate)
            shift
            parse_args "$@"
            require_installed
            if [[ -n "$API_HOST_ARG" && -n "$NODE_ID_ARG" && -n "$API_KEY_ARG" ]]; then
                generate_config "$API_HOST_ARG" "$NODE_ID_ARG" "$API_KEY_ARG"
            else
                interactive_generate_config
            fi
            ;;
        config)
            require_installed
            edit_config
            ;;
        version)
            require_installed
            show_version
            ;;
        uninstall)
            require_installed
            uninstall_app
            ;;
        open-ports)
            open_ports
            ;;
        help|-h|--help)
            show_usage
            ;;
        "")
            if ! is_install_complete; then
                parse_args "$@"
                print_banner
                install_base
                install_app "$VERSION_ARG"
            else
                print_banner
                show_status_line
                echo ""
                show_usage
            fi
            ;;
        *)
            if ! is_install_complete; then
                parse_args "$@"
                print_banner
                install_base
                install_app "$VERSION_ARG"
            else
                echo -e "${red}Unknown command: ${cmd}${plain}"
                echo ""
                show_usage
                exit 1
            fi
            ;;
    esac
}

main "$@"
