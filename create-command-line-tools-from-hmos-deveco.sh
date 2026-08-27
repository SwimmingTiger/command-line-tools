#!/usr/bin/env bash
# ============================================================================
# create-command-line-tools-from-hmos-deveco.sh
# 用 DevEco Studio 设备端安装 (/data/app) 的 HarmonyOS 原生二进制合成可在
# HarmonyOS aarch64 设备上运行的 command-line-tools。
#
# 与 create-ohos-command-line-tools.sh 的关系:
#   旧脚本从 openharmony 公共 SDK 组件 zip + arm64 node tar 获取 aarch64 二进制;
#   本脚本不再下载任何 SDK 组件, 而是直接把设备上已安装的 DevEco hnp 包
#   (/data/app 下的 sdk.org/node.org/cdp.org/clangd.org/... ) 里适配设备的
#   aarch64 原生二进制叠加进 linux 基底, 合成结果与旧脚本等价 (可在设备运行)。
#
# 输入 (可用环境变量覆盖):
#   LINUX_ZIP    - commandline-tools-linux-x64-6.1.0.860.zip (基底, 完整版:
#                  JS 工具链 hvigor/ohpm/hstack/codelinter、SDK 头文件/文档/
#                  脚本, 以及 x86-64 主机二进制)
#   DEVECO_ROOT  - DevEco 设备端 hnp 安装根目录 (默认 /data/app)
# 输出:
#   DEST         - 合成结果 (默认 ./output/command-line-tools)
#   FORCE=1      - 目标已存在时覆盖 (默认拒绝, 防止误删正在使用的工具树)
#   STAGE        - 中间目录 (默认 $DEST.stage, 与 DEST 同盘; 完成自动删除)
#   LOG          - 日志文件 (默认 ./output/build.log)
#
# 步骤:
#   1. 解压 linux 工具 (基底)
#   2. 叠加复制设备 SDK (sdk.org/sdk_<v>/default) → sdk/default
#      (openharmony/hms 的 llvm、BiSheng、toolchains、build-tools/cmake、
#      lldb、BinXO、ohos_packing_tool 等全部换为设备 aarch64 版;
#      linux 基底与设备 SDK 同为 6.1.0.105, 版本一致)
#   3. 叠加复制设备 node (node.org/node_<v>) → tool/node (替换 x86-64 node)
#   4. 复制设备独立工具 → tool/<name>/ (cdp/clangd/cmake_lsp_server/
#      dap_server/json5-server-plugin/trace_streamer), 并按 /data/app/bin 的
#      hnp 链接布局在 bin/ 建立符号链接
#   5. llvm 重复文件符号链接化 (md5 校验内容相同后替换)
#   6. hvigor 设备 bug 补丁 (areIdentical / isLinux)
#   7. ld.lld 替换为 --code-sign 包装脚本 (openharmony llvm + hms BiSheng 两处)
#   8. 批量签名全部 aarch64 ELF (ohos-sign-elf)
#   9. hms toolchains 6 个图像库换为 aarch64 musl stub (restool dlopen 需要),
#      并对加载 stub 库的工具重签名 (--resign, 已知: restool)
#   10. 校验 (签名覆盖 + ELF 完整性)
#   11. 扫描 x86-64 ELF 可执行文件并取消执行权限 (基底残留 x64 工具)
#   12. 交付: 移动 $DEST, 清理 STAGE
#
# 设计说明:
#   - hvigor/ohpm/codelinter/hstack 是纯 JS 工具, 保留 linux 基底版本 (完整版,
#     版本 6.23.7 / 6.1.1.830 / 6.0.240 / 5.1.0); 其 arm64 原生插件
#     (hvigor 的 oxc-resolver.linux-arm64-*.node、ohpm 的 tar_rs.linux-arm64-
#     gnu.node) linux 包内已自带, 无需设备版本。hvigor 的设备 bug
#     (areIdentical/isLinux) 由步骤 6 补丁修复。
#   - 设备 /data/app 里的二进制已在设备上运行 (系统签名, .note.ohos.ident),
#     但复制后内核不再接受其原签名 (fs-verity 元数据不随复制), 需在步骤 8
#     用 self-sign.py 统一注入 .codesign 段自签 (与旧脚本产物一致)。
#   - hms BiSheng 保留设备的真实编译器 (bisheng-clang 等真实文件, 不符号链接
#     到普通 clang); 叠加用 tar --overwrite, 避免基底 zip 的别名符号链接导致
#     cp"穿透"写入而保留链接 (详见步骤 2 注释)。
#   - 设备 sdk 缺的 x86-64 工具 (idl/diff/hnpcli/glslang_validator/
#     spirv-remap/Previewer 等) 保留 linux 基底版本, 由步骤 11 取消执行权限。
#   - 所有复制均为"叠加覆盖": 设备文件覆盖同名文件, 基底其他文件保留不删。
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/output"

DOWNLOADS="${DOWNLOADS:-$SCRIPT_DIR/Downloads}"
LINUX_ZIP="${LINUX_ZIP:-$DOWNLOADS/commandline-tools-linux-x64-6.1.0.860.zip}"
DEVECO_ROOT="${DEVECO_ROOT:-/data/app}"
DEST="${DEST:-$BUILD_DIR/command-line-tools}"
STAGE="${STAGE:-$BUILD_DIR/command-line-tools.stage}"
FORCE="${FORCE:-0}"

LINUX_VERSION="6.1.0.860"

STUB_DIR="$SCRIPT_DIR/stubs"
LOG="${LOG:-$BUILD_DIR/build.log}"

# llvm-objcopy / ohos-sign-elf 所在目录
export PATH="/storage/Users/currentUser/.harmonybrew/bin:/storage/Users/currentUser/.local/bin:$PATH"

# ohos-sign-elf.py: 优先仓库根 (旧布局), 回退 ohos-bst-light 子模块 (新布局)
if [ -z "${OHOS_SIGN_ELF:-}" ]; then
    if [ -f "$SCRIPT_DIR/ohos-sign-elf.py" ]; then
        OHOS_SIGN_ELF="$SCRIPT_DIR/ohos-sign-elf.py"
    else
        OHOS_SIGN_ELF="$SCRIPT_DIR/ohos-bst-light/ohos-sign-elf.py"
    fi
fi
X64_UNEXEC_ELF="${X64_UNEXEC_ELF:-$SCRIPT_DIR/ohos-chmod-x64-elf.py}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "错误: $*"; exit 1; }

# 解析 hnp 包目录: hnp_dir <pkg.org> → 该包第一个 <name>_<version> 目录 (无尾斜杠)
hnp_dir() {
    local d
    d="$(ls -d "$DEVECO_ROOT/$1"/*/ 2>/dev/null | head -1 || true)"
    [ -n "$d" ] && [ -d "$d" ] && printf '%s' "${d%/}"
}

# ---------------- 输入检查 ----------------
mkdir -p "$DOWNLOADS"
# output 可能是指向外部目录 (如 f2fs) 的符号链接; mkdir -p 无法穿过悬空符号链接,
# 先解析目标再创建。
if [ -L "$BUILD_DIR" ]; then
    mkdir -p "$(readlink -f "$BUILD_DIR")"
else
    mkdir -p "$BUILD_DIR"
fi
[ -f "$LINUX_ZIP" ] || die "缺少输入文件: $LINUX_ZIP"
[ -d "$DEVECO_ROOT" ] || die "缺少 DevEco hnp 根目录: $DEVECO_ROOT"
[ -d "$STUB_DIR" ] || die "缺少 stub 目录: $STUB_DIR"
[ -f "$OHOS_SIGN_ELF" ] || die "缺少签名脚本: $OHOS_SIGN_ELF"
[ -f "$X64_UNEXEC_ELF" ] || die "缺少 $X64_UNEXEC_ELF"
for pkg in sdk.org node.org cdp.org clangd.org cmake_lsp_server.org \
           dap_server.org json5-server-plugin.org trace_streamer.org; do
    [ -n "$(hnp_dir "$pkg")" ] || die "缺少 hnp 包: $DEVECO_ROOT/$pkg"
done
if [ -e "$DEST" ]; then
    if [ "$FORCE" != "1" ]; then
        die "目标已存在: $DEST (确认覆盖请设 FORCE=1)"
    fi
    log "FORCE=1, 将覆盖 $DEST"
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
TOOLS="$STAGE/command-line-tools"

# workaround with brew bash + cat and cp issue
# brew cat 会导致 cat: -: Broken pipe 报错，详见: https://atomgit.com/org/Harmonybrew/discussions/6
# brew cp 曾导致 WineHua 的 libffi.so.8 复制失败并得到损坏的文件，报错如下：
# cp: error deallocating '……/WineHua/entry/libs/arm64-v8a/libffi.so.8': Permission denied
# 并且报错后cp依然以状态码0退出，所以编译不会失败，但最终复制的 so 库会被截断。
# 虽然本项目可能不会出现该问题，但最好避免使用 brew cp。
CAT_PATH="$(command -v cat)"
CP_PATH="$(command -v cp)"
if [ "$CAT_PATH" = "$(brew --prefix)/bin/cat" ] || [ "$CP_PATH" = "$(brew --prefix)/bin/cp" ]; then
    echo "调整 PATH 让系统 cat 和 cp 命令优先级更高，避免 brew 的 cat 和 cp 命令导致编译失败"
    set -x
    mkdir -p "$BUILD_DIR/ohos-bin"
    ln -sf /usr/bin/cat "$BUILD_DIR/ohos-bin/"
    ln -sf /usr/bin/cp "$BUILD_DIR/ohos-bin/"
    export PATH="$BUILD_DIR/ohos-bin:$PATH"
    { set +x; } 2>/dev/null
fi

# ---------------- 1. 解压 linux 基础工具 ----------------
log "==> 1/12 解压 linux command-line-tools ($LINUX_VERSION)"
unzip -q "$LINUX_ZIP" -d "$STAGE" || die "解压 linux zip 失败"
[ -d "$TOOLS" ] || die "zip 内未找到 command-line-tools/ 目录"

# ---------------- 2. 叠加复制设备 SDK → sdk/default ----------------
log "==> 2/12 叠加设备 SDK 到 sdk/default (openharmony/hms 原生二进制)"
DEVECO_SDK="$(hnp_dir sdk.org)/default"
[ -d "$DEVECO_SDK" ] || die "设备 SDK 目录异常: $DEVECO_SDK"
log "    设备 SDK: $DEVECO_SDK"
# 用 tar --overwrite 叠加: 基底 zip 的 llvm/BiSheng 里别名是符号链接
# (bisheng-clang -> clang-15、clang -> bisheng-clang 等), 普通 cp 遇到已存在
# 的符号链接会"穿透"链接把内容写入目标文件、保留链接; --overwrite 则先删
# 链接再写真实文件, 保证 BiSheng 保留真正的 bisheng-clang 编译器 (与设备
# /data/app 布局一致), 不被降级成指向普通 clang 的符号链接。
# 叠加语义不变: 只覆盖 tar 内同名条目, 基底其他文件保留不删。
tar -C "$DEVECO_SDK" -cf - . | tar -C "$TOOLS/sdk/default" --overwrite -xf -
# 关键二进制存在性抽查 (叠加覆盖后应为设备 aarch64 版)
for f in \
    "sdk/default/openharmony/native/llvm/bin/clang" \
    "sdk/default/openharmony/toolchains/hdc" \
    "sdk/default/hms/native/BiSheng/bin/clang-15" \
    "sdk/default/openharmony/native/build-tools/cmake/bin/cmake" \
    "sdk/default/openharmony/toolchains/lib/binary-sign-tool"; do
    [ -e "$TOOLS/$f" ] || die "设备 SDK 叠加后缺少: $f"
done
# 防回退: BiSheng 的 bisheng-clang 必须是真实文件 (设备有真正的 BiSheng 编译器)
[ -L "$TOOLS/sdk/default/hms/native/BiSheng/bin/bisheng-clang" ] \
    && die "BiSheng bisheng-clang 仍是符号链接 (叠加未替换成功)"

# ---------------- 3. 叠加复制设备 node → tool/node ----------------
log "==> 3/12 叠加设备 node 到 tool/node (替换 x86-64 node)"
DEVECO_NODE="$(hnp_dir node.org)"
log "    设备 node: $DEVECO_NODE"
# 同步骤 2: --overwrite 叠加, 防止基底符号链接被"穿透"写入
tar -C "$DEVECO_NODE" -cf - . | tar -C "$TOOLS/tool/node" --overwrite -xf -
[ -x "$TOOLS/tool/node/bin/node" ] || die "tool/node/bin/node 缺失"

# ---------------- 4. 设备独立工具 → tool/<name>/ + bin/ 符号链接 ----------------
log "==> 4/12 复制设备独立工具到 tool/ 并按 /data/app/bin 布局建立 bin/ 链接"
for spec in "cdp.org|cdp" "clangd.org|clangd" "cmake_lsp_server.org|cmake_lsp_server" \
            "dap_server.org|dap_server" "json5-server-plugin.org|json5-server-plugin" \
            "trace_streamer.org|trace_streamer"; do
    pkg="${spec%%|*}"; name="${spec##*|}"
    src="$(hnp_dir "$pkg")"
    [ -n "$src" ] || die "缺少 hnp 包: $DEVECO_ROOT/$pkg"
    log "    工具: $name ← $src"
    cp -r "$src" "$TOOLS/tool/$name"
done
# 按 /data/app/bin 的 hnp 链接布局建立符号链接 (目标缺失时跳过, 避免悬空链接)
# 注意: 相对目标以 bin/ 为基准解析, 存在性检查同样从 bin/ 出发
# (即 $TOOLS/bin/$target)。
ln_safe() {
    local link="$1" target="$2"
    if [ -e "$TOOLS/bin/$target" ] || [ -L "$TOOLS/bin/$target" ]; then
        ln -s "$target" "$TOOLS/bin/$link"
    else
        log "    跳过符号链接 (目标不存在): bin/$link -> $target"
    fi
}
ln_safe node "../tool/node/bin/node"
ln_safe npm "../tool/node/lib/node_modules/npm/bin/npm-cli.js"
ln_safe npx "../tool/node/lib/node_modules/npm/bin/npx-cli.js"
ln_safe corepack "../tool/node/lib/node_modules/corepack/dist/corepack.js"
ln_safe clangd "../tool/clangd/clangd"
ln_safe cdp "../tool/cdp/bin/cdp"
ln_safe cdp.d "../tool/cdp/bin/cdp.d"
ln_safe log4rs.yaml "../tool/cdp/bin/log4rs.yaml"
ln_safe cmake_lsp_server "../tool/cmake_lsp_server/cmake_lsp_server"
ln_safe dap_server "../tool/dap_server/dap_server"
ln_safe json5-server-plugin "../tool/json5-server-plugin/json5-server-plugin"
ln_safe hdc "../sdk/default/openharmony/toolchains/hdc"

# ---------------- 5. llvm 重复文件符号链接化 ----------------
# 设备 SDK 的 llvm 把符号链接实体化成了文件副本 (clang/clang-15 等各 109MB),
# 参照 harmonybrew-core ohos-sdk.rb 的 ln_map 做法, 用固定映射表把
# 内容完全相同的重复文件换回符号链接 (减小体积, 行为不变:
# clang/lld 等按 argv[0] 分发, 符号链接名保留原名)。
# 注意: 只处理已核对内容相同的对; ld.lld 由后续包装脚本步骤处理, 不在此表。
llvm_dedup() {
    local dir="$1"; shift
    local n=0 skip=0 entry link target h1 h2
    for entry in "$@"; do
        link="${entry%%:*}"
        target="${entry##*:}"
        if [ -f "$dir/$link" ] && [ -f "$dir/$target" ]; then
            # 替换前用 md5sum 确认内容相同, 不同则跳过 (防止误伤真实差异文件)
            h1="$(md5sum "$dir/$link" | cut -d' ' -f1)"
            h2="$(md5sum "$dir/$target" | cut -d' ' -f1)"
            if [ "$h1" != "$h2" ]; then
                log "    跳过 (md5 不同): $link vs $target"
                skip=$((skip+1))
                continue
            fi
            rm -f "$dir/$link"
            ln -s "$target" "$dir/$link"
            n=$((n+1))
        fi
    done
    log "    符号链接化 $n 个, 跳过 $skip 个: $dir"
}
log "==> 5/12 llvm 重复文件符号链接化"
llvm_dedup "$TOOLS/sdk/default/openharmony/native/llvm/bin" \
    "clang:clang-15" "clang++:clang-15" "clang-cl:clang-15" "clang-cpp:clang-15" \
    "ld64.lld:lld" "lld-link:lld" \
    "llvm-addr2line:llvm-symbolizer" \
    "llvm-lib:llvm-ar" "llvm-ranlib:llvm-ar" \
    "llvm-readelf:llvm-readobj" "llvm-strip:llvm-objcopy"
llvm_dedup "$TOOLS/sdk/default/openharmony/native/llvm/lib" \
    "libLLVM.so:libLLVM-15.so" "libLLVM-15.0.4.so:libLLVM-15.so" \
    "libclang.so.15:libclang.so.15.0.4" \
    "liblldb.so.15:liblldb.so.15.0.4" \
    "liblldbIntelFeatures.so:liblldbIntelFeatures.so.15" \
    "libgomp.so:libomp.so" "libiomp5.so:libomp.so" \
    "libxml2.so:libxml2.so.2.14.0" "libxml2.so.16:libxml2.so.2.14.0"

# ---------------- 6. hvigor 设备 bug 补丁 ----------------
# 6a. areIdentical: 设备 f2fs 的 stat 返回 dev=0, 原判断 e.dev===t.dev 恒真且
#     e.ino 为 0 时误判"文件相同"而跳过复制 (hvigor 报错/产物缺失)。
patch_areIdentical() {
    python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "static areIdentical(t,e){return e.ino&&e.dev&&e.ino===t.ino&&e.dev===t.dev}"
new = "static areIdentical(t,e){return !!e.ino&&e.ino===t.ino&&e.dev===t.dev}"
assert old in s, f"path-util.js 未找到待替换片段: {p}"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
print("      patched:", p)
PY
}
# 6b. isLinux: openharmony node 的 os.type() 可能返回 "HarmonyOS" (商业版) 而非
#     "Linux", 导致 hvigor 的 isLinux() 为 false, 平台判断落到 macOS 分支
#     (如加载 libimage_transcoder_shared.dylib 而非 .so, 报 path invalid)。
#     同时匹配 os.platform()==="openharmony" (node 构建时定死, 覆盖所有设备,
#     包括将来内核改名的定制版)。当前设备 node 22.7.0 的 os.type() 已是
#     "Linux", 此补丁为兼容性保险。
patch_isLinux() {
    python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = 'function isLinux(){return"Linux"===os_1.default.type()}'
new = ('function isLinux(){return"Linux"===os_1.default.type()'
       '||"HarmonyOS"===os_1.default.type()'
       '||"openharmony"===os_1.default.platform()}')
assert old in s, f"system-util.js 未找到 isLinux: {p}"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
print("      patched:", p)
PY
}

# 6c. hvigorw node 解析兼容:
#     - 顶层 bin/hvigorw 会设置 DEVECO_NODE_HOME 指向工具树自带 node, 优先使用
#       (避免继承的 NODE_HOME 指向设备 node 目录时误用不可执行的设备 node);
#     - 设备环境 (如 DevEco) 常把 NODE_HOME 直接指向 node 所在目录
#       (如 /data/app/node.org/node_22.7.0/bin), 而 linux 版 hvigorw 只认
#       "含 bin/ 的 node 根目录" ($NODE_HOME/bin/node), 会误报 invalid
#       directory; 加上设备惯例分支 ($NODE_HOME/node) 两者兼容
#       (设备自带的 hvigorw 正是 ${NODE_HOME}/node 写法)。
patch_hvigorw_nodehome() {
    chmod u+w "$1"   # zip 解出的 hvigorw 为只读 (步骤 8 才统一 chmod)
    python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = ('if [ -n "${NODE_HOME}" ];then\n'
       '   # unix path\n'
       '   if [ -x "${NODE_HOME}/bin/node" ];then\n'
       '      EXECUTABLE_NODE="${NODE_HOME}/bin/node"')
new = ('if [ -n "${DEVECO_NODE_HOME}" ] && [ -x "${DEVECO_NODE_HOME}/bin/node" ];then\n'
       '   # 顶层 bin/hvigorw 设置 DEVECO_NODE_HOME 指向工具树自带 node, 优先使用\n'
       '   EXECUTABLE_NODE="${DEVECO_NODE_HOME}/bin/node"\n'
       'elif [ -n "${NODE_HOME}" ];then\n'
       '   # unix path\n'
       '   if [ -x "${NODE_HOME}/bin/node" ];then\n'
       '      EXECUTABLE_NODE="${NODE_HOME}/bin/node"\n'
       '   # harmonyos 设备惯例: NODE_HOME 直接指向 node 所在目录\n'
       '   elif [ -x "${NODE_HOME}/node" ];then\n'
       '      EXECUTABLE_NODE="${NODE_HOME}/node"')
assert old in s, f"hvigorw 未找到 NODE_HOME 段: {p}"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
print("      patched:", p)
PY
}

log "==> 6/12 hvigor 设备 bug 补丁 (areIdentical / isLinux / hvigorw NODE_HOME)"
patch_areIdentical "$TOOLS/hvigor/hvigor/src/common/util/path-util.js"
patch_isLinux "$TOOLS/hvigor/hvigor/node_modules/@ohos/hvigor-common/src/util/system-util.js"
patch_isLinux "$TOOLS/hvigor/hvigor-ohos-plugin/node_modules/@ohos/hvigor-common/src/util/system-util.js"
patch_hvigorw_nodehome "$TOOLS/hvigor/bin/hvigorw"

# ---------------- 7. ld.lld 包装为 --code-sign ----------------
# OHOS lld 支持 --code-sign (链接产物自签名, 才能在设备上执行)。用包装脚本
# 强制每次链接都带上该参数。exec -a 保持 argv[0] 为 ld.lld (lld 按 argv[0]
# 分发模式, 必须看到 ld.lld 才会进入 ELF 链接模式)。
# openharmony llvm 与 hms BiSheng 各有一份 ld.lld, 都包装 (旧脚本通过把
# BiSheng 工具符号链接到 openharmony 实现同样效果; 本脚本保留真实 BiSheng)。
wrap_ld_lld() {
    local bin="$1"
    [ -x "$bin/lld" ] || { log "    跳过 (无 lld): $bin"; return; }
    rm -f "$bin/ld.lld"   # 签名 ELF 不能原地覆盖, 先删再建
    cat > "$bin/ld.lld" <<'EOF'
#!/bin/sh
exec -a "$0" "$(dirname "$0")/lld" --code-sign "$@"
EOF
    chmod +x "$bin/ld.lld"
    log "    包装: $bin/ld.lld"
}
log "==> 7/12 替换 ld.lld 为 --code-sign 包装脚本"
wrap_ld_lld "$TOOLS/sdk/default/openharmony/native/llvm/bin"
wrap_ld_lld "$TOOLS/sdk/default/hms/native/BiSheng/bin"

# ---------------- 8. 批量签名 ----------------
log "==> 8/12 解除只读属性并批量签名 (ohos-sign-elf)"
# cppaudit/hpaudit 等从 zip 解出为只读, 签名需要写权限
chmod -R u+w "$TOOLS"
# 设备二进制复制后原签名 (fs-verity) 失效, 统一自签; 跳过符号链接;
# x86-64 / 已签名 / 静态库等失败项仅记录不中止 (退出码恒为 0)
"$OHOS_SIGN_ELF" "$TOOLS" >> "$LOG" 2>&1 || true
log "    签名完成 (失败项见日志: x86-64 / 已签名属预期)"

# ---------------- 9. hms 图像库 stub ----------------
log "==> 9/12 编译 hms 图像库 aarch64 stub"
HMS_LIB="$TOOLS/sdk/default/hms/toolchains/lib"
CLANG="$TOOLS/sdk/default/openharmony/native/llvm/bin/clang"
[ -x "$CLANG" ] || die "clang 不可执行: $CLANG"
bash "$STUB_DIR/build-stubs.sh" "$CLANG" "$HMS_LIB"
"$OHOS_SIGN_ELF" "$HMS_LIB" >> "$LOG" 2>&1 || true

# 加载 stub 库的工具需要在 stub 编译并签名后重签名 (--resign),
# 否则 dlopen 会失败 (签名状态不一致, 报 Operation not permitted)。
# 已知: restool (处理资源时 dlopen hms/toolchains/lib 的图像库)。
log "==> 9b/12 重签名加载 stub 库的工具 (--resign)"
STUB_LOADER_TOOLS=(
    "$TOOLS/sdk/default/openharmony/toolchains/restool"
)
for tool in "${STUB_LOADER_TOOLS[@]}"; do
    if [ -f "$tool" ]; then
        log "    重签名: $tool"
        "$OHOS_SIGN_ELF" --resign "$tool" >> "$LOG" 2>&1 || true
    fi
done

# ---------------- 10. 校验 ----------------
log "==> 10/12 校验 ELF 完整性与签名覆盖"
python3 - "$TOOLS" <<'PY' | tee -a "$LOG"
import struct, os, sys
root = sys.argv[1]

def elf_info(d):
    if len(d) < 20 or d[:4] != b"\x7fELF":
        return None
    return struct.unpack_from("<H", d, 0x12)[0], struct.unpack_from("<H", d, 0x10)[0]

def ptload_ok(d):
    if len(d) < 64:
        return False
    phoff = struct.unpack_from("<Q", d, 0x20)[0]
    phentsz = struct.unpack_from("<H", d, 0x36)[0]
    phnum = struct.unpack_from("<H", d, 0x38)[0]
    mx = 0
    for i in range(phnum):
        o = phoff + i * phentsz
        if o + 56 > len(d):
            break
        if struct.unpack_from("<I", d, o)[0] == 1:  # PT_LOAD
            mx = max(mx, struct.unpack_from("<Q", d, o + 8)[0] + struct.unpack_from("<Q", d, o + 32)[0])
    return mx <= len(d)

total = a64 = dyn_exec = missing_sign = truncated = 0
for dp, dn, fns in os.walk(root):
    for fn in fns:
        p = os.path.join(dp, fn)
        if os.path.islink(p):
            continue
        try:
            with open(p, "rb") as f:
                hdr = f.read(64)
                if hdr[:4] != b"\x7fELF":
                    continue
                total += 1
                mach, typ = struct.unpack_from("<H", hdr, 0x12)[0], struct.unpack_from("<H", hdr, 0x10)[0]
                with open(p, "rb") as f2:
                    d = f2.read()
                if not ptload_ok(d):
                    truncated += 1
                    print("  截断:", p)
                    continue
                if mach != 183:      # 仅关注 aarch64
                    continue
                a64 += 1
                if typ not in (2, 3):  # 静态库/目标文件不要求签名
                    continue
                dyn_exec += 1
                if b".codesign" not in d:
                    missing_sign += 1
                    print("  未签名:", p)
        except OSError:
            continue

print(f"ELF 总数={total} aarch64={a64} aarch64 可执行/动态库={dyn_exec} 未签名={missing_sign} 截断={truncated}")
if missing_sign or truncated:
    print("校验失败")
    sys.exit(1)
print("校验通过: 所有 aarch64 可执行/动态库均已签名且完整")
PY

# ---------------- 11. 扫描 x86-64 ELF 可执行文件并取消执行权限 ----------------
# 基底残留的 x64 主机工具在设备上无法运行 (Exec format error), 取消执行权限
# 避免被误调用。调用 ohos-chmod-x64-elf.py (由 ohos-replace-x64-elf.py 复制改造,
# 保留其多线程扫描与 --dry-run/--restore 逻辑; 检测: 64 位 ELF + EM_X86_64 + PT_INTERP)。
log "==> 11/12 扫描 x86-64 ELF 可执行文件并取消执行权限"
python3 "$X64_UNEXEC_ELF" "$TOOLS" | tee -a "$LOG"

# ---------------- 12. 交付 ----------------
log "==> 12/12 交付: $DEST"
if [ -e "$DEST" ]; then
    rm -rf "$DEST"
fi
mv "$TOOLS" "$DEST"
rm -rf "$STAGE"

# 冒烟测试 (非致命): 验证自签链有效 (node/clang 能在设备上执行)
log "==> 冒烟测试 (非致命)"
if "$DEST/tool/node/bin/node" --version >/dev/null 2>&1; then
    log "    node: $("$DEST/tool/node/bin/node" --version)"
else
    log "    node 冒烟测试失败 (签名或依赖问题, 请检查)"
fi
if "$DEST/sdk/default/openharmony/native/llvm/bin/clang" --version >/dev/null 2>&1; then
    log "    clang: $("$DEST/sdk/default/openharmony/native/llvm/bin/clang" --version | head -1)"
else
    log "    clang 冒烟测试失败 (签名或依赖问题, 请检查)"
fi
log "完成: $DEST"
