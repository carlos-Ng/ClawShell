#!/usr/bin/env bash
# build-rootfs.sh — 在 WSL2 内构建 ClawShell VM rootfs（支持断点续建 + 下载缓存）
#
# 用法：sudo ./build-rootfs.sh [选项] [输出文件]
#
#   选项：
#     --src DIR      ClawShell 源码目录（含 mcp/、scripts/ 等）
#     --clean        清除所有 checkpoint，完全重新构建
#     --from N       从阶段 N 开始（丢弃 N 及之后的 checkpoint）
#     --list         列出已有 checkpoint 状态
#     --purge-cache  清除下载缓存（deb 包、debootstrap tarball）
#
#   示例：
#     sudo ./build-rootfs.sh                    # 自动断点续建
#     sudo ./build-rootfs.sh --src /mnt/c/Users/me/ClawShell  # 指定源码目录
#     sudo ./build-rootfs.sh --clean            # 全新构建（保留下载缓存）
#     sudo ./build-rootfs.sh --from 5           # 从阶段 5 重新开始
#     sudo ./build-rootfs.sh --list             # 查看哪些阶段已完成
#     sudo ./build-rootfs.sh --purge-cache      # 清除下载缓存
#
# 网络不稳定？放心：
#   - debootstrap 的 deb 包会先下载到本地缓存，断了重跑自动续传
#   - apt-get install 的 deb 包也有持久缓存，不会重复下载
#   - 每个阶段完成后保存 checkpoint，下次跑直接跳过
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
OUTPUT="$CACHE_DIR/clawshell-rootfs.tar.gz"
NODE_MAJOR=22
CLAWSHELL_USER="clawshell"
MCP_INSTALL_DIR="/opt/clawshell/mcp"

# 持久缓存目录（不在 /tmp 下，重启后仍保留）
CACHE_DIR="/var/cache/clawshell-build"
APT_CACHE_DIR="$CACHE_DIR/apt-archives"       # deb 包持久缓存
DEB_TARBALL="$CACHE_DIR/debootstrap-debs.tar"  # debootstrap 预下载 tarball

# debootstrap 的 --include 包列表（下载和安装都要用，提取为变量）
DEBOOTSTRAP_INCLUDE="systemd,systemd-sysv,dbus,ca-certificates,curl,wget,gnupg,git,locales,procps,iproute2,iputils-ping,less,vim-tiny,sudo"

# ClawShell 源码目录（默认从脚本位置推导，可通过 --src 覆盖）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAWSHELL_SRC=""  # 由参数解析或自动检测填充

TOTAL_STAGES=7

# ── 参数解析 ──────────────────────────────────────────────────────────────

CLEAN=false
FROM_STAGE=0
LIST_ONLY=false
PURGE_CACHE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)
            CLAWSHELL_SRC="$2"
            shift 2
            ;;
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
        --purge-cache)
            PURGE_CACHE=true
            shift
            ;;
        -*)
            echo "未知选项: $1" >&2
            exit 1
            ;;
        *)
            OUTPUT="$(cd "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1")"
            shift
            ;;
    esac
done

# ── 快速模式（不需要 preflight 的操作）────────────────────────────────────

# --list 只读缓存状态，不需要完整检查
if $LIST_ONLY; then
    mkdir -p "$CACHE_DIR" "$APT_CACHE_DIR"
    list_checkpoints
    exit 0
fi

# --purge-cache 只清缓存，不需要完整检查
if $PURGE_CACHE; then
    echo "清除下载缓存 ..."
    rm -f "$DEB_TARBALL"
    rm -rf "$APT_CACHE_DIR"
    mkdir -p "$APT_CACHE_DIR"
    echo "下载缓存已清除。"
    echo "(checkpoint 未清除，如需清除请加 --clean)"
    exit 0
fi

# ── 前置检查（Preflight） ─────────────────────────────────────────────────
#
# 在真正开始构建之前，统一检查所有依赖项：
#   1. 运行权限（root）
#   2. 宿主机必备工具
#   3. ClawShell 源码目录及关键文件
#   4. 磁盘空间
# 检查失败会一次性列出所有问题，而不是跑到一半才报错。

echo ""
echo "══════════════════════════════════════════"
echo " Preflight 检查"
echo "══════════════════════════════════════════"
echo ""

PREFLIGHT_ERRORS=()
PREFLIGHT_WARNINGS=()

# ── 1. 权限检查 ──────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo "  ✗ 需要 root 权限" >&2
    echo "" >&2
    echo "请使用：sudo $0 $*" >&2
    exit 1
fi
echo "  ✓ root 权限"

# ── 2. 宿主机工具检查 ────────────────────────────────────────────────────

# 必备工具：不可缺少，构建无法继续
REQUIRED_TOOLS=(
    "debootstrap:创建 Debian 基础系统:debootstrap"
    "tar:打包/解包 rootfs 和 checkpoint:tar"
    "gzip:压缩/解压 tarball:gzip"
    "mount:挂载虚拟文件系统到 chroot:mount"
    "umount:卸载虚拟文件系统:umount"
    "chroot:在 rootfs 内执行命令:coreutils"
)

MISSING_TOOLS=()
AUTO_INSTALL_PKGS=()

for entry in "${REQUIRED_TOOLS[@]}"; do
    IFS=: read -r cmd purpose pkg <<< "$entry"
    if command -v "$cmd" &>/dev/null; then
        echo "  ✓ $cmd"
    else
        echo "  ✗ $cmd — $purpose"
        MISSING_TOOLS+=("$cmd")
        AUTO_INSTALL_PKGS+=("$pkg")
    fi
done

# 尝试自动安装缺失的工具
if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    echo ""
    echo "  缺少 ${#MISSING_TOOLS[@]} 个工具，尝试自动安装: ${AUTO_INSTALL_PKGS[*]}"

    # 去重
    UNIQUE_PKGS=($(printf '%s\n' "${AUTO_INSTALL_PKGS[@]}" | sort -u))

    if apt-get update -qq 2>/dev/null && apt-get install -y -qq "${UNIQUE_PKGS[@]}" 2>/dev/null; then
        echo ""
        # 重新验证
        STILL_MISSING=()
        for cmd in "${MISSING_TOOLS[@]}"; do
            if command -v "$cmd" &>/dev/null; then
                echo "  ✓ $cmd (已自动安装)"
            else
                STILL_MISSING+=("$cmd")
            fi
        done

        if [[ ${#STILL_MISSING[@]} -gt 0 ]]; then
            PREFLIGHT_ERRORS+=("以下工具安装失败: ${STILL_MISSING[*]}")
        fi
    else
        PREFLIGHT_ERRORS+=("自动安装失败，请手动安装: apt-get install ${UNIQUE_PKGS[*]}")
    fi
fi

# ── 3. ClawShell 源码目录检查 ────────────────────────────────────────────

if [[ -z "$CLAWSHELL_SRC" ]]; then
    # 自动检测：脚本所在目录的上级
    _auto="$(dirname "$SCRIPT_DIR")"
    if [[ -f "$_auto/mcp/server/mcp_server.py" ]]; then
        CLAWSHELL_SRC="$_auto"
    fi
fi

# 如果自动检测失败，尝试常见的 Windows 挂载路径
if [[ -z "$CLAWSHELL_SRC" || ! -f "$CLAWSHELL_SRC/mcp/server/mcp_server.py" ]]; then
    for _try in \
        /mnt/c/Users/*/ClawShell \
        /mnt/d/ClawShell \
        /mnt/c/ClawShell; do
        # shellcheck disable=SC2086
        for _dir in $_try; do
            if [[ -f "$_dir/mcp/server/mcp_server.py" ]]; then
                CLAWSHELL_SRC="$_dir"
                break 2
            fi
        done
    done
fi

if [[ -z "$CLAWSHELL_SRC" || ! -d "$CLAWSHELL_SRC" ]]; then
    echo "  ✗ ClawShell 源码目录未找到"
    PREFLIGHT_ERRORS+=("无法定位 ClawShell 源码目录，请使用 --src 指定: sudo $0 --src /mnt/c/Users/你的用户名/ClawShell")
else
    echo "  ✓ 源码目录: $CLAWSHELL_SRC"

    # 检查源码目录中的关键文件
    SRC_FILES=(
        "mcp/server/mcp_server.py:MCP Server 入口"
        "mcp/server/vsock_client.py:VsockClient"
        "mcp/client/clawshell-gui/SKILL.md:OpenClaw Skill 定义"
    )

    for entry in "${SRC_FILES[@]}"; do
        IFS=: read -r fpath desc <<< "$entry"
        if [[ -f "$CLAWSHELL_SRC/$fpath" ]]; then
            echo "  ✓ $fpath"
        else
            echo "  ✗ $fpath — $desc"
            PREFLIGHT_ERRORS+=("源码文件缺失: $CLAWSHELL_SRC/$fpath ($desc)")
        fi
    done
fi

# ── 4. 磁盘空间检查 ──────────────────────────────────────────────────────

# rootfs 在 /tmp，checkpoint 在 /var/cache，分别检查
check_disk_space() {
    local path=$1
    local need_gb=$2
    local label=$3
    local avail_kb
    avail_kb=$(df --output=avail "$path" 2>/dev/null | tail -1)
    if [[ -n "$avail_kb" ]]; then
        local avail_gb=$(( avail_kb / 1024 / 1024 ))
        if [[ $avail_gb -lt $need_gb ]]; then
            echo "  ⚠ $label: ${avail_gb}GB 可用，建议至少 ${need_gb}GB"
            PREFLIGHT_WARNINGS+=("$label 磁盘空间不足: 可用 ${avail_gb}GB, 建议 ${need_gb}GB")
        else
            echo "  ✓ $label: ${avail_gb}GB 可用"
        fi
    fi
}

check_disk_space "/tmp" 3 "rootfs 工作区 (/tmp)"
check_disk_space "$CACHE_DIR" 4 "checkpoint 缓存 ($CACHE_DIR)"

# ── 5. 网络连通性（仅警告） ──────────────────────────────────────────────

if curl -sf --max-time 5 -o /dev/null "$MIRROR/dists/$SUITE/Release" 2>/dev/null; then
    echo "  ✓ 网络: Debian 镜像可达"
elif wget -q --timeout=5 --spider "$MIRROR/dists/$SUITE/Release" 2>/dev/null; then
    echo "  ✓ 网络: Debian 镜像可达"
else
    echo "  ⚠ 网络: 无法连接 Debian 镜像 ($MIRROR)"
    if [[ -f "$DEB_TARBALL" ]]; then
        echo "    (已有本地 debootstrap 缓存，stage 1 可离线安装)"
    else
        PREFLIGHT_WARNINGS+=("网络不可用且无本地缓存，stage 1 将无法下载 deb 包")
    fi
fi

# ── Preflight 结果 ───────────────────────────────────────────────────────

echo ""

if [[ ${#PREFLIGHT_WARNINGS[@]} -gt 0 ]]; then
    echo "⚠ 警告 (${#PREFLIGHT_WARNINGS[@]}):"
    for w in "${PREFLIGHT_WARNINGS[@]}"; do
        echo "  - $w"
    done
    echo ""
fi

if [[ ${#PREFLIGHT_ERRORS[@]} -gt 0 ]]; then
    echo "✗ 发现 ${#PREFLIGHT_ERRORS[@]} 个错误，无法继续：" >&2
    for e in "${PREFLIGHT_ERRORS[@]}"; do
        echo "  - $e" >&2
    done
    echo "" >&2
    exit 1
fi

echo "✓ Preflight 通过"
echo ""

mkdir -p "$CACHE_DIR" "$APT_CACHE_DIR"

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
    echo "ClawShell rootfs 构建状态："
    echo "────────────────────────────────────────"

    # checkpoint 状态
    echo ""
    echo "  阶段 checkpoint："
    local stage
    for stage in $(seq 1 $TOTAL_STAGES); do
        local ckpt
        ckpt="$(checkpoint_file "$stage")"
        if [[ -f "$ckpt" ]]; then
            local size ts
            size=$(du -sh "$ckpt" | cut -f1)
            ts=$(date -r "$ckpt" '+%Y-%m-%d %H:%M:%S')
            printf "    ✅ stage %d  %6s  %s\n" "$stage" "$size" "$ts"
        else
            printf "    ⬜ stage %d  (未构建)\n" "$stage"
        fi
    done

    # 下载缓存状态
    echo ""
    echo "  下载缓存："
    if [[ -f "$DEB_TARBALL" ]]; then
        local deb_size
        deb_size=$(du -sh "$DEB_TARBALL" | cut -f1)
        printf "    📦 debootstrap tarball  %s\n" "$deb_size"
    else
        printf "    ⬜ debootstrap tarball  (未下载)\n"
    fi

    local apt_count
    apt_count=$(find "$APT_CACHE_DIR" -name '*.deb' 2>/dev/null | wc -l)
    if [[ $apt_count -gt 0 ]]; then
        local apt_size
        apt_size=$(du -sh "$APT_CACHE_DIR" | cut -f1)
        printf "    📦 apt deb 缓存        %s (%d 个包)\n" "$apt_size" "$apt_count"
    else
        printf "    ⬜ apt deb 缓存        (空)\n"
    fi

    echo ""
    echo "  缓存目录: $CACHE_DIR"
    echo "  总大小: $(du -sh "$CACHE_DIR" | cut -f1)"
    echo ""
}

# ── apt 缓存 helper ──────────────────────────────────────────────────────

# 将持久缓存目录 bind-mount 到 chroot 内的 apt archives
mount_apt_cache() {
    mkdir -p "$ROOTFS_DIR/var/cache/apt/archives/partial"
    mount --bind "$APT_CACHE_DIR" "$ROOTFS_DIR/var/cache/apt/archives"
}

umount_apt_cache() {
    umount "$ROOTFS_DIR/var/cache/apt/archives" 2>/dev/null || true
}

# ── --clean 模式 ─────────────────────────────────────────────────────────

if $CLEAN; then
    echo "清除所有 checkpoint ..."
    rm -f "$CACHE_DIR"/stage*.tar.gz
    rm -f "$CACHE_DIR"/stage*.tar.gz.tmp
    echo "(下载缓存保留，如需清除请用 --purge-cache)"
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
    umount "$ROOTFS_DIR/sys"  2>/dev/null || true
    umount "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount "$ROOTFS_DIR/dev"  2>/dev/null || true
    mount --bind /dev  "$ROOTFS_DIR/dev"
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys  "$ROOTFS_DIR/sys"
}

umount_vfs() {
    umount_apt_cache
    umount "$ROOTFS_DIR/sys"  2>/dev/null || true
    umount "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount "$ROOTFS_DIR/dev"  2>/dev/null || true
}

trap umount_vfs EXIT

# ── 运行阶段 helper ──────────────────────────────────────────────────────

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
    return 1
}

# ── 阶段 1：debootstrap（分下载+安装两步） ────────────────────────────────

if ! run_stage 1 "debootstrap：创建 Debian $SUITE 基础系统"; then

    # ── 1a：预下载所有 deb 包到本地 tarball ──────────────────────────────
    #
    # debootstrap --make-tarball 只下载不安装，生成的 tarball 可重复使用。
    # 如果 tarball 已存在（上次下载成功），直接跳过。
    # 如果下载中断了，tarball 不存在，重跑会重新下载。

    if [[ -f "$DEB_TARBALL" ]]; then
        echo "  ✓ debootstrap deb tarball 已存在，跳过下载"
        echo "    ($DEB_TARBALL, $(du -sh "$DEB_TARBALL" | cut -f1))"
    else
        echo "  ↓ 预下载 debootstrap deb 包 ..."
        echo "    (下载到 $DEB_TARBALL)"

        # --make-tarball 需要一个临时目标目录，不会真正安装
        DOWNLOAD_TMP="/tmp/clawshell-debootstrap-download"
        rm -rf "$DOWNLOAD_TMP"
        mkdir -p "$DOWNLOAD_TMP"

        debootstrap \
            --make-tarball="$DEB_TARBALL" \
            --variant=minbase \
            --include="$DEBOOTSTRAP_INCLUDE" \
            "$SUITE" "$DOWNLOAD_TMP" "$MIRROR"

        rm -rf "$DOWNLOAD_TMP"
        echo "  ✓ deb 包下载完成 ($(du -sh "$DEB_TARBALL" | cut -f1))"
    fi

    # ── 1b：从本地 tarball 离线安装 ──────────────────────────────────────

    echo "  ⚙ 从本地 tarball 安装基础系统（离线，无需网络）..."

    if [[ -d "$ROOTFS_DIR" ]]; then
        rm -rf "$ROOTFS_DIR"
    fi

    debootstrap \
        --unpack-tarball="$DEB_TARBALL" \
        --variant=minbase \
        --include="$DEBOOTSTRAP_INCLUDE" \
        "$SUITE" "$ROOTFS_DIR"

    echo "基础系统完成：$(du -sh "$ROOTFS_DIR" | cut -f1)"
    save_checkpoint 1
fi

# ── 阶段 2：基础系统配置 ─────────────────────────────────────────────────

if ! run_stage 2 "配置基础系统"; then
    mount_vfs

    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

    cat > "$ROOTFS_DIR/etc/apt/sources.list" <<SOURCES
deb $MIRROR $SUITE main contrib
deb $MIRROR ${SUITE}-updates main contrib
deb http://security.debian.org/debian-security ${SUITE}-security main contrib
SOURCES

    # 配置 apt 自动重试（网络不稳定时自动重试 3 次）
    mkdir -p "$ROOTFS_DIR/etc/apt/apt.conf.d"
    cat > "$ROOTFS_DIR/etc/apt/apt.conf.d/80clawshell-retry" <<'APTCONF'
Acquire::Retries "3";
Acquire::https::Timeout "30";
Acquire::http::Timeout "30";
APTCONF

    chroot "$ROOTFS_DIR" bash -c "
        sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
        locale-gen
    "

    echo "clawshell" > "$ROOTFS_DIR/etc/hostname"

    umount_vfs
    save_checkpoint 2
fi

# ── 阶段 3：安装 Python 3 ────────────────────────────────────────────────

if ! run_stage 3 "安装 Python 3"; then
    mount_vfs
    mount_apt_cache
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
    mount_apt_cache
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

        # 写入系统级 profile
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
    mount_apt_cache
    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

    chroot "$ROOTFS_DIR" bash -c "
        export PNPM_HOME=/usr/local/share/pnpm
        export PATH=\$PNPM_HOME:\$PATH

        # openclaw 的依赖 @whiskeysockets/baileys 需要 git ls-remote
        # chroot 是隔离环境，即使宿主装了 git 也看不到，必须在里面装
        apt-get update -qq
        apt-get install -y -qq git build-essential python3-dev

        pnpm add -g openclaw@latest

        # 严格验证：openclaw 必须安装成功，否则不存 checkpoint
        if ! command -v openclaw &>/dev/null; then
            echo '错误：openclaw 安装失败，未找到可执行文件' >&2
            exit 1
        fi
        openclaw --version
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

        # 清理 apt 缓存（rootfs 内部的，不影响外部持久缓存）
        apt-get clean
        rm -rf /var/lib/apt/lists/*

        # 清理 pip 缓存
        rm -rf /root/.cache/pip /home/$CLAWSHELL_USER/.cache/pip

        # 清理 pnpm store 缓存
        pnpm store prune 2>/dev/null || true

        # 清理文档和 man pages
        rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
        # 删除非英语 locale（保留 en、en_US、locale.alias）
        find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
            ! -name 'en' ! -name 'en_US' -exec rm -rf {} +
        rm -f /usr/share/locale/*.alias 2>/dev/null || true

        # 清理日志
        find /var/log -type f -delete

        # 清理 __pycache__
        find / -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

        # 清理临时文件
        rm -rf /tmp/* /var/tmp/*

        # 清理 apt retry 配置（构建完不再需要）
        rm -f /etc/apt/apt.conf.d/80clawshell-retry
    "

    umount_vfs
    save_checkpoint 7
fi

# ── 打包 ─────────────────────────────────────────────────────────────────

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
echo ""
echo " 输出文件：$OUTPUT"
echo " 文件大小：$(du -sh "$OUTPUT" | cut -f1)"
echo " rootfs：$(du -sh "$ROOTFS_DIR" | cut -f1)"
echo ""
echo " 在 WSL 内复制到 Windows 可访问位置："
echo "   cp $OUTPUT /mnt/c/Users/\$(whoami)/clawshell-rootfs.tar.gz"
echo ""
echo " 然后在 Windows PowerShell 中导入："
echo "   wsl --import ClawShell C:\\ClawShell\\vm C:\\Users\\<用户名>\\clawshell-rootfs.tar.gz"
echo ""
echo " 启动："
echo "   wsl -d ClawShell"
echo ""
echo " 管理构建缓存："
echo "   sudo $0 --list           # 查看缓存状态"
echo "   sudo $0 --from 5         # 从阶段 5 重建"
echo "   sudo $0 --clean          # 清除 checkpoint（保留下载缓存）"
echo "   sudo $0 --purge-cache    # 清除下载缓存"
echo "=========================================="
