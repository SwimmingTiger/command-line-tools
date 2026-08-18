# 合成 HarmonyOS aarch64 可用的 command-line-tools

本目录包含用 SDK 压缩包合成"可在 HarmonyOS aarch64 设备上运行"的
command-line-tools 的全部材料：主脚本、批量签名/去权限脚本、stub 源文件。

## 文件

| 文件 | 说明 |
|---|---|
| `create-ohos-command-line-tools.sh` | 一键合成脚本（12 步，见下） |
| `ohos-sign-elf.py` | 批量签名脚本：多线程扫描 + 签名，**跳过符号链接与 `.o` 目标文件**，支持 `--unsign`/`--resign`/`--dry-run`，内部调用 `self-sign.py`；x86-64 / 已签名等失败项只记录、不中止（被主脚本第 9 步调用） |
| `ohos-chmod-x64-elf.py` | 扫描 x86-64 ELF 可执行文件并取消执行权限（`chmod -x`，`--restore` 还原）。由 `~/work/ohos-script/ohos-replace-x64-elf.py` 复制改造：保留其多线程扫描（`_ScanTracker` + 扫描/处理双线程池，最多 8 线程）与 `--dry-run`/`--restore` 参数，替换逻辑改为去执行位（被主脚本第 12 步调用）。检测：64 位 ELF + `e_machine==EM_X86_64`(62) + 程序头含 `PT_INTERP`（区分 PIE 可执行与共享库） |
| `self-sign.py` | OpenHarmony 二进制自签名实现（纯 Python + hashlib）：注入 4KB 对齐 `.codesign` 段、计算 merkle 根哈希（段所在页叶哈希置 0）、写 fs-verity descriptor + SHA-256 签名；与 binary-sign-tool 产物段级等价。符号链接，指向 `ohos-bst-light/self-sign.py`。被 `ohos-sign-elf.py` 调用 |
| `stubs/hms_stub.c` | hms 图像库 stub 源码（导出与真实库同名符号、空实现） |
| `stubs/build-stubs.sh` | stub 编译脚本（被主脚本第 10 步调用） |

## 输入（放在 `./Downloads/`，或用环境变量指定路径）

| 文件 | 作用 | 下载地址 |
|---|---|---|
| `commandline-tools-linux-x64-26.0.0.621.zip` | 基础（完整版，含 hvigor/ohpm/hstack/codelinter/sdk） | https://developer.huawei.com/consumer/cn/download/command-line-tools-for-hmos |
| `version-Master_Version-ohos-sdk-public_ohos-20260330_020501-ohos-sdk-public_ohos.tar.gz` | 5 个 **ohos 平台**组件：ets/js/native/previewer/toolchains（26.0.0.18-Beta）；文件缺失且设了 `OHOS_SDK_URL` 时自动下载 | https://cidownload.openharmony.cn/version/Master_Version/ohos-sdk-public_ohos/20260330_020501/ |
| `node-v24.14.1-openharmony-arm64.tar.xz` | openharmony arm64 node，替换自带的 x86-64 node | https://github.com/hqzing/ohos-node/releases/tag/v24.14.1 |

## 构建 HarmonyOS Command Line Tools

### 环境要求

- `python3`、`unzip`、`tar`、`md5sum`、`curl`；
- `llvm-objcopy`（仅 `--resign` 时用于剥离旧 `.codesign` 段；脚本会在 `PATH`
  前追加 harmonybrew 与 `~/.local/bin`，请按实际环境准备）；
- 若批量签名脚本不在本目录，可用 `OHOS_SIGN_ELF` 环境变量指定。

> 签名由仓库内 `self-sign.py`（纯 Python）完成，**不需要 binary-sign-tool**。

### 使用步骤

```bash
# 1. 把三个输入压缩包放进 ./Downloads/（或用 LINUX_ZIP/OHOS_SDK_TAR/NODE_TAR_XZ 覆盖）

# 2.（建议）把 output 目录链接到 f2fs 分区，防止文件系统问题（见下文"建议"）
mkdir -p /data/storage/el2/base/files/cmdtools
ln -s /data/storage/el2/base/files/cmdtools ./output

# 3. 运行（产物已存在时需 FORCE=1 覆盖）
bash ./create-ohos-command-line-tools.sh

# 4. 合成结果在 ./output/command-line-tools，全程日志在 ./output/build.log
#    （LOG 环境变量可改日志位置）
```

自定义输入/输出：

```bash
LINUX_ZIP=... OHOS_SDK_TAR=... NODE_TAR_XZ=... \
DEST=/path/to/command-line-tools LOG=/path/to/build.log \
bash ./create-ohos-command-line-tools.sh
```

### 使用 HarmonyOS Command Line Tools 构建鸿蒙项目

```bash
export TOOL_HOME="/path/to/output/command-line-tools"
export OHOS_SDK="$TOOL_HOME/sdk/default/openharmony"
export PATH="$TOOL_HOME/bin:$OHOS_SDK/toolchains/lib:$OHOS_SDK/native/build-tools/cmake/bin:$OHOS_SDK/native/llvm/bin:$PATH"

cd /path/to/harmony-project
hvigorw assembleHap
```

### 建议：把 output 目录链接到 f2fs

脚本的 `output/`（存放中间产物、最终工具树与日志）**建议放在大小写敏感的
文件系统**（f2fs，如 `/data/storage/el2/base/files/`），而不是大小写不敏感
的 HMDFS（`/storage/Users/...`）。

原因：工具树里存在**仅大小写不同**的文件（如 sysroot 内核头
`ip6t_hl.h`/`ip6t_HL.h`、`xt_MARK.h`/`xt_mark.h` 等，共 8 对）。HMDFS 会
把这些文件**合并**（同名互相覆盖），一旦树被放到大小写敏感的文件系统上
运行，引用特定大小写（如 `#include <linux/netfilter/xt_MARK.h>`）就会
找不到文件。

做法：`mkdir -p <f2fs路径> && ln -s <f2fs路径> ./output`，然后正常运行脚本。

## 合成步骤（12 步）

1. 解压 linux command-line-tools（基底，完整版）
2. 解压 ohos-sdk-public_ohos（Master），3. 覆盖解压 arm64 node 到 `tool/node`
4. 合并 openharmony 组件（ets/js/native/previewer/toolchains，版本自动探测）
   ——**叠加覆盖**：zip 直接解压到 `sdk/default/openharmony/`，同名文件被新版
   替换、新文件被加入、基底原有其他文件保留不删
5. llvm 重复文件符号链接化（md5 校验内容相同后替换）
6. hvigor 设备 bug 补丁（areIdentical / isLinux）
7. BiSheng（hms）x86-64 bin 工具替换为 openharmony aarch64 符号链接
8. `ld.lld` 替换为 `--code-sign` 包装脚本（链接产物自签名）
9. 批量签名全部 aarch64 ELF（`ohos-sign-elf.py`）
10. hms toolchains 6 个图像库换为 aarch64 musl stub，并对加载 stub 库的工具
    重签名（`--resign`，已知：restool）
11. 校验（签名覆盖 + ELF 完整性）
12. 扫描 x86-64 ELF 可执行文件并取消执行权限

## 为什么这样做

1. **Linux 版本来就是完整的**：以 linux zip 为基底，不需要 Windows 版补充。
2. **合并 openharmony 组件（版本自动探测，叠加覆盖）**：linux 自带 openharmony
   是 26.0.0.32（Beta2），把更新的 public SDK 组件 zip **直接解压叠加**到
   `sdk/default/openharmony/` 下：同名文件被新版覆盖、新组件独有的文件被加入，
   **linux 基底中已有的其他文件全部保留、不删除**（避免新版组件与旧版相比
   "少掉的"文件被误删）；`hms` 保持 26.0.0.32 不动。
   当前默认使用 **Master 版 `ohos-sdk-public_ohos`**（20260330，组件
   26.0.0.18-Beta），该 tar 只含 ohos 平台组件（顶层 `ohos/`，二进制均为
   aarch64 musl）。脚本对两种打包均兼容：master 版（`ohos/`）与旧 daily 版
   （`ohos-sdk/ohos/`）。⚠️ 若换回 daily 版 tar，必须用 `ohos-sdk/ohos/` 下
   的 `*-ohos-x64-*` 变体（aarch64 musl）；`ohos-sdk/linux/` 的
   `*-linux-x64-*` 变体是 x86-64 主机工具（clang-15/restool/hdc 等均为
   x86-64 glibc），设备上无法执行，stub 编译会报 "cannot execute binary
   file: Exec format error"，BiSheng 替换数也会从 35 变成 47（llvm bin
   工具集不同）。
3. **覆盖解压 tool/node**：自带 node 是 x86-64 ELF（动态链接 glibc），在设备上
   无法运行；将 openharmony 官方 arm64 musl node v24.14.1 覆盖解压到
   `tool/node/`（同名文件如 `bin/node` 被 arm64 版替换，原目录其他文件保留），
   之后 `bin/hvigorw`（原版，自动设置
   `DEVECO_NODE_HOME=$all_tool_dir/tool/node`）即可直接工作。
4. **hvigor 设备 bug 补丁（areIdentical / isLinux）**：
   - `hvigor/hvigor/src/common/util/path-util.js` 的 `areIdentical`：
     设备 f2fs 的 stat 返回 `dev=0`，原判断
     `e.ino&&e.dev&&e.ino===t.ino&&e.dev===t.dev` 在 ino 为 0 时仍可能误判
     "同一文件"而跳过复制 → 改为
     `!!e.ino&&e.ino===t.ino&&e.dev===t.dev`（ino/dev 均非 0 才判同）。
   - `@ohos/hvigor-common` 的 `system-util.js` 的 `isLinux()`：openharmony
     node 的 `os.type()` 返回 `"HarmonyOS"`（商业版）而非 `"Linux"`，导致
     hvigor 把环境当成 macOS（例如加载 `libimage_transcoder_shared.dylib`
     而非 `.so`，报 "path invalid"）→ `isLinux()` 增加对 `"HarmonyOS"` 与
     `os.platform()==="openharmony"` 的匹配（后者是 node 构建时定死的值，
     覆盖所有设备；两个 hvigor-common 副本都要改）。
5. **BiSheng（hms）x86-64 bin 工具 → openharmony 符号链接**：hms 的 BiSheng
   clang/llvm 工具是 x86-64 glibc ELF，设备上无法运行也无法签名；对每个在
   `openharmony/native/llvm/bin` 有同名 aarch64 工具者（master 版 40 个，
   旧 daily 版 35 个）替换为相对符号链接（两套都是 LLVM 15 工具链，接口
   一致）。zip 自带的 BiSheng 内部别名符号链接（`clang -> bisheng-clang ->
   clang-15` 链）保留。
6. **hms 图像库 stub**：`sdk/default/hms/toolchains/lib/` 下 6 个图像库
   （libimage_transcoder_shared / libastc_encoder_shared /
   libastcCustomizedEncode / liblz4_shared / libtextureSuperCompress /
   libhilog）原为 x86-64 glibc，restool 在打包时会 dlopen 它们 → 用
   `hms_stub.c`（导出同名符号、空实现）编译成 aarch64 musl 动态库替换。
   编译命令（SDK 自带 OHOS clang 15.0.4）：
   ```
   clang --target=aarch64-linux-ohos -shared -fPIC -O2 \
         -Wl,-soname,<lib名>.so hms_stub.c -o <lib名>.so
   ```
   加载这些 stub 库的工具（已知：`openharmony/toolchains/restool`，处理资源时
   dlopen 图像库）需要在 stub 编译并签名后**重签名（`--resign`）**，否则
   dlopen 报 `Operation not permitted`（签名状态不一致）。
7. **ld.lld 包装为 --code-sign**：OHOS lld 支持 `--code-sign`（链接产物
   自签名，才能在设备上执行）。把 `openharmony/native/llvm/bin/ld.lld`
   换成包装脚本：
   ```sh
   #!/bin/sh
   exec -a "$0" "$(dirname "$0")/lld" --code-sign "$@"
   ```
   `exec -a` 保持 argv[0] 为 `ld.lld`（lld 按 argv[0] 分发模式，必须是
   ld.lld 才进入 ELF 链接模式）。注意：签名后的 ELF 不能原地覆盖
   （Operation not permitted），需先 `rm -f` 再重建。

   另：master 版 SDK 的 llvm 打包时**没有符号链接**（`clang`/`clang-15`、
   `ld.lld`/`lld`、`libLLVM.so`/`libLLVM-15.so` 等都是两份真实文件）；
   旧 daily-38 版才有（llvm 内 36 个符号链接）——这是 SDK 打包差异，
   不是解压问题。
8. **批量签名**：用仓库内 `ohos-sign-elf.py`（多线程，见文件表）签名整棵树。
   跳过符号链接与 `.o` 目标文件（`.o` 若带签名，lld 链接时会产出多块签名，
   设备内核校验失败报 `Operation not permitted`）；x86-64 / 已签名等失败项
   只记录、不中止。
9. **建议把 output 链接到 f2fs**：见上文"建议"一节——HMDFS 大小写不敏感，
   工具树里仅大小写不同的文件（8 对内核头）会被合并，放回大小写敏感文件
   系统会找不到特定大小写的文件。
10. **llvm 重复文件符号链接化**：master 官方包把符号链接实体化成了文件副本
    （`clang`/`clang-15` 等各 109MB），参照 harmonybrew-core `ohos-sdk.rb`
    的 `ln_map` 做法，用固定映射表把**内容相同**（md5 校验通过）的重复文件
    换回符号链接：bin 11 个（clang 家族→clang-15、lld 家族→lld、
    llvm-lib/ranlib→llvm-ar、llvm-strip→llvm-objcopy、llvm-addr2line→
    llvm-symbolizer、llvm-readelf→llvm-readobj），lib 9 个（libLLVM→
    libLLVM-15、libclang.so.15→libclang.so.15.0.4、liblldb.so.15→
    liblldb.so.15.0.4、liblldbIntelFeatures→.15、libgomp/libiomp5→libomp、
    libxml2→libxml2.so.2.14.0）。md5 不同的对跳过（如 libLTO.so 与
    libLTO.so.15 内容不同、OpenMP `.bc` 位码同大小不同内容，均不处理）。
    `ld.lld` 不在此表，由第 8 步包装脚本处理。llvm 体积从约 3.5G 降至 2.5G。
11. **扫描 x86-64 ELF 可执行文件并取消执行权限**：基底残留的 x64 主机工具
    （glslang_validator/idl/hnpcli/ccmake/Previewer/cppaudit 等）在设备上
    无法运行，取消执行权限避免被误调用。由仓库内 `ohos-chmod-x64-elf.py`
    执行（见文件表），对每个命中文件 `chmod -x`，aarch64 工具不受影响。

## 日志

全程日志在 `./output/build.log`（`LOG` 环境变量可覆盖）。最后一步会校验：
- 所有 aarch64 可执行/动态库（ET_EXEC/ET_DYN）必须带 `.codesign` 段（预期约
  300 个，整树约 1000 个 ELF）；
- 所有 ELF 的 PT_LOAD 段不得越出文件末尾（防截断，参照 libffi 事故）。

任一失败脚本即退出非 0。

## 预期结果

- 大小约 6.6 GB；`tool/node/bin/node --version` → `v24.14.1`；
- openharmony 组件 `oh-uni-package.json` 版本均为 `26.0.0.18`（Master 20260330）；
- hvigor 版本 6.26.2，ohpm 26.0.0.410，codelinter 6.0.240（来自 linux 基底）；
- BiSheng/bin 中 40 个工具（master 版）为指向 openharmony llvm 的相对符号链接；
- hms/toolchains/lib 下 6 个 stub 为 aarch64 musl、带 SONAME、已签名。
