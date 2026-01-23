#!/bin/bash
# Tactical RMM Linux installer/updater/uninstaller
# https://github.com/Nerdy-Technician/LinuxRMM-Script
# Author: Nerdy-Technician <


set -euo pipefail

#--- simple/pretty output ------------------------------------------------------
SIMPLE=false
if [[ "${1:-}" == "--simple" ]]; then
    SIMPLE=true
    shift
fi

# color codes
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

function info_echo() { 
    if $SIMPLE; then
        echo -e "\n[${BLUE}INFO${RESET}] $1\n"
    else
        echo "$1"
    fi
}

function ok_echo() {
    if $SIMPLE; then
        echo -e "[${GREEN}OK${RESET}] ✅ $1\n"
    else
        echo "$1"
    fi
}

function err_echo() {
    if $SIMPLE; then
        echo -e "[${RED}ERROR${RESET}] ❌ $1\n"
    else
        echo "$1"
    fi
}

#--- cleanup trap --------------------------------------------------------------
cleanup() {
    info_echo "Cleaning up temporary files..."
    rm -rf /tmp/temp_rmmagent \
           /tmp/rmmagent-master \
           /tmp/meshagent \
           /tmp/meshagent.msh \
           /tmp/golang.tar.gz \
           ./go 2>/dev/null || true
    ok_echo "Temporary files cleaned."
}
trap cleanup EXIT

#--- safety: require root -------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (e.g. sudo $0 ...)"
    exit 1
fi

#--- usage / guards -------------------------------------------------------------
if [[ -z "${1:-}" ]]; then
    echo "First argument is empty!"
    echo "Type 'help' for more information"
    exit 1
fi

if [[ "$1" == "help" ]]; then
    cat <<'EOF'
Help available at:
  github.com/Brandon-Roff/LinuxRMM-Script

Install example:
  sudo bash rmmagent-linux.sh install \
    "https://mesh.example.com/meshagents?id=ENCODED_ID" \
    "https://rmm-api.example.com" \
    1 2 "SuperSecretAuthKey" server
EOF
    exit 0
fi

if [[ "$1" != "install" && "$1" != "update" && "$1" != "uninstall" ]]; then
    echo "First argument can only be 'install', 'update', or 'uninstall'!"
    exit 1
fi

#--- arch detection -------------------------------------------------------------

function detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        i386|i686) echo "x86" ;;
        aarch64) echo "arm64" ;;
        armv6l|armv7l) echo "armv6" ;;
        *) echo "unsupported" ;;
    esac
}


#--- inputs --------------------------------------------------------------------
mesh_url="${2:-}"
rmm_url="${3:-}"
rmm_client_id="${4:-}"
rmm_site_id="${5:-}"
rmm_auth="${6:-}"
rmm_agent_type="${7:-}"

# uninstall inputs
mesh_fqdn="${2:-}"
mesh_id="${3:-}"

#--- versions / URLs -----------------------------------------------------------
go_version="1.25.6"
go_url_amd64="https://go.dev/dl/go${go_version}.linux-amd64.tar.gz"
go_url_x86="https://go.dev/dl/go${go_version}.linux-386.tar.gz"
go_url_arm64="https://go.dev/dl/go${go_version}.linux-arm64.tar.gz"
go_url_armv6="https://go.dev/dl/go${go_version}.linux-armv6l.tar.gz"

mesh_amd64="&installflags=0&meshinstall=6"
mesh_arm6l="&installflags=0&meshinstall=25"
mesh_arm64="&installflags=0&meshinstall=26"

#--- helpers -------------------------------------------------------------------
function go_install() {
    system=$(detect_arch)
    if ! command -v go >/dev/null 2>&1; then
        info_echo "Installing Go $go_version for $system..."
        case "$system" in
            amd64) url="$go_url_amd64" ;;
            x86)   url="$go_url_x86" ;;
            arm64) url="$go_url_arm64" ;;
            armv6) url="$go_url_armv6" ;;
        esac
        wget -q --show-progress -O /tmp/golang.tar.gz "$url"
        rm -rf /usr/local/go/
        tar -xzf /tmp/golang.tar.gz -C /usr/local/

        export PATH=/usr/local/go/bin:$PATH
        if ! grep -q "/usr/local/go/bin" /etc/profile; then
            echo 'export PATH=/usr/local/go/bin:$PATH' >> /etc/profile
        fi
        ok_echo "Go $go_version installed."
    fi
}

function update_agent() {
    systemctl stop tacticalagent
    cp "/tmp/temp_rmmagent" /usr/local/bin/rmmagent
    rm "/tmp/temp_rmmagent"
    systemctl start tacticalagent
}

function agent_compile() {
    info_echo "Compiling Tactical RMM agent for $system..."
    wget -q --show-progress -O /tmp/rmmagent.tar.gz "https://github.com/amidaware/rmmagent/archive/refs/heads/master.tar.gz"
    tar -xf /tmp/rmmagent.tar.gz -C /tmp/
    cd /tmp/rmmagent-master

    case "$system" in
        amd64) env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o /tmp/temp_rmmagent ;;
        x86)   env CGO_ENABLED=0 GOOS=linux GOARCH=386   go build -ldflags "-s -w" -o /tmp/temp_rmmagent ;;
        arm64) env CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o /tmp/temp_rmmagent ;;
        armv6) env CGO_ENABLED=0 GOOS=linux GOARCH=arm   go build -ldflags "-s -w" -o /tmp/temp_rmmagent ;;
    esac

    cd /tmp
    ok_echo "Tactical RMM agent compiled."
}

function install_agent() {
    info_echo "Installing Tactical Agent service..."
    
    # Remove old binary and config if present
    rm -f /usr/local/bin/rmmagent
    if [ -d /etc/tacticalagent ]; then
        rm -rf /etc/tacticalagent
        info_echo "Old /etc/tacticalagent removed."
    fi

    install -m 0755 /tmp/temp_rmmagent /usr/local/bin/rmmagent

    if $SIMPLE; then
        echo
        if /usr/local/bin/rmmagent -m install \
            -api "$rmm_url" \
            -client-id "$rmm_client_id" \
            -site-id "$rmm_site_id" \
            -agent-type "$rmm_agent_type" \
            -auth "$rmm_auth"; then
            ok_echo "Tactical Agent installed successfully."
        else
            err_echo "Tactical Agent failed to install. Check logs or run without --simple."
            exit 1
        fi
    else
        /usr/local/bin/rmmagent -m install \
            -api "$rmm_url" \
            -client-id "$rmm_client_id" \
            -site-id "$rmm_site_id" \
            -agent-type "$rmm_agent_type" \
            -auth "$rmm_auth"
    fi

    # systemd service
    cat >/etc/systemd/system/tacticalagent.service <<'EOF'
[Unit]
Description=Tactical RMM Linux Agent
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rmmagent -m svc
User=root
Group=root
Restart=always
RestartSec=5s
LimitNOFILE=1000000
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now tacticalagent
    ok_echo "Tactical Agent service installed and started."
}

function install_mesh() {
    info_echo "Installing MeshCentral agent for $system..."
    case "$system" in
        amd64) mesh_param="$mesh_amd64" ;;
        armv6) mesh_param="$mesh_arm6l" ;;
        arm64) mesh_param="$mesh_arm64" ;;
        x86)   mesh_param="$mesh_amd64" ;;
        *) echo "No Mesh installer flag for this architecture: $system"; exit 1 ;;
    esac

    full_mesh_url="${mesh_url}${mesh_param}"
    wget -q --show-progress -O /tmp/meshagent "$full_mesh_url"
    chmod +x /tmp/meshagent
    mkdir -p /opt/tacticalmesh
    /tmp/meshagent -install --installPath="/opt/tacticalmesh"
    ok_echo "Mesh agent installed."
}

function uninstall_agent() {
    info_echo "Uninstalling Tactical Agent..."
    systemctl stop tacticalagent || true
    systemctl disable tacticalagent || true
    rm -f /etc/systemd/system/tacticalagent.service
    systemctl daemon-reload
    rm -f /usr/local/bin/rmmagent
    rm -rf /etc/tacticalagent
    ok_echo "Tactical Agent uninstalled."
}

function uninstall_mesh() {
    info_echo "Uninstalling MeshCentral agent..."
    if [[ -z "$mesh_fqdn" || -z "$mesh_id" ]]; then
        err_echo "Mesh FQDN and Mesh ID are required for uninstall."
        exit 1
    fi

    wget "https://${mesh_fqdn}/meshagents?script=1" -O /tmp/meshinstall.sh \
        || wget "https://${mesh_fqdn}/meshagents?script=1" --no-proxy -O /tmp/meshinstall.sh

    chmod 755 /tmp/meshinstall.sh
    /tmp/meshinstall.sh uninstall "https://${mesh_fqdn}" "$mesh_id" || true
    ok_echo "Mesh agent uninstall attempted."
}

#--- dispatcher ----------------------------------------------------------------
case "$1" in
    install)
        go_install
        install_mesh
        agent_compile
        install_agent
        ok_echo "Tactical Agent Install is done."
        ;;
    update)
        go_install
        agent_compile
        update_agent
        ok_echo "Tactical Agent Update is done."
        ;;
    uninstall)
        uninstall_agent
        uninstall_mesh
        ok_echo "Tactical Agent Uninstall is done."
        ;;
esac
