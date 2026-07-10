#!/usr/bin/env bash
set -euo pipefail

# 1. 检查输入参数
if [ "$#" -ne 1 ]; then
    echo "用法: $0 <输入目录路径>"
    exit 1
fi

TARGET_DIR="$1"

# 2. 检查必需的文件和目录是否存在
echo "=> 正在检查目录结构..."
for item in "version.txt" "command.sh" "bin" "data_dir"; do
    if [ ! -e "$TARGET_DIR/$item" ]; then
        echo "错误: 缺少必要的文件或目录 -> $TARGET_DIR/$item"
        exit 1
    fi
done

if ! command -v zstd >/dev/null 2>&1; then
    echo "检测到未安装 zstd，尝试自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
        install_cmd='apt-get install -y zstd'
    elif command -v yum >/dev/null 2>&1; then
        install_cmd='yum install -y zstd'
    else
        echo "错误: 未安装 zstd，且无法自动检测包管理器"
        echo "Ubuntu/Debian: sudo apt install zstd"
        echo "CentOS/RHEL: sudo yum install zstd"
        exit 1
    fi

    if [ "$(id -u)" -eq 0 ]; then
        sh -c "$install_cmd"
    else
        sudo sh -c "$install_cmd"
    fi

    if ! command -v zstd >/dev/null 2>&1; then
        echo "错误: zstd 自动安装失败"
        exit 1
    fi
fi

# 3. 读取版本号并清理可能存在的换行符或空格
VERSION=$(cat "$TARGET_DIR/version.txt" | tr -d '\n' | tr -d '\r' | xargs)
if [ -z "$VERSION" ]; then
    echo "错误: version.txt 内容为空"
    exit 1
fi

RUN_FILE="${VERSION}.run"

# ZSTD_THREADS: zstd 并行压缩线程数，0 = 自动检测全部逻辑核
ZSTD_THREADS="${ZSTD_THREADS:-0}"
# SPLIT_THRESHOLD_KB: data_dir 子目录超过此大小则再拆一层，默认 512MB
SPLIT_THRESHOLD_KB="${SPLIT_THRESHOLD_KB:-$((512 * 1024))}"

INSTALL_DIR=$(mktemp -d "/tmp/${VERSION}.install.XXXXXX")
ARCHIVES_DIR="${INSTALL_DIR}/archives"
CHECKSUM_FILE="${INSTALL_DIR}/checksums.md5"
mkdir -p "$ARCHIVES_DIR"
: > "$CHECKSUM_FILE"

# 4. 分片打包 (bin, command.sh, data_dir)
echo "=> 正在分片压缩 payload (bin, data_dir, command.sh)..."

create_shard() {
    local archive_name="$1"
    shift
    echo "  Creating shard: ${archive_name}"
    tar -C "$TARGET_DIR" -I "zstd -T${ZSTD_THREADS}" -cf "${ARCHIVES_DIR}/${archive_name}" "$@"
    (cd "$INSTALL_DIR" && md5sum "archives/${archive_name}" >> "$CHECKSUM_FILE")
}

shard_name_from_path() {
    local prefix="$1"
    local rel="${2#data_dir/}"
    rel="${rel//\//-}"
    rel="${rel//_/-}"
    echo "${prefix}-${rel}.tar.zst"
}

create_data_dir_shards() {
    local prefix="20-data-dir"
    local data_root="${TARGET_DIR}/data_dir"
    local root_files=() entry rel_entry size_kb
    local child_root_files=() child rel_child file

    while IFS= read -r -d $'\0' file; do
        root_files+=("${file#"${TARGET_DIR}"/}")
    done < <(find "$data_root" -maxdepth 1 -type f -print0 | sort -z)
    if [ "${#root_files[@]}" -gt 0 ]; then
        create_shard "${prefix}-root.tar.zst" "${root_files[@]}"
    fi

    while IFS= read -r -d $'\0' entry; do
        rel_entry="${entry#"${TARGET_DIR}"/}"
        size_kb=$(du -sk "$entry" | awk '{print $1}')
        if [ "$size_kb" -le "$SPLIT_THRESHOLD_KB" ]; then
            create_shard "$(shard_name_from_path "$prefix" "$rel_entry")" "$rel_entry"
            continue
        fi

        child_root_files=()
        while IFS= read -r -d $'\0' file; do
            child_root_files+=("${file#"${TARGET_DIR}"/}")
        done < <(find "$entry" -maxdepth 1 -type f -print0 | sort -z)
        if [ "${#child_root_files[@]}" -gt 0 ]; then
            create_shard "$(shard_name_from_path "$prefix" "$rel_entry" | sed 's/\.tar\.zst$/-root.tar.zst/')" \
                "${child_root_files[@]}"
        fi

        while IFS= read -r -d $'\0' child; do
            rel_child="${child#"${TARGET_DIR}"/}"
            create_shard "$(shard_name_from_path "$prefix" "$rel_child")" "$rel_child"
        done < <(find "$entry" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    done < <(find "$data_root" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
}

create_shard "00-command.tar.zst" "command.sh"
create_shard "10-bin.tar.zst" "bin"
create_data_dir_shards

PAYLOAD_ARCHIVE=$(mktemp /tmp/payload.XXXXXX.tar)
tar -cf "$PAYLOAD_ARCHIVE" -C "$INSTALL_DIR" archives checksums.md5

# 5. 生成 .run 自解压脚本的头部逻辑
echo "=> 正在生成自解压脚本: ${RUN_FILE} ..."

# 注意：这里使用了 << 'EOF' (带单引号)，这会阻止外层变量替换，
# 让我们在写入脚本时不需要像你提供的代码那样手动转义 \$，代码更干净。
cat > "$RUN_FILE" << 'EOF'
#!/usr/bin/env bash
set -e

PAYLOAD_MARKER="__PAYLOAD_BELOW__"
# 找到魔法标记所在的行号
PAYLOAD_LINE=$(awk "/^${PAYLOAD_MARKER}$/ {print NR+1; exit 0;}" "$0")

if [ -z "$PAYLOAD_LINE" ]; then
    echo "错误: 安装包 payload 损坏或不存在"
    exit 1
fi

if ! command -v zstd >/dev/null 2>&1; then
    echo "错误: 未安装 zstd，请先安装 (apt install zstd / yum install zstd)"
    exit 1
fi

# 创建临时工作目录并设置退出清理钩子
TMP_DIR=$(mktemp -d "/tmp/installer.XXXXXX")
cleanup() {
    echo "清理临时工作空间: $TMP_DIR"
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "释放模块 payload 到 $TMP_DIR ..."
# 提取自身尾部的分片包 (archives/ + checksums.md5) 到临时目录
tail -n +"$PAYLOAD_LINE" "$0" | tar -xf - -C "$TMP_DIR"

echo "校验分片文件完整性..."
if ! (cd "$TMP_DIR" && md5sum -c --quiet checksums.md5); then
    echo "错误: 分片文件完整性校验失败"
    exit 1
fi

DECOMPRESS_JOBS="${DECOMPRESS_JOBS:-4}"
if ! [[ "$DECOMPRESS_JOBS" =~ ^[0-9]+$ ]] || [ "$DECOMPRESS_JOBS" -lt 1 ]; then
    DECOMPRESS_JOBS=4
fi

echo "并行解压分片 (jobs=${DECOMPRESS_JOBS})..."
if ! find "$TMP_DIR/archives" -type f -name '*.tar.zst' -print0 | \
        xargs -0 -P "$DECOMPRESS_JOBS" -r -n 1 bash -c '
            target_dir="$1"
            archive="$2"
            tar -I "zstd -d -T0" -xf "$archive" -C "$target_dir"
        ' _ "$TMP_DIR"; then
    echo "错误: 分片解压失败"
    exit 1
fi

echo "赋予 bin 目录可执行权限..."
chmod -R +x "$TMP_DIR/bin/"

echo "------------------------------------------------"
echo "开始执行 command.sh 部署指令..."
echo "------------------------------------------------"

# 切换到解压目录，确保 command.sh 里调用的 bin/xxx 或 data_dir/xxx 相对路径有效
cd "$TMP_DIR"

# 运行 command.sh (将其当作 shell 脚本执行)
bash command.sh

echo "------------------------------------------------"
echo "部署指令执行完毕！"
exit 0

__PAYLOAD_BELOW__
EOF

# 6. 将生成的分片 payload 追加到 .run 文件末尾
cat "$PAYLOAD_ARCHIVE" >> "$RUN_FILE"

# 7. 赋予可执行权限并清理临时产物
chmod +x "$RUN_FILE"
rm -f "$PAYLOAD_ARCHIVE"
rm -rf "$INSTALL_DIR"

echo "=> 打包完成！成功生成: ${RUN_FILE}"
