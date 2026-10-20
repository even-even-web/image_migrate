#!/usr/bin/env bash
#
# 容器/镜像迁移快照工具
# 功能：
#   1. 镜像导出  docker save -o 将镜像导出为 .tar 文件
#   2. 容器提交  docker commit 将容器打包为镜像，再 docker save 导出为 .tar 文件
#   3. 结果传输  scp 将 .tar 文件拷贝到另一台机器（自定义源IP、目的IP、目的保存地址）
#
# 用法：bash image_migrate.sh
#

set -uo pipefail

print_block() {
    echo ""
    echo "=============================================="
    echo "   $1"
    echo "=============================================="
}

# ==================== scp 传输函数 ====================
scp_transfer() {
    local TAR_FILE="$1"

    echo ""
    read -rp "是否执行 scp 传输到目标机器？(y/N): " DO_SCP
    case "$DO_SCP" in
        y|Y|yes|YES) ;;
        *) echo "[INFO] 已跳过 scp 传输。tar 文件在: $TAR_FILE"; return 0 ;;
    esac

    echo "[提示] 如果 tar 文件就在当前机器上，源IP可直接回车留空。"
    read -rp "请输入源IP (当前机器留空，远程机器填其IP): " SRC_IP
    read -rp "请输入源机器 SSH 用户名 (默认 root): " SRC_USER
    SRC_USER="${SRC_USER:-root}"

    read -rp "请输入目的IP: " DST_IP
    if [[ -z "$DST_IP" ]]; then
        echo "[ERROR] 目的IP不能为空" >&2
        return 1
    fi

    read -rp "请输入目的机器 SSH 用户名 (默认 root): " DST_USER
    DST_USER="${DST_USER:-root}"

    read -rp "请输入目的保存地址 (如 /root/backup/images): " DST_DIR
    if [[ -z "$DST_DIR" ]]; then
        echo "[ERROR] 目的保存地址不能为空" >&2
        return 1
    fi

    local TAR_NAME
    TAR_NAME=$(basename "$TAR_FILE")

    # 构造 scp 源路径
    local SRC_PATH="$TAR_FILE"
    local TMP_FILE=""
    if [[ -n "$SRC_IP" && "$SRC_IP" != "localhost" && "$SRC_IP" != "127.0.0.1" ]]; then
        # 源文件在远程机器上，先拷贝到当前机器做中转
        TMP_FILE="/tmp/${TAR_NAME}.tmp"
        echo ""
        echo "[INFO] 从源机器下载到当前机器中转: $TMP_FILE"
        scp "$SRC_USER@$SRC_IP:$TAR_FILE" "$TMP_FILE" || { echo "[ERROR] 从源机器下载失败" >&2; return 1; }
        SRC_PATH="$TMP_FILE"
    fi

    echo ""
    echo "[INFO] 创建目的目录并传输: $SRC_PATH -> $DST_USER@$DST_IP:$DST_DIR"
    ssh "$DST_USER@$DST_IP" "mkdir -p '$DST_DIR'" || { echo "[ERROR] 在目的机器创建目录失败: $DST_DIR" >&2; return 1; }
    scp "$SRC_PATH" "$DST_USER@$DST_IP:$DST_DIR/$TAR_NAME" || { echo "[ERROR] scp 传输失败" >&2; return 1; }

    if [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]]; then
        rm -f "$TMP_FILE"
    fi

    echo ""
    echo "[SUCCESS] 传输完成！目标文件: $DST_USER@$DST_IP:$DST_DIR/$TAR_NAME"
    return 0
}

# ==================== 镜像保存为 tar ====================
save_image() {
    local IMAGE_NAME="$1"
    local SAVE_DIR="$2"
    local TAR_NAME="$3"

    if [[ -z "$TAR_NAME" ]]; then
        SAFE_NAME=$(echo "$IMAGE_NAME" | tr '/:+' '___')
        TAR_NAME="${SAFE_NAME}_$(date +%Y%m%d_%H%M%S).tar"
    fi
    local TAR_FILE="$SAVE_DIR/$TAR_NAME"

    echo "[INFO] 开始导出镜像: $IMAGE_NAME -> $TAR_FILE"
    docker save -o "$TAR_FILE" "$IMAGE_NAME" || { echo "[ERROR] docker save 导出失败" >&2; return 1; }

    echo "[INFO] 导出成功，文件大小："
    ls -lh "$TAR_FILE"
    echo "$TAR_FILE"
}

# ==================== 功能一：镜像导出并迁移 ====================
func_export_image() {
    print_block "功能一：镜像导出 (docker save)"
    read -rp "请输入要导出的镜像名称 (如 nginx:latest): " IMAGE_NAME
    if [[ -z "$IMAGE_NAME" ]]; then
        echo "[ERROR] 镜像名称不能为空" >&2
        return 1
    fi

    read -rp "请输入 tar 文件保存目录 (如 /root/backup/images): " SAVE_DIR
    SAVE_DIR="${SAVE_DIR:-/root/backup/images}"
    if ! mkdir -p "$SAVE_DIR" 2>/dev/null; then
        echo "[ERROR] 目录不存在且创建失败: $SAVE_DIR" >&2
        return 1
    fi

    read -rp "请输入要保存的 tar 文件名 (如 myapp.tar，留空则自动生成): " TAR_NAME

    echo ""
    echo "[INFO] 检查本地镜像是否已存在 ..."
    if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        echo "[WARN] 本地不存在该镜像，尝试先 pull ..."
        docker pull "$IMAGE_NAME" || { echo "[ERROR] 镜像拉取失败: $IMAGE_NAME" >&2; return 1; }
    fi

    local OUT
    OUT=$(save_image "$IMAGE_NAME" "$SAVE_DIR" "$TAR_NAME") || return 1
    local TAR_FILE
    TAR_FILE=$(echo "$OUT" | tail -n 1)

    scp_transfer "$TAR_FILE"
}

# ==================== 功能二：容器提交并迁移 ====================
func_commit_container() {
    print_block "功能二：容器提交 (docker commit)"
    read -rp "请输入要提交的容器 ID 或名称: " CONTAINER
    if [[ -z "$CONTAINER" ]]; then
        echo "[ERROR] 容器 ID/名称不能为空" >&2
        return 1
    fi

    read -rp "请输入新镜像名称 (如 myapp/ubuntu:latest，留空则自动生成): " IMAGE_NAME
    if [[ -z "$IMAGE_NAME" ]]; then
        IMAGE_NAME="committed_${CONTAINER}_$(date +%Y%m%d_%H%M%S)"
    fi

    read -rp "请输入提交信息 message (可选，直接回车跳过): " COMMIT_MSG

    echo ""
    echo "[INFO] 检查容器是否存在 ..."
    if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
        echo "[ERROR] 容器不存在: $CONTAINER" >&2
        return 1
    fi

    echo "[INFO] 正在提交容器 -> 镜像: $IMAGE_NAME"
    if [[ -n "$COMMIT_MSG" ]]; then
        docker commit -m "$COMMIT_MSG" "$CONTAINER" "$IMAGE_NAME"
    else
        docker commit "$CONTAINER" "$IMAGE_NAME"
    fi || { echo "[ERROR] docker commit 提交失败" >&2; return 1; }

    echo "[INFO] 提交成功，开始保存为 tar 文件 ..."
    read -rp "请输入 tar 文件保存目录 (如 /root/backup/images): " SAVE_DIR
    SAVE_DIR="${SAVE_DIR:-/root/backup/images}"
    if ! mkdir -p "$SAVE_DIR" 2>/dev/null; then
        echo "[ERROR] 目录不存在且创建失败: $SAVE_DIR" >&2
        return 1
    fi

    read -rp "请输入要保存的 tar 文件名 (如 myapp.tar，留空则自动生成): " TAR_NAME

    local OUT
    OUT=$(save_image "$IMAGE_NAME" "$SAVE_DIR" "$TAR_NAME") || return 1
    local TAR_FILE
    TAR_FILE=$(echo "$OUT" | tail -n 1)

    scp_transfer "$TAR_FILE"
}

# ==================== 功能三：仅 scp 已导出的 tar ====================
func_scp_only() {
    print_block "功能三：仅传输已有 tar 文件"
    read -rp "请输入本地 tar 文件完整路径: " TAR_FILE
    if [[ -z "$TAR_FILE" || ! -f "$TAR_FILE" ]]; then
        echo "[ERROR] 文件不存在: $TAR_FILE" >&2
        return 1
    fi
    scp_transfer "$(realpath "$TAR_FILE")"
}

# ==================== 主菜单 ====================
print_block "容器/镜像迁移快照工具"

while true; do
    echo "请选择操作："
    echo "  1) 镜像导出并迁移   (docker save -o + scp)"
    echo "  2) 容器提交并迁移   (docker commit + docker save + scp)"
    echo "  3) 仅传输已有 tar    (scp)"
    echo "  0) 退出"
    read -rp "请输入序号 [0/1/2/3]: " OPT

    case "$OPT" in
        1) func_export_image ;;
        2) func_commit_container ;;
        3) func_scp_only ;;
        0) echo "[INFO] 已退出。"; exit 0 ;;
        *) echo "[WARN] 无效输入，请重新输入。"; continue ;;
    esac

    echo ""
    read -rp "继续其他操作？(y/N): " AGAIN
    case "$AGAIN" in
        y|Y|yes|YES) continue ;;
        *) break ;;
    esac
done

echo "[完成] 容器/镜像迁移快照流程结束。"
