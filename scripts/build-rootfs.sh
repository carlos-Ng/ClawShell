#!/usr/bin/env bash
# build-rootfs.sh — 在 WSL2 内构建 ClawShell VM rootfs（支持断点续建）
#
# 用法：sudo ./build-rootfs.sh [选项] [输出文件]
#
#   选项：
#     --clean        清除所有 checkpoint，完全重新构建
#     --from N       从阶段 N 开始（丢弃 N 及之后的 checkpoint）
#     --list         列出已有 checkpoint 状态
#
#   示例：
#     sudo ./build-rootfs.sh                    # 自动断点续建
#     sudo ./build-rootfs.sh --clean            # 全新构建
#     sudo ./build-rootfs.sh --from 5           # 从阶段 5 重新开始
#     sudo ./build-rootfs.sh --list             # 查看哪些阶段已完成
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
OUTPUT="clawshell-rootfs.tar.gz"
NODE_MAJOR=22
CLAWSHELL_USER="clawshell"
MCP_INSTALL_DIR="/opt/clawshell/mcp"

# checkpoint 目录（持久存储，不在 /tmp 下）
CACHE_DIR="/var/cache/clawshell-build"

# ClawShell 源码目录（脚本所在位置的上级）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAWSHELL_SRC="$(dirname "$SCRIPT_DIR")"

TOTAL_STAGES=7

# ── 参数解析 ──────────────────────────────────────────────────────────────

CLEAN=false
FROM_STAGE=0
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)
            CLEAN=true
            shift
            ;;
        --from)
            FROM_STAGE="$2"
            shift 2
            ;;
        --list)
            LIST_ONLY=true
            shift
            ;;
        -*)
            echo "未知选项: $1" >&2
            exit 1
            ;;
        *)
            OUTPUT="$1"
            shift
            ;;
    esac
done

# ── 前置检查 ──────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo "错误：请以 root 运行（sudo $0）" >&2
    exit 1
fi

if ! command -v debootstrap &>/dev/null; then
    echo "正在安装 debootstrap..."
    apt-get update -qq && apt-get install -y -qq debootstrap
fi

mkdir -p "$CACHE_DIR"

# ── checkpoint 工具函数 ──────────────────────────────────────────────────

checkpoint_file() {
    echo "$CACHE_DIR/stage${1}.tar.gz"
}

has_checkpoint() {
    [[ -f "$(checkpoint_file "$1")" ]]
}

save_checkpoint() {
    local stage=$1
    echo "  ✓ 保存 checkpoint: stage $stage ..."
    # 先保存到临时文件，成功后再重命名（避免写一半断电/kill 导致损坏）
    tar -czf "$(checkpoint_file "$stage").tmp" -C "$ROOTFS_DIR" .
    mv "$(checkpoint_file "$stage").tmp" "$(checkpoint_file "$stage")"
    local size
    size=$(du -sh "$(checkpoint_file "$stage")" | cut -f1)
    echo "  ✓ checkpoint stage $stage 已保存 ($size)"
}

restore_checkpoint() {
    local stage=$1
    local ckpt
    ckpt="$(checkpoint_file "$stage")"
    echo "  ↻ 从 checkpoint stage $stage 恢复 ..."
    rm -rf "$ROOTFS_DIR"
    mkdir -p "$ROOTFS_DIR"
    tar -xzf "$ckpt" -C "$ROOTFS_DIR"
    echo "  ✓ 恢复完成"
}

list_checkpoints() {
    echo ""
    echo "ClawShell rootfs 构建 checkpoint 状态："
    echo "────────────────────────────────────────"
    local stage
    for stage in $(seq 1 $TOTAL_STAGES); do
        local ckpt
        ckpt="$(checkpoint_file "$stage")"
        if [[ -f "$ckpt" ]]; then
            local size ts
            size=$(du -sh "$ckpt" | cut -f1)
            ts=$(date -r "$ckpt" '+%Y-%m-%d %H:%M:%S')
            printf "  ✅ stage %d  %6s  %s\n" "$stage" "$size" "$ts"
        else
            printf "  ⬜ stage %d  (未构建)\n" "$stage"
        fi
    done
    echo ""
    echo "缓存目录: $CACHE_DIR"
    if ls "$CACHE_DIR"/stage*.tar.gz &>/dev/null; then
        echo "总缓存大小: $(du -sh "$CACHE_DIR" | cut -f1)"
    fi
    echo ""
}

# ── --list 模式 ──────────────────────────────────────────────────────────

if $LIST_ONLY; then
    list_checkpoints
    exit 0
fi

# ── --clean 模式 ─────────────────────────────────────────────────────────

if $CLEAN; then
    echo "清除所有 checkpoint ..."
    rm -f "$CACHE_DIR"/stage*.tar.gz
    rm -f "$CACHE_DIR"/stage*.tar.gz.tmp
fi

# ── --from N 模式 ────────────────────────────────────────────────────────

if [[ $FROM_STAGE -gt 0 ]]; then
    echo "从阶段 $FROM_STAGE 开始，删除 stage $FROM_STAGE 及之后的 checkpoint ..."
    for s in $(seq "$FROM_STAGE" $TOTAL_STAGES); do
        rm -f "$(checkpoint_file "$s")" "$(checkpoint_file "$s").tmp"
    done
fi

# ── 确定从哪个阶段开始 ──────────────────────────────────────────────────

find_resume_stage() {
    # 找到最后一个连续存在的 checkpoint
    local last=0
    for s in $(seq 1 $TOTAL_STAGES); do
        if has_checkpoint "$s"; then
            last=$s
        else
            break
        fi
    done
    echo $last
}

LAST_COMPLETED=$(find_resume_stage)

if [[ $LAST_COMPLETED -ge $TOTAL_STAGES ]]; then
    echo "所有阶段已完成，直接打包。"
    echo "如需重新构建，使用 --clean 或 --from N"
    restore_checkpoint $TOTAL_STAGES
    # 跳到打包步骤
    RESUME_FROM=$((TOTAL_STAGES + 1))
elif [[ $LAST_COMPLETED -gt 0 ]]; then
    echo ""
    echo "════════════════════════════════════════"
    echo " 检测到 checkpoint，从 stage $((LAST_COMPLETED + 1)) 继续"
    echo " (stage 1~$LAST_COMPLETED 已缓存，跳过)"
    echo "════════════════════════════════════════"
    echo ""
    restore_checkpoint $LAST_COMPLETED
    RESUME_FROM=$((LAST_COMPLETED + 1))
else
    echo "无 checkpoint，从头开始构建。"
    RESUME_FROM=1
fi

# ── 挂载/卸载 helper ─────────────────────────────────────────────────────

mount_vfs() {
    # 先卸载（防止重复挂载）
    umount "$ROOTFS_DIR/sys"  2>/dev/null || true
    umount "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount "$ROOTFS_DIR/dev"  2>/dev/null || true
    mount --bind /dev  "$ROOTFS_DIR/dev"
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys  "$ROOTFS_DIR/sys"
}

umount_vfs() {
    umount "$ROOTFS_DIR/sys"  2>/dev/null || true
    umount "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount "$ROOTFS_DIR/dev"  2>/dev/null || true
}

trap umount_vfs EXIT

# ── 运行阶段 helper ──────────────────────────────────────────────────────

# 执行某个阶段：如果 RESUME_FROM > stage，跳过；否则执行并保存 checkpoint
run_stage() {
    local stage=$1
    local name=$2
    if [[ $RESUME_FROM -gt $stage ]]; then
        echo "=== [${stage}/${TOTAL_STAGES}] ${name} === (已缓存，跳过)"
        return 0
    fi
    echo ""
    echo "=== [${stage}/${TOTAL_STAGES}] ${name} ==="
    echo ""
    return 1  # 表示需要执行
}

# ── 阶段 1：debootstrap 基础系统 ─────────────────────────────────────────

if ! run_stage 1 "debootstrap：创建 Debian $SUITE 基础系统"; then
    # 清理旧 rootfs
    if [[ -d "$ROOTFS_DIR" ]]; then
        rm -rf "$ROOTFS_DIR"
    fi

    debootstrap \
        --variant=minbase \
        --include=systemd,systemd-sysv,dbus,ca-certificates,curl,wget,gnupg,locales,procps,iproute2,iputils-ping,less,vim-tiny,sudo \
        "$SUITE" "$ROOTFS_DIR" "$MIRROR"

    echo "基础系统完成：$(du -sh "$ROOTFS_DIR" | cut -f1)"
    save_checkpoint 1
fi

# ── 阶段 2：基础系统配置 ─────────────────────────────────────────────────

if ! run_stage 2 "配置基础系统"; then
    mount_vfs

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

    umount_vfs
    save_checkpoint 2
fi

# ── 阶段 3：安装 Python 3 ────────────────────────────────────────────────

if ! run_stage 3 "安装 Python 3"; then
    mount_vfs
    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

    chroot "$ROOTFS_DIR" bash -c "
        apt-get update -qq
        apt-get install -y -qq python3 python3-pip python3-venv
        python3 --version
    "

    umount_vfs
    save_checkpoint 3
fi

# ── 阶段 4：安装 Node.js + pnpm ─────────────────────────────────────────

if ! run_stage 4 "安装 Node.js $NODE_MAJOR + pnpm"; then
    mount_vfs
    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

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

        # 配置 pnpm 全局目录
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

    umount_vfs
    save_checkpoint 4
fi

# ── 阶段 5：安装 OpenClaw ────────────────────────────────────────────────

if ! run_stage 5 "安装 OpenClaw"; then
    mount_vfs
    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

    chroot "$ROOTFS_DIR" bash -c "
        export PNPM_HOME=/usr/local/share/pnpm
        export PATH=\$PNPM_HOME:\$PATH

        # 用 pnpm 全局安装
        pnpm add -g openclaw@latest

        # 验证
        openclaw --version || echo 'openclaw installed (version check may need gateway)'
    "

    umount_vfs
    save_checkpoint 5
fi

# ── 阶段 6：部署 ClawShell MCP Server ────────────────────────────────────

if ! run_stage 6 "部署 ClawShell MCP Server"; then
    mount_vfs

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

    # OpenClaw mcpServers 配置
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

    umount_vfs
    save_checkpoint 6
fi

# ── 阶段 7：瘦身 ─────────────────────────────────────────────────────────

if ! run_stage 7 "清理瘦身"; then
    mount_vfs

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

    umount_vfs
    save_checkpoint 7
fi

# ── 打包 ─────────────────────────────────────────────────────────────────

# 如果 rootfs 目录不存在（所有阶段都跳过），从最终 checkpoint 恢复
if [[ ! -d "$ROOTFS_DIR" ]]; then
    restore_checkpoint $TOTAL_STAGES
fi

echo ""
echo "rootfs 大小：$(du -sh "$ROOTFS_DIR" | cut -f1)"

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
echo ""
echo " 管理 checkpoint："
echo "   sudo $0 --list           # 查看缓存"
echo "   sudo $0 --from 5         # 从阶段 5 重建"
echo "   sudo $0 --clean          # 清除所有缓存"
echo "=========================================="
