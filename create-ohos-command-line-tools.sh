#!/usr/bin/env bash
# ============================================================================
# create-ohos-command-line-tools.sh
# 用 SDK 压缩包合成可在 HarmonyOS aarch64 设备上运行的 command-line-tools。
#
# 输入 (可用环境变量覆盖):
#   LINUX_ZIP    - commandline-tools-linux-x64-26.0.0.621.zip (基础, 完整版)
#   OHOS_SDK_TAR - ohos-sdk-public_ohos tar.gz (Master 20260330, 组件 26.0.0.18-Beta,
#                  5 个 ohos 平台组件; 文件缺失且设了 OHOS_SDK_URL 时自动下载)
#   NODE_TAR_XZ  - node-v24.14.1-openharmony-arm64.tar.xz (替换 x64 node)
# 输出:
#   DEST         - 合成结果 (默认 ./output/command-line-tools)
#   FORCE=1      - 目标已存在时覆盖 (默认拒绝, 防止误删正在使用的工具树)
#   STAGE        - 中间目录 (默认 $DEST.stage, 与 DEST 同盘; 完成自动删除)
#   LOG          - 日志文件 (默认 ./output/build.log)
#
# 步骤:
#   1. 解压 linux 工具 (基础)
#   2. 解压 ohos-sdk-public_ohos (Master), 3. 覆盖解压 arm64 node 到 tool/node
#       (注意: 组件必须用 *-ohos-x64-* 变体, 其内二进制为 aarch64 musl;
#        master 版 tar 顶层为 ohos/, 旧 daily 版为 ohos-sdk/ohos/, 脚本自动兼容)
#   4. 合并 openharmony 组件 (ets/js/native/previewer/toolchains, 版本自动探测)
#      到 sdk/default/openharmony/ (叠加覆盖: 同名文件被新版替换、新增文件被加入,
#      linux 基底中已有的其他文件保留不删; hms 保持 32 不动)
#   5. llvm 重复文件符号链接化 (md5 校验内容相同后替换, 参照 ohos-sdk.rb ln_map)
#   6. hvigor 3 处设备 bug 补丁 (areIdentical / getArkVersion / worker-pool)
#   7. BiSheng (hms) x86-64 bin 工具替换为 openharmony aarch64 llvm 符号链接
#   8. ld.lld 替换为 --code-sign 包装脚本 (链接产物自签名)
#   9. 批量签名全部 aarch64 ELF (ohos-sign-elf), 并校验签名/完整性
#   10. hms toolchains 6 个图像库换为 aarch64 musl stub (restool dlopen 需要),
#       并对加载 stub 库的工具重签名 (--resign, 已知: restool)
#   11. 校验
#   12. 扫描 x86-64 ELF 可执行文件并取消执行权限 (基底残留 x64 工具, 防止误调用)
#   交付: 移动 $DEST, 清理 STAGE
#
# 所有压缩包统一采用"覆盖解压"策略: 直接解压到目标目录, 同名文件被覆盖,
# 目标中原有的其他文件保留不删。
#
# 说明: 产物放在 f2fs (/data/storage/el2/base/files) 而非 HMDFS
#       (/storage/Users/currentUser), 因 HMDFS 对未签名 ELF 的执行有限制,
#       且 GNU coreutils cp 写 HMDFS 存在截断问题 (详见 README.md)。
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/output"

DOWNLOADS="${DOWNLOADS:-$SCRIPT_DIR/Downloads}"
LINUX_ZIP="${LINUX_ZIP:-$DOWNLOADS/commandline-tools-linux-x64-26.0.0.621.zip}"
OHOS_SDK_TAR="${OHOS_SDK_TAR:-$DOWNLOADS/version-Master_Version-ohos-sdk-public_ohos-20260330_020501-ohos-sdk-public_ohos.tar.gz}"
OHOS_SDK_URL="${OHOS_SDK_URL:-https://cidownload.openharmony.cn/version/Master_Version/ohos-sdk-public_ohos/20260330_020501/version-Master_Version-ohos-sdk-public_ohos-20260330_020501-ohos-sdk-public_ohos.tar.gz}"
NODE_TAR_XZ="${NODE_TAR_XZ:-$DOWNLOADS/node-v24.14.1-openharmony-arm64.tar.xz}"
DEST="${DEST:-$BUILD_DIR/command-line-tools}"
STAGE="${STAGE:-$BUILD_DIR/command-line-tools.stage}"
FORCE="${FORCE:-0}"

LINUX_VERSION="26.0.0.621"
NODE_VERSION="24.14.1"
OHOS_VERSION=""   # 在步骤 2 中从组件 zip 文件名自动探测

STUB_DIR="$SCRIPT_DIR/stubs"
LOG="${LOG:-$BUILD_DIR/build.log}"

# binary-sign-tool / llvm-objcopy / ohos-sign-elf 所在目录
export PATH="/storage/Users/currentUser/.harmonybrew/bin:/storage/Users/currentUser/.local/bin:$PATH"
OHOS_SIGN_ELF="${OHOS_SIGN_ELF:-$SCRIPT_DIR/ohos-sign-elf.py}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "错误: $*"; exit 1; }

# ---------------- 输入检查 ----------------
mkdir -p "$DOWNLOADS"
if [ ! -f "$OHOS_SDK_TAR" ] && [ -n "${OHOS_SDK_URL:-}" ]; then
    log "下载 ohos-sdk:"
    log "  $OHOS_SDK_URL"
    curl -L --fail -C - -o "$OHOS_SDK_TAR" "$OHOS_SDK_URL" || die "下载 ohos-sdk 失败"
fi
for f in "$LINUX_ZIP" "$OHOS_SDK_TAR" "$NODE_TAR_XZ"; do
    [ -f "$f" ] || die "缺少输入文件: $f"
done
[ -d "$STUB_DIR" ] || die "缺少 stub 目录: $STUB_DIR"
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
log "==> 1/10 解压 linux command-line-tools ($LINUX_VERSION)"
unzip -q "$LINUX_ZIP" -d "$STAGE" || die "解压 linux zip 失败"
[ -d "$TOOLS" ] || die "zip 内未找到 command-line-tools/ 目录"

# ---------------- 2. 解压 ohos-sdk-public_ohos ----------------
log "==> 2/10 解压 ohos-sdk-public_ohos (Master) 组件"
OHOS_DIR="$STAGE/ohos-public"
mkdir -p "$OHOS_DIR"
# 兼容两种打包: 旧 daily 版是 ohos-sdk/ohos/..., 新 master 版是顶层 ohos/...
if tar -tzf "$OHOS_SDK_TAR" 2>/dev/null | grep -qm1 "^ohos-sdk/ohos/"; then
    tar -xzf "$OHOS_SDK_TAR" -C "$OHOS_DIR" "ohos-sdk/ohos" || die "解压 ohos-sdk tar.gz 失败"
    COMP_DIR="$OHOS_DIR/ohos-sdk/ohos"
else
    tar -xzf "$OHOS_SDK_TAR" -C "$OHOS_DIR" "ohos" || die "解压 ohos-sdk tar.gz 失败"
    COMP_DIR="$OHOS_DIR/ohos"
fi
NATIVE_ZIP="$(ls "$COMP_DIR"/native-ohos-x64-*.zip 2>/dev/null | head -1 || true)"
[ -n "$NATIVE_ZIP" ] || die "tar 中未找到 native-ohos-x64-*.zip 组件"
OHOS_VERSION="$(basename "$NATIVE_ZIP" | sed -E 's/.*-ohos-x64-([0-9.]+)-.*/\1/')"
log "    组件版本: $OHOS_VERSION (来自 $COMP_DIR)"

# ---------------- 3. 覆盖解压 arm64 node 到 tool/node ----------------
log "==> 3/10 覆盖解压 openharmony arm64 node ($NODE_VERSION) 到 tool/node"
# 与组件合并同策略: 同名文件被 arm64 node 覆盖 (bin/node 等),
# linux 基底 tool/node 中已有的其他文件保留不删。
# --strip-components=1 去掉 tar 顶层目录 (node-v24.14.1-openharmony-arm64/)。
mkdir -p "$TOOLS/tool/node"
tar -xJf "$NODE_TAR_XZ" -C "$TOOLS/tool/node" --strip-components=1 || die "解压 node tar.xz 失败"
[ -x "$TOOLS/tool/node/bin/node" ] || die "tool/node/bin/node 缺失"

# ---------------- 4. 合并 openharmony 组件 (叠加覆盖) ----------------
log "==> 4/10 合并 openharmony 组件到 sdk/default/openharmony (叠加覆盖)"
for c in ets js native previewer toolchains; do
    cz="$(ls "$COMP_DIR"/${c}-ohos-x64-*.zip 2>/dev/null | head -1 || true)"
    [ -n "$cz" ] && [ -f "$cz" ] || die "缺少组件 $c: $COMP_DIR 下无 ${c}-ohos-x64-*.zip"
    log "    组件: $c ($(basename "$cz"))"
    # 叠加合并: zip 顶层目录名 == 组件目录名, 直接解压覆盖到 openharmony/ 下。
    # 同名文件被新组件覆盖, 新组件独有的文件被加入, linux 基底中已有的其他
    # 文件全部保留 (不删除原有内容)。
    mkdir -p "$TOOLS/sdk/default/openharmony"
    unzip -o -q "$cz" -d "$TOOLS/sdk/default/openharmony" || die "解压组件 $c 失败"
    [ -f "$TOOLS/sdk/default/openharmony/$c/oh-uni-package.json" ] || die "组件 $c 顶层目录异常 (缺少 oh-uni-package.json)"
done

# ---------------- 5. llvm 重复文件符号链接化 ----------------
# 官方包把符号链接实体化成了文件副本 (clang/clang-15 等各 109MB),
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
log "==> 5/11 llvm 重复文件符号链接化"
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
# 6.1 areIdentical: 设备 f2fs 的 stat 返回 dev=0, 原判断 e.dev===t.dev 恒真且
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
# 6.2 getArkVersion: hvigor 会 spawn ts2abc 探测 ark 版本, 在设备上经常失败;
#     直接固定返回 13.0.1.0。
patch_getArkVersion() {
    python3 - "$1" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
m = re.search(r"getArkVersion\(e,t\)\{.*?\}\}exports\.EtsArkComponent", s, re.S)
assert m, f"ets-ark-component.js 未找到 getArkVersion: {p}"
new = 'getArkVersion(e,t){return"13.0.1.0"}}exports.EtsArkComponent'
open(p, "w", encoding="utf-8").write(s[:m.start()] + new + s[m.end():])
print("      patched:", p)
PY
}
# 6.3 worker-pool: hvigor 在设备上用 worker 线程池执行 native 命令时
#     libentry.so 会消失 (worker 目录遍历 bug), 绕过 worker 直接执行。
patch_worker() {
    python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "if(this.getWorkerPool().submit(this,l,s).getState()===hvigor_1.TaskState.REJECT){"
new = "if(true/*worker-bypass*/){"
assert old in s, f"abstract-build-native.js 未找到 worker 分支: {p}"
open(p, "w", encoding="utf-8").write(s.replace(old, new))
print("      patched:", p)
PY
}

log "==> 6/11 hvigor 设备 bug 补丁"
patch_areIdentical "$TOOLS/hvigor/hvigor/src/common/util/path-util.js"
patch_getArkVersion "$TOOLS/hvigor/hvigor-ohos-plugin/src/sdk/impl/ets-ark-component.js"
patch_worker "$TOOLS/hvigor/hvigor-ohos-plugin/src/tasks/abstract-build-native.js"

# ---------------- 7. BiSheng x86-64 工具替换 ----------------
# hms BiSheng 的 bin 工具是 x86-64 glibc ELF (设备无法运行) 且无法签名;
# 对每个在 openharmony llvm bin 中存在同名 aarch64 工具者, 替换为相对符号链接。
log "==> 7/11 BiSheng x86-64 工具替换为 openharmony aarch64 符号链接"
BISHENG_BIN="$TOOLS/sdk/default/hms/native/BiSheng/bin"
OH_LLVM_BIN="$TOOLS/sdk/default/openharmony/native/llvm/bin"
n=0
for f in "$BISHENG_BIN"/*; do
    [ -f "$f" ] || continue                     # 跳过 zip 自带的符号链接/目录
    b="$(basename "$f")"
    [ -e "$OH_LLVM_BIN/$b" ] || continue        # openharmony 无同名工具则保留
    if ! head -c 4 "$f" | od -An -tx1 | grep -q "7f 45 4c 46"; then continue; fi
    mach="$(od -An -tu2 -j 18 -N 2 "$f" | tr -d ' ')"
    [ "$mach" = "62" ] || continue              # EM_X86_64 才替换
    rm -f "$f"
    # BiSheng/bin → sdk/default/hms/native/BiSheng/bin, 上溯 4 级到 sdk/default
    ln -s "../../../../openharmony/native/llvm/bin/$b" "$f"
    n=$((n+1))
done
log "    替换 $n 个工具 (预期 35 个)"

# ---------------- 8. ld.lld 包装为 --code-sign ----------------
# OHOS lld 支持 --code-sign (链接产物自签名, 才能在设备上执行)。用包装脚本
# 强制每次链接都带上该参数。exec -a 保持 argv[0] 为 ld.lld (lld 按 argv[0]
# 分发模式, 必须看到 ld.lld 才会进入 ELF 链接模式)。
log "==> 8/11 替换 ld.lld 为 --code-sign 包装脚本"
LLD_WRAPPER="$TOOLS/sdk/default/openharmony/native/llvm/bin/ld.lld"
[ -x "$TOOLS/sdk/default/openharmony/native/llvm/bin/lld" ] || die "缺少 lld, 包装脚本无法工作"
rm -f "$LLD_WRAPPER"   # 签名 ELF 不能原地覆盖, 先删再建
cat > "$LLD_WRAPPER" <<'EOF'
#!/bin/sh
exec -a "$0" "$(dirname "$0")/lld" --code-sign "$@"
EOF
chmod +x "$LLD_WRAPPER"

# ---------------- 9. 批量签名 ----------------
log "==> 9/11 解除只读属性并批量签名 (ohos-sign-elf)"
# cppaudit/hpaudit 等从 zip 解出为只读, 签名需要写权限
chmod -R u+w "$TOOLS"
# 跳过符号链接; x86-64 / 已签名 / 静态库等失败项仅记录不中止 (退出码恒为 0)
"$OHOS_SIGN_ELF" "$TOOLS" >> "$LOG" 2>&1 || true
log "    签名完成 (失败项见日志: x86-64 / 已签名属预期)"

# ---------------- 10. hms 图像库 stub ----------------
log "==> 10/11 编译 hms 图像库 aarch64 stub"
HMS_LIB="$TOOLS/sdk/default/hms/toolchains/lib"
CLANG="$TOOLS/sdk/default/openharmony/native/llvm/bin/clang"
[ -x "$CLANG" ] || die "clang 不可执行: $CLANG"
bash "$STUB_DIR/build-stubs.sh" "$CLANG" "$HMS_LIB"
"$OHOS_SIGN_ELF" "$HMS_LIB" >> "$LOG" 2>&1 || true

# 加载 stub 库的工具需要在 stub 编译并签名后重签名 (--resign),
# 否则 dlopen 会失败 (签名状态不一致, 报 Operation not permitted)。
# 已知: restool (处理资源时 dlopen hms/toolchains/lib 的图像库)。
log "==> 10b/11 重签名加载 stub 库的工具 (--resign)"
STUB_LOADER_TOOLS=(
    "$TOOLS/sdk/default/openharmony/toolchains/restool"
)
for tool in "${STUB_LOADER_TOOLS[@]}"; do
    if [ -f "$tool" ]; then
        log "    重签名: $tool"
        "$OHOS_SIGN_ELF" --resign "$tool" >> "$LOG" 2>&1 || true
    fi
done

# ---------------- 11. 校验 ----------------
log "==> 11/11 校验 ELF 完整性与签名覆盖"
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

# ---------------- 12. 扫描 x86-64 ELF 可执行文件并取消执行权限 ----------------
# 基底残留的 x64 主机工具在设备上无法运行 (Exec format error), 取消执行权限
# 避免被误调用。调用 ohos-chmod-x64-elf.py (由 ohos-replace-x64-elf.py 复制改造,
# 保留其多线程扫描与 --dry-run/--restore 逻辑; 检测: 64 位 ELF + EM_X86_64 + PT_INTERP)。
log "==> 12/12 扫描 x86-64 ELF 可执行文件并取消执行权限"
X64_UNEXEC_ELF="${X64_UNEXEC_ELF:-$SCRIPT_DIR/ohos-chmod-x64-elf.py}"
[ -f "$X64_UNEXEC_ELF" ] || die "缺少 $X64_UNEXEC_ELF"
python3 "$X64_UNEXEC_ELF" "$TOOLS" | tee -a "$LOG"

# ---------------- 交付 ----------------
log "==> 交付: $DEST"
if [ -e "$DEST" ]; then
    rm -rf "$DEST"
fi
mv "$TOOLS" "$DEST"
rm -rf "$STAGE"
log "完成: $DEST"
