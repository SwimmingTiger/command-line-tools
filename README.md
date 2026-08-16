# 合成 HarmonyOS aarch64 可用的 command-line-tools

本目录包含用 SDK 压缩包合成"可在 HarmonyOS aarch64 设备上运行"的
command-line-tools 的全部材料：主脚本、stub 源文件、stub 构建脚本。

## 文件

| 文件 | 说明 |
|---|---|
| `create-ohos-command-line-tools.sh` | 一键合成脚本（9 步，见下） |
| `stubs/hms_stub.c` | hms 图像库 stub 源码（导出与真实库同名符号） |
| `stubs/build-stubs.sh` | stub 编译脚本（被主脚本第 8 步调用） |

## 输入（放在 `./Downloads/`）

| 文件 | 作用 | 下载地址 |
|---|---|---|
| `commandline-tools-linux-x64-26.0.0.621.zip` | 基础（完整版，含 hvigor/ohpm/hstack/codelinter/sdk） | https://developer.huawei.com/consumer/cn/download/command-line-tools-for-hmos |
| `version-Daily_Version-OpenHarmony_7.0.0.38-20260816_000626-ohos-sdk-public.tar.gz` | 5 个 **ohos 平台**组件：ets/js/native/previewer/toolchains（26.0.0.38） | https://dcp.openharmony.cn/workbench/cicd/dailybuild/dailylist |
| `node-v24.14.1-openharmony-arm64.tar.xz` | openharmony arm64 node，替换自带的 x86-64 node | https://github.com/hqzing/ohos-node/releases/tag/v24.14.1 |

## 为什么这样做

1. **Linux 版本来就是完整的**：以 linux zip 为基底，不需要 Windows 版补充。
2. **合并 openharmony 26.0.0.38 组件**：linux 自带 openharmony 是 26.0.0.32
   （Beta2），用更新的 public SDK 组件整体替换 `sdk/default/openharmony/`
   下的 ets/js/native/previewer/toolchains；`hms` 保持 26.0.0.32 不动。
   ⚠️ **必须使用 `ohos-sdk/ohos/` 下的 `*-ohos-x64-*` 变体**（二进制为
   aarch64 musl，能在设备上运行）。`ohos-sdk/linux/` 的 `*-linux-x64-*`
   变体是 x86-64 主机工具（clang-15/restool/hdc 等均为 x86-64 glibc），
   设备上无法执行，stub 编译会报 "cannot execute binary file: Exec format
   error"，BiSheng 替换数也会从 35 变成 47（llvm bin 工具集不同）。
3. **替换 tool/node**：自带 node 是 x86-64 ELF（动态链接 glibc），在设备上
   无法运行；换成 openharmony 官方 arm64 musl node v24.14.1 后，
   `bin/hvigorw`（原版，自动设置 `DEVECO_NODE_HOME=$all_tool_dir/tool/node`）
   即可直接工作。
4. **hvigor 3 处设备 bug 补丁**（仅改源文件，node_modules 副本不动）：
   - `hvigor/hvigor/src/common/util/path-util.js` 的 `areIdentical`：
     设备 f2fs 的 stat 返回 `dev=0`，原判断 `e.ino&&e.dev&&e.ino===t.ino&&e.dev===t.dev`
     在 ino 为 0 时仍可能误判"同一文件"而跳过复制 → 改为
     `!!e.ino&&e.ino===t.ino&&e.dev===t.dev`（ino/dev 均非 0 才判同）。
   - `hvigor/hvigor-ohos-plugin/src/sdk/impl/ets-ark-component.js` 的
     `getArkVersion`：hvigor 会 spawn ts2abc 探测 ark 版本，设备上不稳定 →
     直接 `return"13.0.1.0"`。
   - `hvigor/hvigor-ohos-plugin/src/tasks/abstract-build-native.js` 的
     worker 分支：设备上 worker 线程池执行 native 命令时 libentry.so 会消失 →
     `if(this.getWorkerPool().submit(...)...REJECT){` 改为 `if(true/*worker-bypass*/){`
     绕过 worker 直接执行。
5. **BiSheng（hms）x86-64 bin 工具 → openharmony 符号链接**：hms 的 BiSheng
   clang/llvm 工具是 x86-64 glibc ELF，设备上无法运行也无法签名；对每个在
   `openharmony/native/llvm/bin` 有同名 aarch64 工具者（35 个）替换为相对
   符号链接（两套都是 LLVM 15 工具链，接口一致）。zip 自带的 BiSheng 内部
   别名符号链接（`clang -> bisheng-clang -> clang-15` 链）保留。
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
7. **批量签名**：用 `ohos-sign-elf`（`~/.local/bin/ohos-sign-elf`，内部调用
   `binary-sign-tool sign -selfSign 1`，8 线程）签名整棵树。跳过符号链接；
   x86-64（如 BiSheng lib 大 .so、llvm-bolt 等无 openharmony 对应者）与
   已签名文件（如 ets es2abc）的失败项只记录、不中止。
8. **产物放 f2fs**：`/data/storage/el2/base/files/command-line-tools`
   （f2fs），而非 HMDFS `/storage/Users/currentUser`：HMDFS 对未签名 ELF
   的执行有限制，且 GNU coreutils cp 写 HMDFS 有截断 bug（"error
   deallocating: Permission denied" 却退出码 0）。构建系统通过符号链接
   `/storage/Users/currentUser/work/wine/command-line-tools` 引用它。

## 用法

```bash
# 默认输出到 /data/storage/el2/base/files/command-line-tools (已存在则需 FORCE=1)
bash /storage/Users/currentUser/work/hmos/command-line-tools/create-ohos-command-line-tools.sh

# 覆盖现有工具树 + 更新 wine 符号链接
FORCE=1 LINK_WINE=1 bash .../create-ohos-command-line-tools.sh

# 自定义输入/输出
LINUX_ZIP=... OHOS_SDK_TAR=... NODE_TAR_XZ=... \
DEST=/data/storage/el2/base/files/command-line-tools-v2 \
bash .../create-ohos-command-line-tools.sh
```

耗时取决于设备磁盘速度（解压约 10 GB 写入），全程日志在
`synth.log`。最后一步会校验：
- 所有 aarch64 可执行/动态库（ET_EXEC/ET_DYN）必须带 `.codesign` 段（预期约
  300 个，整树约 1150 个 ELF）；
- 所有 ELF 的 PT_LOAD 段不得越出文件末尾（防截断，参照 libffi 事故）。

任一失败脚本即退出非 0。

## 预期结果

- 大小约 6.6 GB；`tool/node/bin/node --version` → `v24.14.1`；
- openharmony 组件 `oh-uni-package.json` 版本均为 `26.0.0.38`；
- hvigor 版本 6.26.2，ohpm 26.0.0.410，codelinter 6.0.240（来自 linux 基底）；
- BiSheng/bin 中 35 个工具为指向 openharmony llvm 的相对符号链接；
- hms/toolchains/lib 下 6 个 stub 为 aarch64 musl、带 SONAME、已签名。
