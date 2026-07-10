#!/bin/bash

# 检查参数
if [ $# -eq 0 ]; then
    echo "请输入大包名称"
    echo "用法: $0 <压缩文件名> [解压目录]"
    echo "示例: $0 your_package.install.tar /mnt/gaea"
    exit 1
fi

# 设置文件路径
ARCHIVE="$1"
MD5_FILE="${ARCHIVE}.md5"

# 检查文件是否存在
if [ ! -f "$ARCHIVE" ]; then
    echo "错误: 压缩文件 $ARCHIVE 不存在"
    exit 1
fi

if [ ! -f "$MD5_FILE" ]; then
    echo "错误: MD5校验文件 $MD5_FILE 不存在"
    exit 1
fi

# 创建完整输出目录路径
OUTPUT_DIR="/mnt/gaea/package"
MIN_AVAILABLE_SPACE_KB=$((50 * 1024 * 1024))

check_available_space() {
    local available_kb

    mkdir -p "$OUTPUT_DIR" || return 1
    available_kb=$(df -Pk "$OUTPUT_DIR" | awk 'NR==2 {print $4}')
    if [ -z "$available_kb" ]; then
        echo "错误: 无法获取 ${OUTPUT_DIR} 的可用空间"
        return 1
    fi

    if [ "$available_kb" -lt "$MIN_AVAILABLE_SPACE_KB" ]; then
        echo "错误: ${OUTPUT_DIR} 可用空间不足 50G，终止解压"
        return 1
    fi
}

ensure_pv_installed() {
    if command -v pv >/dev/null 2>&1; then
        return 0
    fi

    echo "pv 未安装，正在安装 pv"
    if sudo apt install -y pv >/dev/null 2>&1 && command -v pv >/dev/null 2>&1; then
        return 0
    fi

    echo "警告: pv 安装失败，将继续解压但不显示分片进度"
    return 1
}

# 校验完整性函数
verify_integrity() {
    echo "开始校验文件完整性..."
    echo "压缩文件: $ARCHIVE"
    echo "校验文件: $MD5_FILE"
    
    # 计算当前文件的MD5值
    current_md5=$(md5sum "$ARCHIVE" | awk '{print $1}')
    # 读取预期的MD5值
    expected_md5=$(cat "$MD5_FILE" | awk '{print $1}')
    
    if [ "$current_md5" = "$expected_md5" ]; then
        echo "✓ 文件完整性校验通过"
        return 0
    else
        echo "✗ 文件完整性校验失败"
        echo "预期MD5: $expected_md5"
        echo "实际MD5: $current_md5"
        return 1
    fi
}

# 解压函数
extract_archive() {
    echo "开始解压文件..."

    if ! check_available_space; then
        return 1
    fi
    
    # 检查zstd是否安装
    if ! command -v zstd &> /dev/null; then
        echo "错误: zstd 未安装，请先安装 zstd"
        echo "Ubuntu/Debian: sudo apt install zstd"
        echo "CentOS/RHEL: sudo yum install zstd"
        exit 1
    fi

    local use_pv=0
    if ensure_pv_installed; then
        use_pv=1
    fi
    
    local base_name=$(basename "${ARCHIVE%.install.tar}")
    local install_dir="${OUTPUT_DIR}/${base_name}.install"
    local archives_dir="${install_dir}/archives"
    local archive_list="${install_dir}/archives.list"
    local staging_dir="${OUTPUT_DIR}/${base_name}_staging"
    local final_dir="${OUTPUT_DIR}/${base_name}_output"
    local decompress_jobs="${DECOMPRESS_JOBS:-8}"

    if [ "${base_name}" = "$(basename "$ARCHIVE")" ]; then
        echo "错误: 仅支持新的 .install.tar 分片包格式"
        return 1
    fi

    if ! [[ "${decompress_jobs}" =~ ^[0-9]+$ ]] || [ "${decompress_jobs}" -lt 1 ]; then
        decompress_jobs=8
    fi

    if [ -e "$final_dir" ]; then
        echo "错误: 输出目录已存在: $final_dir"
        return 1
    fi

    echo "清理历史中间产物..."
    if ! rm -rf "$install_dir" "$staging_dir"; then
        echo "错误: 清理历史中间产物失败"
        return 1
    fi
    mkdir -p "$staging_dir"

    echo "解压外层安装包..."
    if ! tar --warning=no-timestamp -xf "$ARCHIVE" -C "$OUTPUT_DIR"; then
        echo "✗ 外层安装包解压失败"
        return 1
    fi

    if [ ! -d "$archives_dir" ]; then
        echo "错误: 分片目录不存在: $archives_dir"
        return 1
    fi

    if [ ! -f "${install_dir}/checksums.md5" ]; then
        echo "错误: 分片校验文件不存在: ${install_dir}/checksums.md5"
        return 1
    fi

    echo "校验分片文件完整性..."
    if ! (cd "$install_dir" && md5sum -c --quiet checksums.md5); then
        echo "✗ 分片文件完整性校验失败"
        return 1
    fi

    awk '$2 ~ /^archives\/.*\.tar\.zst$/ {print "'"$install_dir"'/" $2}' \
        "${install_dir}/checksums.md5" | sort > "$archive_list"
    if [ ! -s "$archive_list" ]; then
        echo "错误: 未在 checksums.md5 中找到分片文件"
        return 1
    fi

    echo "并行解压分片文件，jobs=${decompress_jobs}..."
    if ! xargs -P "$decompress_jobs" -r -n 1 bash -c \
            'set -o pipefail
             staging_dir="$1"
         use_pv="$2"
         archive="$3"
         if [ "$use_pv" = "1" ]; then
             archive_name=$(basename "$archive")
             archive_size=$(stat -c%s "$archive")
             pv -c -pterb -s "$archive_size" -N "$archive_name" "$archive" \
                 | tar --warning=no-timestamp -I "zstd -T0" -xf - -C "$staging_dir"
         else
             tar --warning=no-timestamp -I "zstd -T0" -xf "$archive" -C "$staging_dir"
         fi' _ "$staging_dir" "$use_pv"; then
        echo "✗ 分片解压失败"
        return 1
    fi < "$archive_list"

    if [ ! -d "${staging_dir}/output" ]; then
        echo "错误: 分片解压后未找到 output 目录"
        return 1
    fi

    mkdir "$final_dir"
    mv "${staging_dir}/output" "$final_dir"
    rm -rf "$staging_dir" "$install_dir"

    echo "✓ 解压完成到目录: $OUTPUT_DIR"
    return 0
}

set_service() {
    local base_name=$(basename "${ARCHIVE%.install.tar}")
    local output_dir="${OUTPUT_DIR}/${base_name}_output/output"
    
    # 设置权限
    sudo chmod -R 777 "${OUTPUT_DIR}/${base_name}_output" || return 1
    
    # 修改启动脚本中的工作目录路径
    echo "修改启动脚本的工作目录路径..."
    sed -i "s|cd /mnt/gaea/output|cd \"$output_dir\"|" \
        "${output_dir}/scripts/humanoid/humanoid_start_up.sh" || return 1
    sed -i "s|> /mnt/gaea/output/comm_full_|> ${output_dir}/comm_full_|g" \
        "${output_dir}/scripts/humanoid/humanoid_start_up.sh" || return 1

    echo "挂接 /apollo 到当前解压目录..."
    if [ ! -f "${output_dir}/gaea.bashrc" ]; then
        echo "错误: gaea.bashrc 不存在: ${output_dir}/gaea.bashrc"
        return 1
    fi
    (
        cd "$output_dir" || exit 1
        source "${output_dir}/gaea.bashrc"
        go2root
    ) >/dev/null 2>&1 || {
        echo "错误: /apollo 挂接失败"
        return 1
    }

    echo "设置开机自启服务"
    sudo cp "${output_dir}/scripts/humanoid/humanoid_start_up.sh" \
        /usr/local/bin/humanoid_start_up.sh || return 1
    sudo chmod +x /usr/local/bin/humanoid_start_up.sh || return 1
    sudo cp "${output_dir}/scripts/humanoid/humanoid-startup.service" \
        /etc/systemd/system/humanoid-startup.service || return 1
    sudo chmod 644 /etc/systemd/system/humanoid-startup.service || return 1
    sudo systemctl daemon-reload || return 1
    sudo systemctl enable humanoid-startup.service || return 1
    sudo systemctl start humanoid-startup.service || return 1

    echo "服务设置完成，需要重启生效"
    # reboot
}

# 主执行流程
main() {
    echo "=== 开始处理压缩文件 ==="
    
    ARCH=$(uname -m)
    if [[ $ARCH == "aarch64" || $ARCH == "arm64" ]]; then
        cd /mnt/gaea/package

        # 第一步：校验完整性
        if verify_integrity; then
            # 第二步：解压文件
            if extract_archive; then
                # 第三步：设置开机自启服务
                if set_service; then
                    echo "=== 所有操作完成 ==="
                else
                    echo "=== 服务设置失败 ==="
                    exit 1
                fi
            else
                echo "=== 解压失败 ==="
                exit 1
            fi
        else
            echo "=== 文件校验失败，停止执行 ==="
            exit 1
        fi
    else
        # x86架构
        echo "当前架构为 ${ARCH}，暂不执行解压和服务设置逻辑"
    fi
}

# 执行主函数
main "$@"
