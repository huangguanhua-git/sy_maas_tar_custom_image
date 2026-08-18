#!/bin/bash
set -euo pipefail

MAAS_HOST="${MAAS_HOST:-10.1.5.4}"
MAAS_PORT="${MAAS_PORT:-5240}"
LOCAL_MAAS_PORT="${LOCAL_MAAS_PORT:-15240}"
JUMP_HOST="${JUMP_HOST:-}"
SSH_USER="${SSH_USER:-root}"
MAAS_SSH_PASS="${MAAS_SSH_PASS:-}"
MAAS_APIKEY="${MAAS_APIKEY:-35pStadEWVjWRSx2DR:W4VT9VELWKPjrTQSG5:L9PqbBmCcY5sWJLDJe3vhEASdAUTqnXu}"
TARGET_HOSTNAME="${1:?Usage: $0 <hostname>}"
TIMEOUT=1200

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

if ! command -v maas &>/dev/null; then sudo add-apt-repository -y ppa:maas/3.7; sudo sed -i 's/jammy/noble/' /etc/apt/sources.list.d/maas-ubuntu-3_7-jammy.list; sudo apt update; sudo apt install -y maas-cli jq; fi
maas logout admin 2>/dev/null || true
maas login admin "$_MAAS_URL" "$MAAS_APIKEY" >/dev/null

SYSID=$(maas admin machines read | jq -r ".[] | select(.hostname==\"${TARGET_HOSTNAME}\") | .system_id")
[ -z "$SYSID" ] || [ "$SYSID" = "null" ] && { echo "Machine not found: ${TARGET_HOSTNAME}"; exit 1; }

DETAIL=$(maas admin machine read "$SYSID")
STATUS=$(echo "$DETAIL" | jq -r '.status_name')
INBAND_IP=$(echo "$DETAIL" | jq -r '.ip_addresses[0] // "N/A"')
POWER_TYPE=$(echo "$DETAIL" | jq -r '.power_type // "N/A"')
BMC_INFO=$(maas admin machines power-parameters 2>/dev/null | jq -r --arg id "$SYSID" '.[$id].power_address // "N/A"')
[ "$BMC_INFO" = "N/A" ] && BMC_INFO="$POWER_TYPE"

echo "=============================================="
echo "HOSTNAME   : ${TARGET_HOSTNAME}"
echo "SYSTEM_ID  : ${SYSID}"
echo "STATUS     : ${STATUS}"
echo "BMC        : ${BMC_INFO}"
echo "POWER_TYPE : ${POWER_TYPE}"
echo "INBAND IP  : ${INBAND_IP}"
echo "=============================================="

if [ "$STATUS" != "Ready" ]; then
 echo "Release + Erase ..."
 maas admin machine release "$SYSID" erase=true >/dev/null
 for i in $(seq 1 $((TIMEOUT / 30))); do
 STATUS=$(maas admin machine read "$SYSID" | jq -r '.status_name'); echo "$(date '+%H:%M:%S') ${STATUS}"
 [ "$STATUS" = "Ready" ] && break; sleep 30
 done
 [ "$STATUS" != "Ready" ] && { echo "Timeout waiting for Ready"; exit 1; }
fi
kill ${_TUNNEL_PID:-} 2>/dev/null || true
