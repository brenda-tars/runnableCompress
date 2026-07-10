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
for item in "version.txt" "command.txt" "bin" "data_dir"; do
    if [ ! -e "$TARGET_DIR/$item" ]; then
        echo "错误: 缺少必要的文件或目录 -> $TARGET_DIR/$item"
        exit 1
    fi
done

# 3. 读取版本号并清理可能存在的换行符或空格
VERSION=$(cat "$TARGET_DIR/version.txt" | tr -d '\n' | tr -d '\r' | xargs)
if [ -z "$VERSION" ]; then
    echo "错误: version.txt 内容为空"
    exit 1
fi

RUN_FILE="${VERSION}.run"
PAYLOAD_ARCHIVE=$(mktemp /tmp/payload.XXXXXX.tar.gz)

# 4. 将需要的文件打包成临时压缩文件 (为了通用性，这里使用 tar.gz)
echo "=> 正在压缩 payload (bin, data_dir, command.txt)..."
# 使用 -C 参数进入目标目录进行压缩，这样解压时不会带上外层目录的名字
tar -czf "$PAYLOAD_ARCHIVE" -C "$TARGET_DIR" bin data_dir command.txt

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

# 创建临时工作目录并设置退出清理钩子
TMP_DIR=$(mktemp -d "/tmp/installer.XXXXXX")
cleanup() {
    echo "清理临时工作空间: $TMP_DIR"
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "释放模块 payload 到 $TMP_DIR ..."
# 提取自身尾部的二进制数据并解压到临时目录
tail -n +"$PAYLOAD_LINE" "$0" | tar -xzf - -C "$TMP_DIR"

echo "赋予 bin 目录可执行权限..."
chmod -R +x "$TMP_DIR/bin/"

echo "------------------------------------------------"
echo "开始执行 command.txt 部署指令..."
echo "------------------------------------------------"

# 切换到解压目录，确保 command.txt 里调用的 bin/xxx 或 data_dir/xxx 相对路径有效
cd "$TMP_DIR"

# 运行 command.txt (将其当作 shell 脚本执行)
bash command.txt

echo "------------------------------------------------"
echo "部署指令执行完毕！"
exit 0

__PAYLOAD_BELOW__
EOF

# 6. 将生成的二进制压缩包追加到 .run 文件末尾
cat "$PAYLOAD_ARCHIVE" >> "$RUN_FILE"

# 7. 赋予可执行权限并清理临时压缩包
chmod +x "$RUN_FILE"
rm -f "$PAYLOAD_ARCHIVE"

echo "=> 打包完成！成功生成: ${RUN_FILE}"