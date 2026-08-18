#!/bin/bash
set -euo pipefail

MAAS_HOST="${MAAS_HOST:-10.1.5.4}"
MAAS_PORT="${MAAS_PORT:-5240}"
LOCAL_MAAS_PORT="${LOCAL_MAAS_PORT:-15240}"
JUMP_HOST="${JUMP_HOST:-}"
SSH_USER="${SSH_USER:-root}"
MAAS_SSH_PASS="${MAAS_SSH_PASS:-}"
MAAS_APIKEY="${MAAS_APIKEY:-35pStadEWVjWRSx2DR:W4VT9VELWKPjrTQSG5:L9PqbBmCcY5sWJLDJe3vhEASdAUTqnXu}"
TAR_FILE="${1:-$(cat /tmp/.last-package-path 2>/dev/null || true)}"

ORIG_MAAS_HOST="${MAAS_HOST}"

[ -z "$TAR_FILE" ] && { echo "Usage: $0 <tar.gz>"; exit 1; }
[ ! -f "$TAR_FILE" ] && { echo "File not found: $TAR_FILE"; exit 1; }

if [ -n "$JUMP_HOST" ]; then echo "Mode: jump ${SSH_USER}@${JUMP_HOST} -> ${MAAS_HOST}"; else echo "Mode: direct ${MAAS_HOST}"; fi

_MAAS_URL="http://${MAAS_HOST}:${MAAS_PORT}/MAAS/api/2.0/"
if [ -n "$JUMP_HOST" ]; then
  echo "Tunnel: localhost:${LOCAL_MAAS_PORT} -> ${MAAS_HOST}:${MAAS_PORT} via ${JUMP_HOST} ..."
  lsof -ti:${LOCAL_MAAS_PORT} 2>/dev/null | xargs kill 2>/dev/null || true; sleep 1
  if [ -n "$MAAS_SSH_PASS" ]; then sshpass -p "${MAAS_SSH_PASS}" ssh -L ${LOCAL_MAAS_PORT}:${MAAS_HOST}:${MAAS_PORT} -N -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes ${SSH_USER}@${JUMP_HOST} &
  else ssh -L ${LOCAL_MAAS_PORT}:${MAAS_HOST}:${MAAS_PORT} -N -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes -o BatchMode=yes ${SSH_USER}@${JUMP_HOST} & fi
  _TUNNEL_PID=$!; sleep 2
trap "kill \${_TUNNEL_PID:-} 2>/dev/null || true" EXIT SIGTERM SIGINT
  kill -0 $_TUNNEL_PID 2>/dev/null || { echo "Tunnel failed"; exit 1; }
  _MAAS_URL="http://127.0.0.1:${LOCAL_MAAS_PORT}/MAAS/api/2.0/"
  echo "Tunnel ready (PID: $_TUNNEL_PID)"
fi

if ! command -v maas &>/dev/null; then add-apt-repository -y ppa:maas/3.7; sed -i 's/jammy/noble/' /etc/apt/sources.list.d/maas-ubuntu-3_7-jammy.list; apt update; apt install -y maas-cli; fi
maas logout admin 2>/dev/null || true
maas login admin "$_MAAS_URL" "$MAAS_APIKEY"

IMG_NAME=$(basename "$TAR_FILE" .tar.gz)
ARCH=$(echo "$IMG_NAME" | cut -d- -f1)
echo "Upload custom/${IMG_NAME} ..."
maas admin boot-resources create name="custom/${IMG_NAME}" title="${IMG_NAME}" architecture="${ARCH}/generic" filetype='tgz' content@="$TAR_FILE"

sudo rm -f "$TAR_FILE"; sudo mkdir -p /home/ubuntu/custom-ubuntu-img
echo "$IMG_NAME" | sudo tee -a /home/ubuntu/custom-ubuntu-img/image.txt > /dev/null
echo "Sync image.txt to MAAS host ..."
if [ -n "$JUMP_HOST" ]; then
  if [ -n "$MAAS_SSH_PASS" ]; then sshpass -p "${MAAS_SSH_PASS}" ssh ${SSH_USER}@${JUMP_HOST} "ssh ${SSH_USER}@${ORIG_MAAS_HOST} \"mkdir -p /home/ubuntu/custom-ubuntu-img && echo '${IMG_NAME}' | tee -a /home/ubuntu/custom-ubuntu-img/image.txt\""
  else ssh -J ${SSH_USER}@${JUMP_HOST} ${SSH_USER}@${ORIG_MAAS_HOST} "mkdir -p /home/ubuntu/custom-ubuntu-img && echo '${IMG_NAME}' | tee -a /home/ubuntu/custom-ubuntu-img/image.txt"; fi
else
  if [ -n "$MAAS_SSH_PASS" ]; then sshpass -p "${MAAS_SSH_PASS}" ssh ${SSH_USER}@${ORIG_MAAS_HOST} "mkdir -p /home/ubuntu/custom-ubuntu-img && echo '${IMG_NAME}' | tee -a /home/ubuntu/custom-ubuntu-img/image.txt"
  else ssh ${SSH_USER}@${ORIG_MAAS_HOST} "mkdir -p /home/ubuntu/custom-ubuntu-img && echo '${IMG_NAME}' | tee -a /home/ubuntu/custom-ubuntu-img/image.txt"; fi
fi
echo "Done: custom/${IMG_NAME}"
kill ${_TUNNEL_PID:-} 2>/dev/null || true


