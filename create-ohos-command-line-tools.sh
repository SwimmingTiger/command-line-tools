#!/usr/bin/env bash
# ============================================================================
# create-ohos-command-line-tools.sh
# 用 SDK 压缩包合成可在 HarmonyOS aarch64 设备上运行的 command-line-tools。
#
# 输入 (可用环境变量覆盖):
#   LINUX_ZIP    - commandline-tools-linux-x64-26.0.0.621.zip (基础, 完整版)
#   OHOS_SDK_TAR - OpenHarmony_7.0.0.38 ohos-sdk-public tar.gz (5 个 linux 组件)
#   NODE_TAR_XZ  - node-v24.14.1-openharmony-arm64.tar.xz (替换 x64 node)
# 输出:
#   DEST         - 合成结果 (默认 /data/storage/el2/base/files/command-line-tools)
#   FORCE=1      - 目标已存在时覆盖 (默认拒绝, 防止误删正在使用的工具树)
#   LINK_WINE=1  - 额外创建 /storage/Users/currentUser/work/wine/command-line-tools 符号链接
#   STAGE        - 中间目录 (默认 $DEST.stage, 与 DEST 同盘; 完成自动删除)
#   LOG          - 日志文件 (默认本目录 synth.log)
#
# 步骤:
#   1. 解压 linux 工具 (基础)
#   2. 解压 ohos-sdk-public, 3. 解压 arm64 node
#   4. 合并 openharmony 26.0.0.38 组件 (ets/js/native/previewer/toolchains)
#      到 sdk/default/openharmony/ (覆盖 linux 自带的 26.0.0.32; hms 保持 32 不动)
#   5. 替换 tool/node 为 openharmony arm64 node (自带 node 是 x86-64, 设备跑不了)
#   6. hvigor 3 处设备 bug 补丁 (areIdentical / getArkVersion / worker-pool)
#   7. BiSheng (hms) x86-64 bin 工具替换为 openharmony aarch64 llvm 符号链接
#   8. hms toolchains 6 个图像库换为 aarch64 musl stub (restool dlopen 需要)
#   9. 批量签名全部 aarch64 ELF (ohos-sign-elf), 并校验签名/完整性
#   交付: 移动 $DEST, 清理 STAGE
#
# 说明: 产物放在 f2fs (/data/storage/el2/base/files) 而非 HMDFS
#       (/storage/Users/currentUser), 因 HMDFS 对未签名 ELF 的执行有限制,
#       且 GNU coreutils cp 写 HMDFS 存在截断问题 (详见 README.md)。
# ============================================================================
set -euo pipefail

DOWNLOADS="${DOWNLOADS:-$PWD/Downloads}"
LINUX_ZIP="${LINUX_ZIP:-$DOWNLOADS/commandline-tools-linux-x64-26.0.0.621.zip}"
OHOS_SDK_TAR="${OHOS_SDK_TAR:-$DOWNLOADS/version-Daily_Version-OpenHarmony_7.0.0.38-20260816_000626-ohos-sdk-public.tar.gz}"
NODE_TAR_XZ="${NODE_TAR_XZ:-$DOWNLOADS/node-v24.14.1-openharmony-arm64.tar.xz}"
DEST="${DEST:-$PWD/command-line-tools}"
STAGE="${STAGE:-$DEST.stage}"
FORCE="${FORCE:-0}"
LINK_WINE="${LINK_WINE:-0}"

OHOS_VERSION="26.0.0.38"
LINUX_VERSION="26.0.0.621"
NODE_VERSION="24.14.1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUB_DIR="$SCRIPT_DIR/stubs"
LOG="${LOG:-$SCRIPT_DIR/synth.log}"

# binary-sign-tool / llvm-objcopy / ohos-sign-elf 所在目录
export PATH="/storage/Users/currentUser/.harmonybrew/bin:/storage/Users/currentUser/.local/bin:$PATH"
OHOS_SIGN_ELF="${OHOS_SIGN_ELF:-ohos-sign-elf}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { log "错误: $*"; exit 1; }

# ---------------- 输入检查 ----------------
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

# ---------------- 1. 解压 linux 基础工具 ----------------
log "==> 1/9 解压 linux command-line-tools ($LINUX_VERSION)"
unzip -q "$LINUX_ZIP" -d "$STAGE" || die "解压 linux zip 失败"
[ -d "$TOOLS" ] || die "zip 内未找到 command-line-tools/ 目录"

# ---------------- 2. 解压 ohos-sdk-public ----------------
log "==> 2/9 解压 ohos-sdk-public ($OHOS_VERSION) linux 组件"
OHOS_DIR="$STAGE/ohos-public"
mkdir -p "$OHOS_DIR"
tar -xzf "$OHOS_SDK_TAR" -C "$OHOS_DIR" "ohos-sdk/linux" || die "解压 ohos-sdk tar.gz 失败"

# ---------------- 3. 解压 arm64 node ----------------
log "==> 3/9 解压 openharmony arm64 node ($NODE_VERSION)"
NODE_DIR="$STAGE/node"
mkdir -p "$NODE_DIR"
tar -xJf "$NODE_TAR_XZ" -C "$NODE_DIR" || die "解压 node tar.xz 失败"
NODE_ROOT="$(find "$NODE_DIR" -maxdepth 1 -type d -name 'node-v*' | head -1)"
[ -n "$NODE_ROOT" ] || die "node 包内未找到 node-v* 目录"

# ---------------- 4. 合并 openharmony 组件 ----------------
log "==> 4/9 合并 openharmony 组件到 sdk/default/openharmony"
for c in ets js native previewer toolchains; do
    cz="$OHOS_DIR/ohos-sdk/linux/${c}-linux-x64-${OHOS_VERSION}-Beta.zip"
    [ -f "$cz" ] || die "缺少组件: $cz"
    log "    组件: $c"
    rm -rf "$STAGE/comp-$c"
    mkdir -p "$STAGE/comp-$c"
    unzip -q "$cz" -d "$STAGE/comp-$c" || die "解压组件 $c 失败"
    [ -d "$STAGE/comp-$c/$c" ] || die "组件 $c 顶层目录异常"
    rm -rf "$TOOLS/sdk/default/openharmony/$c"
    cp -a "$STAGE/comp-$c/$c" "$TOOLS/sdk/default/openharmony/$c"
done

# ---------------- 5. 替换 tool/node ----------------
log "==> 5/9 替换 tool/node 为 arm64 node"
rm -rf "$TOOLS/tool/node"
cp -a "$NODE_ROOT" "$TOOLS/tool/node"

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

log "==> 6/9 hvigor 设备 bug 补丁"
patch_areIdentical "$TOOLS/hvigor/hvigor/src/common/util/path-util.js"
patch_getArkVersion "$TOOLS/hvigor/hvigor-ohos-plugin/src/sdk/impl/ets-ark-component.js"
patch_worker "$TOOLS/hvigor/hvigor-ohos-plugin/src/tasks/abstract-build-native.js"

# ---------------- 7. BiSheng x86-64 工具替换 ----------------
# hms BiSheng 的 bin 工具是 x86-64 glibc ELF (设备无法运行) 且无法签名;
# 对每个在 openharmony llvm bin 中存在同名 aarch64 工具者, 替换为相对符号链接。
log "==> 7/9 BiSheng x86-64 工具替换为 openharmony aarch64 符号链接"
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

# ---------------- 8. hms 图像库 stub ----------------
log "==> 8/9 编译 hms 图像库 aarch64 stub"
HMS_LIB="$TOOLS/sdk/default/hms/toolchains/lib"
CLANG="$TOOLS/sdk/default/openharmony/native/llvm/bin/clang"
[ -x "$CLANG" ] || die "clang 不可执行: $CLANG"
bash "$STUB_DIR/build-stubs.sh" "$CLANG" "$HMS_LIB"

# ---------------- 9. 批量签名 + 校验 ----------------
log "==> 9/9 解除只读属性并批量签名 (ohos-sign-elf)"
# cppaudit/hpaudit 等从 zip 解出为只读, 签名需要写权限
chmod -R u+w "$TOOLS"
# 跳过符号链接; x86-64 / 已签名 / 静态库等失败项仅记录不中止 (退出码恒为 0)
"$OHOS_SIGN_ELF" "$TOOLS" >> "$LOG" 2>&1 || true
log "    签名完成 (失败项见日志: x86-64 / 已签名属预期)"

log "==> 校验: ELF 完整性与签名覆盖"
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

# ---------------- 交付 ----------------
log "==> 交付: $DEST"
if [ -e "$DEST" ]; then
    rm -rf "$DEST"
fi
mv "$TOOLS" "$DEST"
if [ "$LINK_WINE" = "1" ]; then
    WINE_LINK="/storage/Users/currentUser/work/wine/command-line-tools"
    ln -sfn "$DEST" "$WINE_LINK"
    log "已创建符号链接: $WINE_LINK -> $DEST"
fi
rm -rf "$STAGE"
log "完成: $DEST"
