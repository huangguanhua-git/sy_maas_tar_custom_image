#!/bin/bash
set -euo pipefail
#set -x

DATE_TAG=$(date +%Y%m%d)
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
OS_VER=$( (lsb_release -rs 2>/dev/null || grep -oP '(?<=VERSION_ID=")[^"]+' /etc/os-release) | tr -d '.')

# IP 后两段，防多机器冲突
IP_SUFFIX=$(ip -4 route get 1 | awk '{print $7; exit}' | awk -F. '{print $(NF-1)"-"$NF}')
[ -z "$IP_SUFFIX" ] && IP_SUFFIX="unknown"

OUTPUT_FILE="/tmp/${ARCH}-ubuntu${OS_VER}-${DATE_TAG}-ip${IP_SUFFIX}.tar.gz"
BACKUP_DIR="/root/system-backup-${DATE_TAG}"
PACKAGE_DONE=false

[ "$(id -u)" -ne 0 ] && { echo "需要 root 权限"; exit 1; }

cleanup() {
 if [ "$PACKAGE_DONE" = true ]; then
 echo "还原配置..."
 else
 echo -e "\n中断，还原配置..."
 fi
 cp "${BACKUP_DIR}/machine-id" /etc/machine-id 2>/dev/null || true
 cp "${BACKUP_DIR}/dbus-machine-id" /var/lib/dbus/machine-id 2>/dev/null || true
 for k in "${BACKUP_DIR}"/ssh_host_*; do [ -f "$k" ] && cp -ra "$k" /etc/ssh/; done
 [ -d "${BACKUP_DIR}/grub.d" ] && cp -a "${BACKUP_DIR}/grub.d"/* /etc/default/grub.d/ 2>/dev/null || true
 [ "$PACKAGE_DONE" = false ] && echo "配置已还原"
 return 0
}
trap cleanup EXIT

echo "输出: ${OUTPUT_FILE}"
#配置apt源
CODENAME=$(lsb_release -cs 2>/dev/null || grep -oP '(?<=VERSION_CODENAME=)\S+' /etc/os-release)
IP_SELF=$(ip -4 route get 1 | awk '{print $7; exit}')
if echo "$IP_SELF" | grep -qE '^10\.1\.([58]\.)'; then
	  # 10.1.8.x / 10.1.5.x → 清华源，不用代理
mv /etc/apt/sources.list /etc/apt/sources.list.bak || true
cat > /etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
EOF
cat > /etc/apt/apt.conf.d/02proxy <<'EOF'
Acquire::http::Proxy "http://10.10.249.98:31420";
Acquire::https::Proxy "http://10.10.249.98:31420";
EOF
mv /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak || true
else
# 其他网段
mv /etc/apt/sources.list /etc/apt/sources.list.bak || true
cat > /etc/apt/sources.list <<EOF
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${CODENAME} main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${CODENAME}-security main restricted universe multiverse
EOF
fi
apt update
#删除之前的测试镜像
rm -f /tmp/amd64-ubuntu*

# 指定默认启动内核（持久化）
# 用法: sudo ./set-kernel.sh [内核版本]
# 示例: sudo ./set-kernel.sh 5.15.0-185-generic

TARGET_KERNEL="${1:-$(uname -r)}"

[[ $EUID -ne 0 ]] && { echo "请用 sudo 运行"; exit 1; }

# 查找内核对应的菜单项标题
MENU_ENTRY=$(grep -E "menuentry.*${TARGET_KERNEL}" /boot/grub/grub.cfg | grep -v "recovery" | head -1 | cut -d"'" -f2)
[[ -z "$MENU_ENTRY" ]] && { echo "未找到内核 ${TARGET_KERNEL} 对应的 GRUB 菜单项"; exit 1; }

if grep -q "submenu.*Advanced options for Ubuntu" /boot/grub/grub.cfg 2>/dev/null; then
	      GRUB_ENTRY="Advanced options for Ubuntu>${MENU_ENTRY}"
	  else
	  GRUB_ENTRY="${MENU_ENTRY}"
fi

echo ">>> 使用菜单项: $GRUB_ENTRY"

cp /etc/default/grub /etc/default/grub.bak.$(date +%Y%m%d)
sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${GRUB_ENTRY}\"|" /etc/default/grub
update-grub

echo "默认内核已设为: $TARGET_KERNEL，重启生效。"

echo "禁用dkms的autoinstall功能"
sudo touch /etc/dkms/no-autoinstall
##只保留当前运行内核,只卸载已安装的
#dpkg -l linux-image\* linux-headers\* linux-module\* linux-generic 2>/dev/null | grep -v "$(uname -r)" | grep ii | awk '{print$2}' | xargs -r dpkg --purge --force-all || true
##只保留当前运行内核,卸载非un状态的包
KV=$(uname -r | sed 's/-generic//')
apt -y install linux-headers-${KV}
dpkg -l linux-image\* linux-headers\* linux-module\* linux-generic 2>/dev/null | grep -v "${KV}" | grep -v "^un" | awk '{print$2}' |grep ^linux|xargs -r dpkg --purge --force-all || true
update-grub
# ========== 备份 ==========
mkdir -p "$BACKUP_DIR"
cp -a --remove-destination /etc/machine-id "${BACKUP_DIR}/" 2>/dev/null || true
cp -a --remove-destination /var/lib/dbus/machine-id "${BACKUP_DIR}/" 2>/dev/null || true
for k in /etc/ssh/ssh_host_*; do [ -f "$k" ] && cp -ra "$k" "$BACKUP_DIR/"; done
[ -d /etc/default/grub.d ] && cp -a /etc/default/grub.d "${BACKUP_DIR}/"

# ========== 清理 cloud-init ==========
apt purge -y cloud-init cloud-initramfs-growroot
apt autoremove -y
rm -rf /etc/cloud /var/lib/cloud /var/log/cloud-init*
apt update
apt install -y cloud-init cloud-initramfs-growroot pigz jq debconf-utils

sudo tee /tmp/cloud-init-base.templates >/dev/null <<'EOF'
Template: cloud-init-base/datasources
Type: multiselect
Description: Fake datasource entry

Template: cloud-init-base/maas-metadata-url
Type: string
Description: Fake MAAS metadata URL

Template: cloud-init-base/maas-metadata-credentials
Type: string
Description: Fake MAAS credentials

Template: cloud-init-base/local-cloud-config
Type: string
Description: Fake local config
EOF

debconf-loadtemplate cloud-init-base /tmp/cloud-init-base.templates 2>/dev/null || true

# ========== 重置 ==========
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*
cloud-init clean --logs || true
rm -rf /var/lib/cloud/*
apt clean

# ========== 打包 ==========
EXCLUDES=(./proc/* ./sys/* ./dev/* ./run/* ./tmp/* ./mnt/* ./media/* ./lost+found
 ./swap.img ./var/tmp/* ./var/log/journal/* ./var/cache/apt/archives/* ./var/lib/cloud/* ./etc/netplan/* ./home/ubuntu/package-ubuntu.sh)
[ -f /etc/default/grub.d/50-curtin-settings.cfg ] && EXCLUDES+=(./etc/default/grub.d/*) && echo "排除 grub.d"

EXCLUDE_ARGS=(); for p in "${EXCLUDES[@]}"; do EXCLUDE_ARGS+=(--exclude="$p"); done

cd /
C=$(nproc); [ "$C" -gt 16 ] && C=16
echo "正在打包 (pigz ${C}线程)..."
tar --xattrs --acls --selinux --numeric-owner --one-file-system -cp \
 --warning=no-file-changed --warning=no-file-removed \
 "${EXCLUDE_ARGS[@]}" . /usr/local | pigz -p "$C" > "$OUTPUT_FILE" || true

PACKAGE_DONE=true
echo "$OUTPUT_FILE" > /tmp/.last-package-path
echo "完成！输出: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo "备份保留在: ${BACKUP_DIR}/ (确认无误后可删除)"

# ========== GPU 信息采集 ==========
echo " ============================== GPU 信息采集 ============================================="
na() { [ -z "$1" ] && echo "NA" || echo "$1"; }
OS=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"' || :)
KERN=$(uname -r)
MOD=$(lsmod 2>/dev/null | grep -E 'nvidia|nouveau|peer' | awk '{print $1}' | sort -u | paste -sd, || :)
DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || :)
FM=$(nv-fabricmanager -v|grep version|awk '{print$NF}' 2>/dev/null | grep -oP '[\d.]+' || :)
CUDA=$(/usr/local/cuda/bin/nvcc -V |grep release|awk '{print$5}'|cut -d, -f1 || :)
CTK=$(nvidia-ctk --version 2>/dev/null | head -1 || nvidia-container-runtime --version 2>/dev/null | head -1 || :)
DOCK=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || :)
SLURM=$(sinfo -V 2>/dev/null || scontrol --version 2>/dev/null || :)
FW=$(nvidia-smi -q 2>/dev/null | grep 'VBIOS Version' | awk -F': ' '{print $2}' | sort -u | paste -sd, || :)
OFED=$(ofed_info -s 2>/dev/null|cut -d: -f1 || :)
SSH=$(ss -tnlp 2>/dev/null | grep sshd | head -1 | awk '{print $4}' | rev | cut -d: -f1 | rev || :)
echo "系统及版本: $(na "$OS")"
echo "内核版本: $KERN"
echo "内核模块: $(na "$MOD")"
echo "驱动版本: $(na "$DRV")"
echo "OFED驱动版本: $(na "$OFED")"
echo "fabricmanager: $(na "$FM")"
echo "CUDA版本: $(na "$CUDA")"
echo "NVIDIA Container toolkit: $(na "$CTK")"
echo "docker-ce: $(na "$DOCK")"
echo "slurm: $(na "$SLURM")"
echo "GPU FW: $(na "$FW")"
echo "ssh端口: $(na "$SSH")"
echo " ========================================================================================="
rm -f -- "$0"
exit 0
