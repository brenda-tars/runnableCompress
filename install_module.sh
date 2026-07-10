#!/usr/bin/env bash


TOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BAZEL_BIN="${TOP_DIR}/bazel-bin"
BAZEL_OUTPUT_BASE=$(bazel info output_base 2>/dev/null)
OUTPUT_DIR="${TOP_DIR}/output"


echo "Start installation..."
echo "TOP_DIR: ${TOP_DIR}"
echo "OUTPUT_DIR: ${OUTPUT_DIR}"
echo "BAZEL_BIN: ${BAZEL_BIN}"
echo "BAZEL_OUTPUT_BASE: ${BAZEL_OUTPUT_BASE}"

#0. Create output directory if not exists, else clean it
if [ ! -d "$OUTPUT_DIR" ]; then
  mkdir -p "$OUTPUT_DIR"
else
  # 保留 awr_power_firmware/：由 zephyr 流水线段先于 install 写入，需随主包一起打。
  find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 ! -name 'awr_power_firmware' -exec rm -rf {} +
fi

#1. copy config files
src_dirs=("${TOP_DIR}/modules" "${TOP_DIR}/cyber")
des_dir="${OUTPUT_DIR}"

echo "Copying configuration files..."
# Loop through each source directory
for src_dir in "${src_dirs[@]}"; do
  # Check if source directory exists
  if [ ! -d "$src_dir" ]; then
    echo "Error: Source directory '$src_dir' does not exist."
    continue
  fi

  # Get the source directory name
  src_folder=$(basename "$src_dir")

  # Find and copy configuration files
  find "$src_dir" -type f \( -name "*.dag" -o -name "*.yaml" -o -name "*.pb.txt" -o -name "*.conf" -o -name "*.launch" -o -name "*.sh" -o -name "*.py" -o -name "*.json" \) | while read -r file; do
    # Get relative path from source directory
    relative_path="${file#$src_dir/}"
    # Generate destination file path
    dest_file="$des_dir/$src_folder/$relative_path"
    # Create destination directory if not exists
    dest_dir=$(dirname "$dest_file")
    mkdir -p "$dest_dir"
    # Copy file to destination
    cp -rP "$file" "$dest_file"
  done
done

echo "Copy configuration files completed!"


#2. copy build output to output directory
#cp -rP bazel_bin/cyber,moduel, _solib_local to output
target_dir="${OUTPUT_DIR}/bazel-bin/"
echo "Copying build output to ${target_dir}..."
mkdir -p ${OUTPUT_DIR}/bazel-bin
cp -rP ${BAZEL_BIN}/cyber $target_dir
cp -rP ${BAZEL_BIN}/modules $target_dir
cp -rP ${BAZEL_BIN}/third_party $target_dir
cp -rP ${BAZEL_BIN}/external $target_dir
cp -rL ${BAZEL_BIN}/_solib_* $target_dir
cp -rP ${BAZEL_OUTPUT_BASE}/external $target_dir/deps

echo "Copy build output completed!"

# Normalize _solib_<cpu> name so RUNPATH labels from any toolchain resolve.
# Each build produces only one _solib_<cpu>; rename to _solib_local and add
# symlinks for other possible cpu labels so binaries linked under a different
# crosstool config still find their mangled solibs after install.
# If more than one _solib_<cpu> coexists, hard-fail — the build tree is dirty
# (different crosstool configs accumulated under bazel-bin) and the user must
# clean before installing.
normalize_solib_dir() {
  local root="$1"
  local dirs=()
  local d
  for d in "$root"/_solib_local "$root"/_solib_aarch64 "$root"/_solib_k8; do
    if [ -d "$d" ] && [ ! -L "$d" ]; then
      dirs+=("$d")
    fi
  done

  if [ "${#dirs[@]}" -eq 0 ]; then
    return 0
  fi
  if [ "${#dirs[@]}" -gt 1 ]; then
    echo "ERROR: multiple _solib_<cpu> dirs under $root: ${dirs[*]}" >&2
    echo "       different toolchains accumulated. Run './apollo.sh clean' before installing." >&2
    exit 1
  fi

  local actual="${dirs[0]}"
  if [ "$(basename "$actual")" != "_solib_local" ]; then
    mv "$actual" "$root/_solib_local"
  fi
  local alias link
  for alias in _solib_aarch64 _solib_k8; do
    link="$root/$alias"
    if [ ! -e "$link" ]; then
      ln -s _solib_local "$link"
    fi
  done
}

echo "Normalizing _solib_<cpu> directories..."
normalize_solib_dir "${target_dir%/}"

# every <bin>.runfiles/<workspace>/ may also have its own _solib_<cpu> dir
while IFS= read -r -d '' rf; do
  while IFS= read -r -d '' ws; do
    normalize_solib_dir "$ws"
  done < <(find "$rf" -mindepth 1 -maxdepth 1 -type d -print0)
done < <(find "${target_dir%/}" -type d -name '*.runfiles' -print0)

#3. clean up
echo "Start cleaning directory: $target_dir"

# Whitelist: paths whose contents must survive the cleanup steps below.
# Add new entries when a third-party dep needs runtime files that match the
# generic "delete *.h / *.cc / *.cpp / *.hpp / *.so* / etc." filters.
#
# - apollo_py_deps_warp_lang/.../warp/native: NVIDIA Warp's NVRTC JIT compiler
#   includes builtin.h + companion headers when emitting .cu kernels at
#   runtime (used by cuRobo / arm_planner). Without these the planner errors
#   out with: "cannot open source file builtin.h".
KEEP_PATHS=(
  '*apollo_py_deps_warp_lang/site-packages/warp/native/*'
)
KEEP_FIND_ARGS=()
for p in "${KEEP_PATHS[@]}"; do
  KEEP_FIND_ARGS+=(-not -path "$p")
done

echo "Deleting matching files under external which doesn't contains '.so*' or '.py' or '.sh' ..."
find "${target_dir}external/" "${KEEP_FIND_ARGS[@]}" \( -type f -o -type l \) -not \( -name "*.so*" -o -name "*.py" -o -name "*.sh" \) -exec rm -f {} +

echo "Deleting matching files under third_party which doesn't contains '.so*' or '.py' or '.sh' ..."
find "${target_dir}third_party/" "${KEEP_FIND_ARGS[@]}" \( -type f -o -type l \) -not \( -name "*.so*" -o -name "*.py" -o -name "*.sh" \) -exec rm -f {} +

echo "Deleting matching files under third_party which doesn't contains '.so*' or '.py' or '.sh' ..."
find "${BAZEL_OUTPUT_BASE}/deps/" "${KEEP_FIND_ARGS[@]}" \( -type f -o -type l \) -not \( -name "*.so*" -o -name "*.py" -o -name "*.sh" \) -exec rm -f {} +

echo "Deleting matching directories _objs, install.runfiles, install_*, and *_cpplint..."
find "$target_dir" -type d \( -name "_objs" -o -name "install.runfiles" -o -name "install_*" -o -name "*_cpplint*" \) -exec rm -rf {} +

echo "Deleting matching files install, *.runfiles_manifest, *.params, *.a, *.lo, *_cpplint..."
find "$target_dir" \( -type f -o -type l \) \( -name "install" -o -name "MANIFEST" -o -name "*.runfiles_manifest" -o -name "*.params" -o -name "*.a" -o -name "*.lo" -o -name "*_cpplint" \) -exec rm -f {} +

echo "Deleting matching files *.h, *.cc, *.cpp, *.hpp..."
find "$target_dir" "${KEEP_FIND_ARGS[@]}" \( -type f -o -type l \) \( -name "*.h" -o -name "*.cc" -o -name "*.cpp" -o -name "*.hpp" \) -exec rm -f {} +

echo "Deleting matching files *.dag, *.yaml, *.txt, *.conf, *.ini, *.md, *.config, *.launch..."
find "$target_dir" -path "*/*.runfiles/*" \( -type f -o -type l \) \( -name "*.dag" -o -name "*.yaml" -o -name "*.txt" -o -name "*.conf" -o -name "*.ini" -o -name "*.md" -o -name "*.config" -o -name "*.launch" \) -exec rm -f {} +

echo "Deleting matching files *.pb.*, *.bin, *_so in proto directory..."
find "$target_dir" -path "*/proto/*" \( -type f -o -type l \) \( -name "*.pb.*" -o -name "*.bin" -o -name "*_so" \) -exec rm -f {} +

echo "Clean directory $target_dir completed."


# RELOCATE_JOBS: 并行重定位 symlink 的 worker 数，默认 16
RELOCATE_JOBS="${RELOCATE_JOBS:-16}"
if ! [[ "${RELOCATE_JOBS}" =~ ^[0-9]+$ ]] || [ "${RELOCATE_JOBS}" -lt 1 ]; then
  RELOCATE_JOBS=16
fi

_relocate_one_symlink() {
  local link="$1"
  local target new_target rel

  target=$(readlink "$link" 2>/dev/null) || return 0
  # Preserve relative-path symlinks (e.g. _solib_aarch64 -> _solib_local).
  if [[ "$target" != /* ]]; then
    return 0
  fi

  new_target=""
  if [[ "$target" == "${OLD_BAZEL_DEPS_PREFIX}"* ]]; then
    rel="${target#"${OLD_BAZEL_DEPS_PREFIX}"}"
    new_target="${INSTALL_BAZEL_DEPS_PREFIX}${rel}"
  elif [[ "$target" == "${OLD_BAZEL_BIN_PREFIX}"* ]]; then
    rel="${target#"${OLD_BAZEL_BIN_PREFIX}"}"
    new_target="${INSTALL_BAZEL_BIN_PREFIX}${rel}"
  elif [[ "$target" == "${OLD_TOP_DIR}"* ]]; then
    rel="${target#"${OLD_TOP_DIR}"}"
    new_target="${INSTALL_TOP_DIR}${rel}"
    if ! [[ "$new_target" == "${INSTALL_TOP_DIR}"/cyber/* || \
            "$new_target" == "${INSTALL_TOP_DIR}"/modules/* || \
            "$new_target" == "${INSTALL_TOP_DIR}"/third_party/* || \
            "$new_target" == "${INSTALL_TOP_DIR}"/external/* ]]; then
      echo "Unknown target: $target"
      rm -f "$link"
      return 0
    fi
  else
    echo "Unknown target: $target"
    rm -f "$link"
    return 0
  fi

  if [[ -d "$link" ]]; then
    rm -rf "$link"
  fi
  ln -sf "$new_target" "$link"
}

relocate_bazel_links() {
  local process_dir="$1"
  local total_links abs_links elapsed start_ts end_ts

  if [ ! -d "$process_dir" ]; then
    echo "dir doesn't exist: $process_dir"
    return 1
  fi

  total_links=$(find "$process_dir" -type l 2>/dev/null | wc -l)
  abs_links=$(find "$process_dir" -type l -lname '/*' 2>/dev/null | wc -l)
  echo "Updating symbolic links rel in $process_dir..."
  echo "  symlink stats: total=${total_links}, absolute=${abs_links}, relative=$((total_links - abs_links)), jobs=${RELOCATE_JOBS}"

  start_ts=$(date +%s)
  if [ "${abs_links}" -gt 0 ]; then
    export OLD_TOP_DIR OLD_BAZEL_BIN_PREFIX OLD_BAZEL_DEPS_PREFIX
    export INSTALL_TOP_DIR INSTALL_BAZEL_BIN_PREFIX INSTALL_BAZEL_DEPS_PREFIX
    export -f _relocate_one_symlink
    find "$process_dir" -type l -lname '/*' -print0 2>/dev/null | \
      xargs -0 -P "${RELOCATE_JOBS}" -r -n 1 bash -c '_relocate_one_symlink "$1"' _
  fi
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))
  echo "  symlink relocate done in ${elapsed}s for $process_dir"
}

OLD_TOP_DIR="${TOP_DIR}"
OLD_BAZEL_BIN_PREFIX=$(readlink "$BAZEL_BIN")
OLD_BAZEL_DEPS_PREFIX="${BAZEL_OUTPUT_BASE}/external"
INSTALL_TOP_DIR="/apollo"
INSTALL_BAZEL_BIN_PREFIX="/apollo/bazel-bin"
INSTALL_BAZEL_DEPS_PREFIX="/apollo/bazel-bin/deps"

echo "Relocating bazel links (RELOCATE_JOBS=${RELOCATE_JOBS})..."
_relocate_all_start=$(date +%s)
relocate_bazel_links "${target_dir}cyber"
relocate_bazel_links "${target_dir}modules"
relocate_bazel_links "${target_dir}third_party"
relocate_bazel_links "${target_dir}external"
_relocate_all_end=$(date +%s)
echo "Relocating bazel links completed in $((_relocate_all_end - _relocate_all_start))s"

# Recursively delete empty directories
echo "Deleting empty directories..."
find "$target_dir" -type d -empty -delete
find "$target_dir" -type d -empty -delete
find "$target_dir" -type d -empty -delete
find "$target_dir" -type d -empty -delete
find "$target_dir" -type d -empty -delete
find "$target_dir" -type d -empty -delete
find "$target_dir" -type d -empty -delete
find "$target_dir" -type d -empty -delete
find "$target_dir" -type d -empty -delete
find "$target_dir" -type d -empty -delete
find "$target_dir" -type d -empty -delete
echo "Empty directory deletion completed."

#4. scripts and tools
echo "Copying scripts and tools..."
# Define source and destination pairs
declare -A file_mappings=(
  ["${TOP_DIR}/scripts/apollo.bashrc"]="${OUTPUT_DIR}/scripts/apollo.bashrc"
  ["${TOP_DIR}/scripts/common.bashrc"]="${OUTPUT_DIR}/scripts/common.bashrc"
  ["${TOP_DIR}/cyber/tools/cyber_tools_auto_complete.bash"]="${OUTPUT_DIR}/cyber/tools/cyber_tools_auto_complete.bash"
  ["${TOP_DIR}/cyber/setup.bash"]="${OUTPUT_DIR}/cyber/setup.bash"
  ["${TOP_DIR}/gaea.bashrc"]="${OUTPUT_DIR}/gaea.bashrc"
)

# Copy each file
for src in "${!file_mappings[@]}"; do
  dest="${file_mappings[$src]}"
  dest_dir=$(dirname "$dest")
  
  # Create destination directory if it doesn't exist
  if [ ! -d "$dest_dir" ]; then
    mkdir -p "$dest_dir"
  fi
  
  # Copy file
  if [ -f "$src" ]; then
    cp "$src" "$dest"
  else
    echo "Warning: Source file not found: $src"
  fi
done

# cp -rP "${TOP_DIR}/scripts/deployment" "${OUTPUT_DIR}/scripts/"
# 0530 fsd package test update
# cp -rP "${TOP_DIR}/scripts/humanoid" "${OUTPUT_DIR}/scripts/"
cp -rP "${TOP_DIR}/scripts" "${OUTPUT_DIR}/"
cp -rP "${TOP_DIR}/tools" "${OUTPUT_DIR}/"
cp -rP "${TOP_DIR}/DEFAULT_CONFIG" "${OUTPUT_DIR}/"
cp -r "${TOP_DIR}/modules" "${OUTPUT_DIR}/"
rm -rf "${OUTPUT_DIR}/modules/ts_hmi/RoboApp"
cp -r "${TOP_DIR}/docker" "${OUTPUT_DIR}/"

echo "Deleting matching modules files *.h, *.cc, *.cpp, *.hpp..."
find "${OUTPUT_DIR}/modules/" \( -type f -o -type l \) \( -name "*.h" -o -name "*.cc" -o -name "*.cpp" -o -name "*.hpp" -o -name "*.c" \) -exec rm -f {} +

# cp -rP "${TOP_DIR}/modules/ts_pnc/ts_local_planner/data" "${OUTPUT_DIR}/modules/ts_pnc/ts_local_planner/"

# mkdir -p "${OUTPUT_DIR}/modules/drivers/tars_djilidar_drivers/conf/aarch64"
# cp -rP "${TOP_DIR}/modules/drivers/tars_djilidar_drivers/conf/aarch64" "${OUTPUT_DIR}/modules/drivers/tars_djilidar_drivers/conf/"

# mkdir -p "${OUTPUT_DIR}/modules/ts_localization/RELOC/init_registration/snapshots"
# cp -r "${TOP_DIR}/modules/ts_localization/RELOC/init_registration/map_knn" "${OUTPUT_DIR}/modules/ts_localization/RELOC/init_registration/"
# cp "${TOP_DIR}/modules/ts_localization/RELOC/init_registration/snapshots/epoch-3.pth.tar" "${OUTPUT_DIR}/modules/ts_localization/RELOC/init_registration/snapshots/"

# mkdir -p "${OUTPUT_DIR}/modules/ts_e2e/ts_nn_plan_py/snapshots/"
# cp "${TOP_DIR}/modules/ts_e2e/ts_nn_plan_py/snapshots/lidar_center_net.onnx" "${OUTPUT_DIR}/modules/ts_e2e/ts_nn_plan_py/snapshots/"

# mkdir -p "${OUTPUT_DIR}/modules/ts_pnc/navigation_planner"
# cp -rP "${TOP_DIR}/modules/ts_pnc/navigation_planner/map" "${OUTPUT_DIR}/modules/ts_pnc/navigation_planner/"

# mkdir -p "${OUTPUT_DIR}/modules/ts_localization/RELOC/relocalization"
# cp -rP "${TOP_DIR}/modules/ts_localization/RELOC/relocalization/map" "${OUTPUT_DIR}/modules/ts_localization/RELOC/relocalization/"

echo "Copying scripts and tools completed!"

# 5. 检查并添加以指定前缀开头的 *.txt 文件
echo "Checking for ${1}.txt files..."
prefix_files=()
while IFS= read -r -d $'\0' file; do
    prefix_files+=("$file")
done < <(find "${TOP_DIR}" -maxdepth 1 -type f -name "${1}.txt" -print0)

if [ ${#prefix_files[@]} -eq 0 ]; then
    echo "Error: No ${1}.txt files found in ${TOP_DIR}."
    exit 1
fi

# 复制前缀文件到输出目录
echo "Copying ${1} files to output directory..."
for file in "${prefix_files[@]}"; do
    cp -v "$file" "${OUTPUT_DIR}/"
    filename=$(basename "$file" .txt)

    echo "大包版本: ${filename}" > "${OUTPUT_DIR}/version.txt"
    echo "打包时commit:" >> "${OUTPUT_DIR}/version.txt"
    cat "$file" >> "${OUTPUT_DIR}/version.txt"
done


#6. compress output as sharded install package
echo "Compressing output..."
cd "${TOP_DIR}"

# ZSTD_THREADS: zstd 并行压缩线程数（环境变量传入，便于 CI 调参）
#   0 = 自动检测全部逻辑核 (zstd -T0)
#   1 = 单线程，与历史行为一致（裸 `zstd` 不加 -T 时等价）
#   N = 显式指定 N 个线程
ZSTD_THREADS="${ZSTD_THREADS:-0}"

# 获取CPU架构
ARCH=$(uname -m)
if [[ $ARCH == "aarch64" || $ARCH == "arm64" ]]; then
    echo "检测到ARM架构，使用zstd压缩 (threads=${ZSTD_THREADS})..."
    rm -rf "${OUTPUT_DIR}/docker"
else
    echo "检测到x86架构，使用zstd压缩 (threads=${ZSTD_THREADS})..."
fi

PACKAGE_NAME="$(basename "$1")"
INSTALL_DIR="${TOP_DIR}/${PACKAGE_NAME}.install"
ARCHIVES_DIR="${INSTALL_DIR}/archives"
OUTER_ARCHIVE="${PACKAGE_NAME}.install.tar"
RUN_FILE="${PACKAGE_NAME}.run"
PAYLOAD_DIR="${TOP_DIR}/${PACKAGE_NAME}.run_payload"
CHECKSUM_FILE="${INSTALL_DIR}/checksums.md5"
MANIFEST_FILE="${INSTALL_DIR}/manifest.json"

rm -rf "$INSTALL_DIR" "$PAYLOAD_DIR" "$OUTER_ARCHIVE" "${OUTER_ARCHIVE}.md5" "$RUN_FILE"
mkdir -p "$ARCHIVES_DIR"

create_shard() {
    local archive_name="$1"
    shift
    local paths=()
    local path
    for path in "$@"; do
        if [ -e "$path" ]; then
            paths+=("$path")
        fi
    done

    if [ "${#paths[@]}" -eq 0 ]; then
        echo "Skipping empty shard: ${archive_name}"
        return 0
    fi

    echo "Creating shard: ${archive_name}"
    tar -I "zstd -T${ZSTD_THREADS}" -cf "${ARCHIVES_DIR}/${archive_name}" "${paths[@]}"
    (cd "$INSTALL_DIR" && md5sum "archives/${archive_name}" >> "$CHECKSUM_FILE")
}

shard_name_from_path() {
    local prefix="$1"
    local path="$2"
    local rel="${path#output/bazel-bin/modules/}"

    rel="${rel//\//-}"
    rel="${rel//_/-}"
    echo "${prefix}-${rel}.tar.zst"
}

create_files_shard() {
    local archive_name="$1"
    shift
    local files=()
    local file

    for file in "$@"; do
        if [ -f "$file" ]; then
            files+=("$file")
        fi
    done

    if [ "${#files[@]}" -eq 0 ]; then
        return 0
    fi

    create_shard "$archive_name" "${files[@]}"
}

create_bazel_modules_shards() {
    local modules_root="output/bazel-bin/modules"
    local shard_prefix="11-bazel-bin-modules"
    local split_threshold_kb=$((512 * 1024))
    local size_kb
    local entry
    local child
    local root_files=()
    local child_root_files=()
    local child_root_archive
    local file

    if [ ! -d "$modules_root" ]; then
        echo "Skipping empty shard group: ${modules_root}"
        return 0
    fi

    while IFS= read -r -d $'\0' file; do
        root_files+=("$file")
    done < <(find "$modules_root" -maxdepth 1 -type f -print0 | sort -z)
    create_files_shard "${shard_prefix}-root.tar.zst" "${root_files[@]}"

    while IFS= read -r -d $'\0' entry; do
        size_kb=$(du -sk "$entry" | awk '{print $1}')
        if [ "$size_kb" -le "$split_threshold_kb" ]; then
            create_shard "$(shard_name_from_path "$shard_prefix" "$entry")" \
                "$entry"
            continue
        fi

        child_root_files=()
        while IFS= read -r -d $'\0' file; do
            child_root_files+=("$file")
        done < <(find "$entry" -maxdepth 1 -type f -print0 | sort -z)
        child_root_archive="$(shard_name_from_path "$shard_prefix" "$entry")"
        child_root_archive="${child_root_archive%.tar.zst}-root.tar.zst"
        create_files_shard \
            "$child_root_archive" \
            "${child_root_files[@]}"

        while IFS= read -r -d $'\0' child; do
            create_shard "$(shard_name_from_path "$shard_prefix" "$child")" \
                "$child"
        done < <(find "$entry" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    done < <(find "$modules_root" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
}

cat > "$MANIFEST_FILE" <<EOF
{
  "format_version": 1,
  "package_name": "${PACKAGE_NAME}",
  "compression": "zstd",
  "root_prefix": "output",
  "archives_dir": "archives"
}
EOF

# checksums.md5 is consumed by tools/decompression.sh. Keep archive paths
# relative to ${PACKAGE_NAME}.install so md5sum -c can verify them in place.
: > "$CHECKSUM_FILE"
(cd "$INSTALL_DIR" && md5sum "manifest.json" >> "$CHECKSUM_FILE")

root_files=("output")
while IFS= read -r -d $'\0' file; do
    root_files+=("$file")
done < <(find output -maxdepth 1 -type f -print0)

echo "Creating shard: 00-root.tar.zst"
tar --no-recursion -I "zstd -T${ZSTD_THREADS}" \
    -cf "${ARCHIVES_DIR}/00-root.tar.zst" "${root_files[@]}"
(cd "$INSTALL_DIR" && md5sum "archives/00-root.tar.zst" >> "$CHECKSUM_FILE")
create_shard "10-bazel-bin-cyber.tar.zst" "output/bazel-bin/cyber"
create_bazel_modules_shards
create_shard "12-bazel-bin-third-party.tar.zst" "output/bazel-bin/third_party"
create_shard "13-bazel-bin-external.tar.zst" "output/bazel-bin/external"
create_shard "14-bazel-bin-deps.tar.zst" "output/bazel-bin/deps"
create_shard "15-bazel-bin-solib.tar.zst" \
    "output/bazel-bin/_solib_local" \
    "output/bazel-bin/_solib_aarch64" \
    "output/bazel-bin/_solib_k8"
create_shard "20-modules.tar.zst" "output/modules"
create_shard "30-cyber.tar.zst" "output/cyber"
create_shard "40-scripts-tools-config.tar.zst" \
    "output/scripts" \
    "output/tools" \
    "output/DEFAULT_CONFIG"
create_shard "50-docker.tar.zst" "output/docker"
# zephyr 流水线段先于 install 写入 awr_power_firmware/（见上方保留逻辑），
# 需显式补分片，否则 --no-recursion 的 00-root 不会收子目录，进不了主包。
create_shard "60-awr-power-firmware.tar.zst" "output/awr_power_firmware"

tar -cf "$OUTER_ARCHIVE" "${PACKAGE_NAME}.install"

# 生成校验文件
echo "Generating checksum file..."
md5sum "$OUTER_ARCHIVE" > "${OUTER_ARCHIVE}.md5"

echo "Generating self-extracting installer..."
mkdir -p "$PAYLOAD_DIR"
cp "${TOP_DIR}/tools/decompression.sh" "${PAYLOAD_DIR}/decompression.sh"
cp "$OUTER_ARCHIVE" "${PAYLOAD_DIR}/${OUTER_ARCHIVE}"
cp "${OUTER_ARCHIVE}.md5" "${PAYLOAD_DIR}/${OUTER_ARCHIVE}.md5"

cat > "$RUN_FILE" <<EOF
#!/usr/bin/env bash
set -e

ARCHIVE_NAME="${OUTER_ARCHIVE}"
PAYLOAD_MARKER="__APOLLO_INSTALL_PAYLOAD_BELOW__"
PAYLOAD_LINE=\$(awk "/^\${PAYLOAD_MARKER}\$/ {print NR + 1; exit 0;}" "\$0")

if [ -z "\$PAYLOAD_LINE" ]; then
    echo "错误: 安装包 payload 不存在"
    exit 1
fi

KILL_ALL_NODE_SCRIPT="/apollo/scripts/humanoid/kill_all_nodes.sh"
if [ -f "\$KILL_ALL_NODE_SCRIPT" ]; then
    echo "检测到节点清理脚本，开始清理已有节点..."
    if ! bash "\$KILL_ALL_NODE_SCRIPT" >/dev/null 2>&1; then
        echo "警告: 节点清理脚本执行失败，继续安装"
    fi
fi

TMP_PARENT="/mnt/gaea/package"
mkdir -p "\$TMP_PARENT"
TMP_DIR=\$(mktemp -d -p "\$TMP_PARENT" ".\${ARCHIVE_NAME}.payload.XXXXXX")
cleanup() {
    rm -rf "\$TMP_DIR"
}
trap cleanup EXIT

echo "准备释放安装 payload 到: \$TMP_DIR"
tail -n +"\$PAYLOAD_LINE" "\$0" | tar --warning=no-timestamp -xf - -C "\$TMP_DIR"
echo "安装 payload 释放完成"
chmod +x "\$TMP_DIR/decompression.sh"
echo "启动解压脚本..."
bash "\$TMP_DIR/decompression.sh" "\$TMP_DIR/\$ARCHIVE_NAME"
exit \$?

__APOLLO_INSTALL_PAYLOAD_BELOW__
EOF

tar -cf - -C "$PAYLOAD_DIR" . >> "$RUN_FILE"
chmod +x "$RUN_FILE"

echo "Installation completed!"
echo "Output: ${RUN_FILE}"

# Top30 大文件
echo "Top 30 largest files in image:"
find output -type f -printf '%s %p\n' | sort -nr | head -30 | awk '{printf "%-6s %s\n", int($1/1024/1024)"M", $2}' > /apollo/scripts/top30_file.txt

#6. clean up
rm -rf "${OUTPUT_DIR:?}"/*
rm -rf "$INSTALL_DIR" "$PAYLOAD_DIR" "$OUTER_ARCHIVE" "${OUTER_ARCHIVE}.md5"
echo "Clean up completed!"
