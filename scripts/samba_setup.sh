#!/usr/bin/env bash
set -euo pipefail

STORAGE_ROOT="${1:-/mnt/media_storage}"
SMB_USER="${SMB_USER:-pandavault}"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "请用 root 运行（或 sudo）: sudo $0 ${STORAGE_ROOT}"
    exit 1
  fi
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  else
    echo "unknown"
  fi
}

install_samba() {
  local pmgr
  pmgr="$(detect_pkg_mgr)"
  case "$pmgr" in
    apt)
      apt-get update -y
      apt-get install -y samba
      ;;
    yum)
      yum install -y samba samba-common samba-common-tools
      ;;
    dnf)
      dnf install -y samba samba-common samba-common-tools
      ;;
    *)
      echo "未识别包管理器，请手动安装 samba"
      exit 2
      ;;
  esac
}

ensure_dirs() {
  mkdir -p "${STORAGE_ROOT}/raw" "${STORAGE_ROOT}/proxies" "${STORAGE_ROOT}/.temp"
  chmod 2775 "${STORAGE_ROOT}/raw" "${STORAGE_ROOT}/proxies" "${STORAGE_ROOT}/.temp" || true
}

ensure_user() {
  if id "${SMB_USER}" >/dev/null 2>&1; then
    echo "系统用户已存在: ${SMB_USER}"
  else
    useradd -m -s /usr/sbin/nologin "${SMB_USER}"
    echo "已创建系统用户: ${SMB_USER}"
  fi
}

print_next_steps() {
  cat <<EOF

=== 下一步（请按顺序执行）===

1) 复制配置（仓库里的模板）到 /etc/samba/smb.conf：
   cp -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/samba/smb.conf" /etc/samba/smb.conf

   然后把 smb.conf 里的：
     valid users = pandavault
   改成：
     valid users = ${SMB_USER}

2) 设置 Samba 密码（交互式）：
   smbpasswd -a ${SMB_USER}

3) 让共享目录对 ${SMB_USER} 可写（两种选一）：
   A. 推荐：把目录属主改成 ${SMB_USER}（Docker 也建议以同 UID/GID 跑）
      chown -R ${SMB_USER}:${SMB_USER} "${STORAGE_ROOT}/raw" "${STORAGE_ROOT}/proxies" "${STORAGE_ROOT}/.temp"

   B. 快速测试：给目录组写权限并加 ACL（适合多人/不改属主）
      chmod -R g+rwX "${STORAGE_ROOT}/raw" "${STORAGE_ROOT}/proxies" "${STORAGE_ROOT}/.temp"

4) 启动并设置开机自启（不同发行版服务名可能不同，按实际报错调整）：
   systemctl enable --now smbd nmbd 2>/dev/null || true
   systemctl enable --now smb nmb 2>/dev/null || true

5) 防火墙（如启用 ufw）放行 445：
   ufw allow 445/tcp 2>/dev/null || true

=== 客户端连接测试 ===
- macOS：Finder -> 前往 -> 连接服务器 -> 输入：
    smb://<服务器IP>/RawMaterials
  账号/密码：${SMB_USER} / 你在 smbpasswd 设置的密码

- Windows：资源管理器地址栏输入：
    \\\\<服务器IP>\\RawMaterials

EOF
}

need_root
echo "准备安装 Samba + 创建目录：${STORAGE_ROOT}"
install_samba
ensure_dirs
ensure_user
print_next_steps



