#!/usr/bin/env bash
# ============================================================================
# build-stubs.sh — 编译 hms toolchains 图像库的 aarch64 musl stub 并替换原库。
#
# 背景:
#   command-line-tools 的 sdk/default/hms/toolchains/lib/ 下 6 个图像库
#   (libimage_transcoder_shared / libastc_encoder_shared / libastcCustomizedEncode /
#    liblz4_shared / libtextureSuperCompress / libhilog) 原为 x86-64 glibc ELF,
#   在 HarmonyOS aarch64 设备上无法加载。restool 在打包阶段会 dlopen 这些库,
#   因此用同一份源码 (hms_stub.c, 导出与真实库同名的符号, 函数体为空实现)
#   编译为 aarch64 musl 动态库替换。stub 导出全部符号, 满足 dlopen/dlsym。
#
# 用法:
#   build-stubs.sh <clang路径> <输出目录>
#     clang 用 SDK 自带的 OHOS clang (openharmony/native/llvm/bin/clang, 15.0.4)
#
# 产物: 6 个 aarch64 musl .so, 带 SONAME, 编译后由合成脚本统一批量签名。
# ============================================================================
set -euo pipefail

CLANG="${1:?用法: build-stubs.sh <clang路径> <输出目录>}"
OUT="${2:?用法: build-stubs.sh <clang路径> <输出目录>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -x "$CLANG" ] || { echo "clang 不可执行: $CLANG" >&2; exit 1; }
mkdir -p "$OUT"

for name in \
    libimage_transcoder_shared \
    libastc_encoder_shared \
    libastcCustomizedEncode \
    liblz4_shared \
    libtextureSuperCompress \
    libhilog
do
    echo "编译 stub: $name.so"
    "$CLANG" --target=aarch64-linux-ohos -shared -fPIC -O2 \
        -Wl,-soname,"$name.so" \
        "$DIR/hms_stub.c" -o "$OUT/$name.so"
done

echo "完成: $(ls -1 "$OUT"/*.so 2>/dev/null | wc -l) 个 stub 已写入 $OUT"
