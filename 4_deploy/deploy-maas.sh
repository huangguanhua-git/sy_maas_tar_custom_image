#!/bin/bash
set -euo pipefail
#set -x

MAAS_HOST="${MAAS_HOST:-10.1.5.4}"
PACKAGE_PORT="${PACKAGE_PORT:-22}"
MAAS_PORT="${MAAS_PORT:-5240}"
LOCAL_MAAS_PORT="${LOCAL_MAAS_PORT:-15240}"
JUMP_HOST="${JUMP_HOST:-}"
SSH_USER="${SSH_USER:-root}"
MAAS_SSH_PASS="${MAAS_SSH_PASS:-}"
MAAS_APIKEY="${MAAS_APIKEY:-35pStadEWVjWRSx2DR:W4VT9VELWKPjrTQSG5:L9PqbBmCcY5sWJLDJe3vhEASdAUTqnXu}"
TARGET_HOSTNAME="${1:?Usage: $0 <hostname>}"

if [ -n "$JUMP_HOST" ]; then echo "Mode: jump ${SSH_USER}@${JUMP_HOST} -> ${MAAS_HOST}"; else echo "Mode: direct ${MAAS_HOST}"; fi

_MAAS_URL="http://${MAAS_HOST}:${MAAS_PORT}/MAAS/api/2.0/"

if [ -n "$JUMP_HOST" ]; then
  echo "Tunnel: localhost:${LOCAL_MAAS_PORT} -> ${MAAS_HOST}:${MAAS_PORT} via ${JUMP_HOST} ..."
  lsof -ti:${LOCAL_MAAS_PORT} 2>/dev/null | xargs kill 2>/dev/null || true; sleep 1
  if [ -n "$MAAS_SSH_PASS" ]; then sshpass -p "${MAAS_SSH_PASS}" ssh -L ${LOCAL_MAAS_PORT}:${MAAS_HOST}:${MAAS_PORT} -N -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes ${SSH_USER}@${JUMP_HOST} &
  else ssh -L ${LOCAL_MAAS_PORT}:${MAAS_HOST}:${MAAS_PORT} -N -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes -o BatchMode=yes ${SSH_USER}@${JUMP_HOST} & fi
  _TUNNEL_PID=$!; trap "kill ${_TUNNEL_PID:-} 2>/dev/null || true" EXIT SIGTERM SIGINT; sleep 2
  kill -0 $_TUNNEL_PID 2>/dev/null || { echo "Tunnel failed"; exit 1; }
  _MAAS_URL="http://127.0.0.1:${LOCAL_MAAS_PORT}/MAAS/api/2.0/"; echo "Tunnel ready (PID: $_TUNNEL_PID)"
fi

IMG_NAME=$(sudo tail -n1 /home/ubuntu/custom-ubuntu-img/image.txt 2>/dev/null)
[ -z "$IMG_NAME" ] && { echo "No image record"; exit 1; }

if ! command -v maas &>/dev/null; then sudo add-apt-repository -y ppa:maas/3.7; sudo sed -i 's/jammy/noble/' /etc/apt/sources.list.d/maas-ubuntu-3_7-jammy.list; sudo apt update; sudo apt install -y maas-cli jq; fi

maas logout admin 2>/dev/null || true
maas login admin "$_MAAS_URL" "$MAAS_APIKEY" >/dev/null

SYSID=$(maas admin machines read | jq -r ".[] | select(.hostname==\"${TARGET_HOSTNAME}\") | .system_id")
[ -z "$SYSID" ] || [ "$SYSID" = "null" ] && { echo "Machine not found: ${TARGET_HOSTNAME}"; exit 1; }

user_data_base64=$(cat <<'CLOUDEOF' | base64 -w0
#cloud-config
chpasswd:
  list: |
    ubuntu:x4zAPiU9E8
  expire: False
disable_root: false
ssh_pwauth: true
runcmd:
  - |
    cat > /etc/apt/apt.conf.d/02proxy << EOF
    Acquire::http::Proxy "http://10.10.249.98:31420";
    Acquire::https::Proxy "http://10.10.249.98:31420";
    EOF
  - cp /etc/apt/sources.list /etc/apt/sources.list.bak
  - sed -i "/update_etc_hosts/c\  - ['update_etc_hosts', 'once-per-instance']" /etc/cloud/cloud.cfg
  - apt update
users:
  - default
  - name: root
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPj1SPlKibHozLqBeTlls4dTNOq1bNGU3O4GH5Je0XbB root@ubuntu
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOiiVEEbmttO4kgbXP7iUxzL6WGaWetr+bfzY/v7csjm root@sj-maas
CLOUDEOF
)

echo "Deploy custom/${IMG_NAME} ..."
maas admin machine deploy "$SYSID" distro_series="custom/${IMG_NAME}" user_data="$user_data_base64" >/dev/null
echo "Deploy command sent, waiting for Deployed ..."

TIMEOUT=1800; START_TIME=$(date +%s)
while true; do
 STATUS=$(maas admin machine read "$SYSID" | jq -r '.status_name')
 ELAPSED=$(( $(date +%s) - START_TIME ))
 echo "$(date '+%H:%M:%S') Status: ${STATUS}"
 [ "$STATUS" = "Deployed" ] && break
 [ "$STATUS" = "Failed deployment" ] && { echo "Deploy failed"; exit 1; }
 [ "$ELAPSED" -ge "$TIMEOUT" ] && { echo "Timeout"; exit 1; }
 sleep 30
done
echo "Deployed: ${TARGET_HOSTNAME}"

# GPU info from target - retry SSH for 2 minutes
INBAND_IP=$(maas admin machine read "$SYSID" 2>/dev/null | jq -r '.ip_addresses[0] // ""')
if [ -n "$INBAND_IP" ] && [ "$INBAND_IP" != "null" ]; then
  _JUMP_OPT=""; [ -n "$JUMP_HOST" ] && _JUMP_OPT="-J root@${JUMP_HOST},root@${MAAS_HOST}"
  echo "Waiting for SSH on ${INBAND_IP} ..."
  _SSH_READY=false; _SSH_WAIT=600; _SSH_START=$(date +%s)
  while true; do
    if sshpass -p "x4zAPiU9E8" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p${PACKAGE_PORT} ${_JUMP_OPT} ubuntu@${INBAND_IP} "echo ok" 2>/dev/null; then
      _SSH_READY=true; break
    fi
    _SSH_ELAPSED=$(( $(date +%s) - _SSH_START ))
    if [ $_SSH_ELAPSED -ge $_SSH_WAIT ]; then
      echo "SSH timeout after ${_SSH_WAIT}s, skip GPU info"; break
    fi
    echo "Waiting (${_SSH_ELAPSED}s)..."; sleep 30
  done
  if [ "$_SSH_READY" = true ]; then
    sshpass -p "x4zAPiU9E8" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p${PACKAGE_PORT} ${_JUMP_OPT} ubuntu@${INBAND_IP} bash -s 2>/dev/null <<'GPUEOF'
echo " ============================== GPU 信息采集 ============================================="
na() { [ -z "$1" ] && echo "NA" || echo "$1"; }
OS=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"' || :)
KERN=$(uname -r)
MOD=$(lsmod 2>/dev/null | grep -E 'nvidia|nouveau' | awk '{print $1}' | sort -u | paste -sd, || :)
DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || :)
FM=$(nv-fabricmanager -v|grep version|awk '{print$NF}' 2>/dev/null | grep -oP '[\d.]+' || :)
CUDA=$(/usr/local/cuda/bin/nvcc -V |grep release|awk '{print$5}'|cut -d, -f1 || :)
CTK=$(nvidia-ctk --version 2>/dev/null | head -1 || nvidia-container-runtime --version 2>/dev/null | head -1 || :)
DOCK=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || :)
SLURM=$(sinfo -V 2>/dev/null || scontrol --version 2>/dev/null || :)
FW=$(nvidia-smi -q 2>/dev/null | grep 'VBIOS Version' | awk -F': ' '{print $2}' | sort -u | paste -sd, || :)
OFED=$(ofed_info -s 2>/dev/null|cut -d: -f1 || :)
SSH=$(sudo ss -tnlp 2>/dev/null | grep sshd | head -1 | awk '{print $4}' | cut -d: -f2 || :)
echo "系统及版本: $(na "$OS")"
echo "内核版本: $KERN"
echo "内核模块: $(na "$MOD")"
echo "显卡驱动版本: $(na "$DRV")"
echo "OFED驱动版本: $(na "$OFED")"
echo "fabricmanager: $(na "$FM")"
echo "CUDA版本: $(na "$CUDA")"
echo "NVIDIA Container toolkit: $(na "$CTK")"
echo "docker-ce: $(na "$DOCK")"
echo "slurm: $(na "$SLURM")"
echo "GPU FW: $(na "$FW")"
echo "ssh端口: $(na "$SSH")"
echo " ========================================================================================="
exit 0
GPUEOF
  fi
fi

kill ${_TUNNEL_PID:-} 2>/dev/null || true
