#!/usr/bin/env bash
# build-rootfs.sh — 在 WSL2 内构建 ClawShell VM rootfs
#
# 用法：sudo ./build-rootfs.sh [输出文件]
#
# 需要在现有 WSL2 distro 中以 root 运行。
# 生成的 tar.gz 可直接用于 wsl --import：
#   wsl --import ClawShell C:\ClawShell\vm clawshell-rootfs.tar.gz
#
# 依赖：debootstrap, tar, gzip (apt install debootstrap)

set -euo pipefail

# ── 配置 ─────────────────────────────────────────────────────────────────

SUITE="bookworm"
MIRROR="https://deb.debian.org/debian"
ROOTFS_DIR="/tmp/clawshell-rootfs"
OUTPUT="${1:-clawshell-rootfs.tar.gz}"
NODE_MAJOR=22
CLAWSHELL_USER="clawshell"
MCP_INSTALL_DIR="/opt/clawshell/mcp"

# ClawShell 源码目录（脚本所在位置的上级）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAWSHELL_SRC="$(dirname "$SCRIPT_DIR")"

# ── 前置检查 ─────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo "错误：请以 root 运行（sudo $0）" >&2
    exit 1
fi

if ! command -v debootstrap &>/dev/null; then
    echo "正在安装 debootstrap..."
    apt-get update -qq && apt-get install -y -qq debootstrap
fi

# ── 清理旧构建 ──────────────────────────────────────────────────────────

if [[ -d "$ROOTFS_DIR" ]]; then
    echo "清理旧 rootfs 目录..."
    rm -rf "$ROOTFS_DIR"
fi

# ── 阶段 1：debootstrap 基础系统 ────────────────────────────────────────

echo "=== [1/7] debootstrap：创建 Debian $SUITE 基础系统 ==="

debootstrap \
    --variant=minbase \
    --include=systemd,systemd-sysv,dbus,ca-certificates,curl,wget,gnupg,locales,procps,iproute2,iputils-ping,less,vim-tiny,sudo \
    "$SUITE" "$ROOTFS_DIR" "$MIRROR"

echo "基础系统完成：$(du -sh "$ROOTFS_DIR" | cut -f1)"

# ── 阶段 2：chroot 环境准备 ─────────────────────────────────────────────

echo "=== [2/7] 配置基础系统 ==="

# 挂载必要的虚拟文件系统
mount --bind /dev  "$ROOTFS_DIR/dev"
mount --bind /proc "$ROOTFS_DIR/proc"
mount --bind /sys  "$ROOTFS_DIR/sys"

# 退出时自动卸载
cleanup() {
    echo "清理挂载点..."
    umount "$ROOTFS_DIR/sys"  2>/dev/null || true
    umount "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount "$ROOTFS_DIR/dev"  2>/dev/null || true
}
trap cleanup EXIT

# DNS 解析
cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

# apt 源
cat > "$ROOTFS_DIR/etc/apt/sources.list" <<SOURCES
deb $MIRROR $SUITE main contrib
deb $MIRROR ${SUITE}-updates main contrib
deb http://security.debian.org/debian-security ${SUITE}-security main contrib
SOURCES

# locale
chroot "$ROOTFS_DIR" bash -c "
    sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen
"

# hostname
echo "clawshell" > "$ROOTFS_DIR/etc/hostname"

# ── 阶段 3：安装 Python 3 ──────────────────────────────────────────────

echo "=== [3/7] 安装 Python 3 ==="

chroot "$ROOTFS_DIR" bash -c "
    apt-get update -qq
    apt-get install -y -qq python3 python3-pip python3-venv
    python3 --version
"

# ── 阶段 4：安装 Node.js 22 + pnpm ─────────────────────────────────────

echo "=== [4/7] 安装 Node.js $NODE_MAJOR + pnpm ==="

chroot "$ROOTFS_DIR" bash -c "
    # nodesource GPG key + repo
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo \"deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main\" \
        > /etc/apt/sources.list.d/nodesource.list

    apt-get update -qq
    apt-get install -y -qq nodejs

    # 启用 corepack 获取 pnpm
    corepack enable
    corepack prepare pnpm@latest --activate

    # 配置 pnpm 全局目录（chroot 内无 shell profile，手动创建）
    export PNPM_HOME=/usr/local/share/pnpm
    mkdir -p \$PNPM_HOME

    # 写入系统级 profile，所有用户登录后自动生效
    cat > /etc/profile.d/pnpm.sh <<'PNPMSH'
export PNPM_HOME=/usr/local/share/pnpm
export PATH=\$PNPM_HOME:\$PATH
PNPMSH

    node --version
    pnpm --version
"

# ── 阶段 5：安装 OpenClaw ──────────────────────────────────────────────

echo "=== [5/7] 安装 OpenClaw ==="

chroot "$ROOTFS_DIR" bash -c "
    export PNPM_HOME=/usr/local/share/pnpm
    export PATH=\$PNPM_HOME:\$PATH

    # 用 pnpm 全局安装
    pnpm add -g openclaw@latest

    # 验证
    openclaw --version || echo 'openclaw installed (version check may need gateway)'
"

# ── 阶段 6：安装 ClawShell MCP Server ──────────────────────────────────

echo "=== [6/7] 部署 ClawShell MCP Server ==="

# 复制 MCP server 文件
mkdir -p "$ROOTFS_DIR$MCP_INSTALL_DIR"
cp "$CLAWSHELL_SRC/mcp/server/vsock_client.py" "$ROOTFS_DIR$MCP_INSTALL_DIR/"
cp "$CLAWSHELL_SRC/mcp/server/mcp_server.py"   "$ROOTFS_DIR$MCP_INSTALL_DIR/"

# 复制 OpenClaw skill
mkdir -p "$ROOTFS_DIR/opt/clawshell/skills/clawshell-gui"
cp "$CLAWSHELL_SRC/mcp/client/clawshell-gui/SKILL.md" \
   "$ROOTFS_DIR/opt/clawshell/skills/clawshell-gui/"

# 创建用户
chroot "$ROOTFS_DIR" bash -c "
    useradd -m -s /bin/bash -G sudo $CLAWSHELL_USER
    echo '$CLAWSHELL_USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$CLAWSHELL_USER
"

# MCP Server 由 OpenClaw acpx 按需以 stdio 子进程启动，不注册 systemd service。
# 配置在 ~/.openclaw/openclaw.json 的 mcpServers 中。

# OpenClaw mcpServers 配置骨架
OPENCLAW_CONF_DIR="$ROOTFS_DIR/home/$CLAWSHELL_USER/.openclaw"
mkdir -p "$OPENCLAW_CONF_DIR"
cat > "$OPENCLAW_CONF_DIR/openclaw.json" <<CONF
{
  "plugins": {
    "acpx": {
      "mcpServers": {
        "clawshell-gui": {
          "command": "python3",
          "args": ["$MCP_INSTALL_DIR/mcp_server.py"]
        }
      }
    }
  },
  "skills": {
    "load": {
      "extraDirs": ["/opt/clawshell/skills"]
    }
  }
}
CONF

chroot "$ROOTFS_DIR" chown -R "$CLAWSHELL_USER:$CLAWSHELL_USER" "/home/$CLAWSHELL_USER/.openclaw"

# WSL 默认用户配置
cat > "$ROOTFS_DIR/etc/wsl.conf" <<WSL
[user]
default=$CLAWSHELL_USER

[boot]
systemd=true

[network]
generateResolvConf=true
WSL

# ── 阶段 7：瘦身 + 打包 ────────────────────────────────────────────────

echo "=== [7/7] 清理 + 打包 ==="

chroot "$ROOTFS_DIR" bash -c "
    export PNPM_HOME=/usr/local/share/pnpm
    export PATH=\$PNPM_HOME:\$PATH

    # 清理 apt 缓存
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    # 清理 pip 缓存
    rm -rf /root/.cache/pip /home/$CLAWSHELL_USER/.cache/pip

    # 清理 pnpm store 缓存
    pnpm store prune 2>/dev/null || true

    # 清理文档和 man pages
    rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
    rm -rf /usr/share/locale/!(en|en_US|locale.alias)

    # 清理日志
    find /var/log -type f -delete

    # 清理 __pycache__
    find / -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

    # 清理临时文件
    rm -rf /tmp/* /var/tmp/*
"

echo "rootfs 大小：$(du -sh "$ROOTFS_DIR" | cut -f1)"

# 打包（从 rootfs 目录内部 tar，避免顶层多一层目录）
echo "正在打包 $OUTPUT ..."
tar -czf "$OUTPUT" -C "$ROOTFS_DIR" .

echo ""
echo "=========================================="
echo " 构建完成！"
echo " 输出：$OUTPUT ($(du -sh "$OUTPUT" | cut -f1))"
echo " rootfs：$(du -sh "$ROOTFS_DIR" | cut -f1)"
echo ""
echo " 导入 WSL2："
echo "   wsl --import ClawShell C:\\ClawShell\\vm $OUTPUT"
echo ""
echo " 启动："
echo "   wsl -d ClawShell"
echo "=========================================="
