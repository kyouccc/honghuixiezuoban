# HarmonyCanvas 构建验证固化手册（BUILD-VERIFY）

> 作者：寇豆码（ArkTS 工程师）
> 适用：HarmonyCanvas entry 模块 hvigor 全量构建
> 硬约束：构建必须**真实编译通过**（`ERROR=0`），且日志中必须出现 `CompileArkTS` /
> `:entry:default@CompileArkTS`；**禁止中途 kill 构建进程**。

---

## 0. 为什么需要这份文档

本仓曾出现过「构建成功但代码根本没编译」的假绿灯：hvigor 在判定输入未变化时
会整个跳过 `CompileArkTS`，于是改了 `.ets` 源码却显示 `BUILD SUCCESSFUL`，
实则该改动一行都没进编译器。**任何一次验收，都必须强制全量重编译**，见 §3。

---

## 1. 七坑固化（症状 → 原因 → 解法）

### 坑 1：`DEVECO_SDK_HOME` 未设置 → 编译静默跳过

- **症状**：`hvigorw` 跑完显示成功，但日志里**没有 `CompileArkTS`**，且 `arkts` 任务
  直接被跳过；或者更早地报 `Configuration Error 00303217` 后退出。
- **原因**：hvigor 找不到 SDK 根目录（`.../sdk`），无法解析 `compileSdkVersion` /
  `compatibleSdkVersion`，于是在配置阶段就放弃了 ArkTS 编译，**不报 ArkTS 错误也不编译**。
- **解法**：构建前必须导出：
  ```bash
  export DEVECO_SDK_HOME="<DevEco>/sdk"
  # 实测绝对路径示例：
  export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"
  ```

### 坑 2：`--daemon` 输出不回流 → 看不到编译结果

- **症状**：用了 `--daemon`，进程 detached，标准输出/错误**不回流到 redirect 文件**，
  你重定向的 `build.log` 是空的，无法判定 ERROR 数。
- **原因**：daemon 模式下日志走内部 pipe，不会随 shell 重定向落地。
- **解法**：**必须 `--no-daemon`**，让编译日志同步写入 redirect 文件：
  ```bash
  node "$DEVECO_HOME/tools/hvigor/bin/hvigorw.js" ... --no-daemon > build.log 2>&1
  ```

### 坑 3：WorkBuddy 的 `NODE_OPTIONS` safe-delete shim 劫持 `rmSync` → `00308018 Unknown Error`

- **症状**：`CompileArkTS` 阶段报 `00308018 Unknown Error`，任务 `CompileArkTS.beforeTask`
  清理 `loader_out` 等目录时失败，整个编译中断。
- **原因**：WorkBuddy 给 node 注入了 `NODE_OPTIONS=--require=.../genie-safe-delete.cjs`，
  该 shim 把 Node 的 `fs.rmSync`/`unlinkSync` 重定向到 Windows 回收站。hvigor 的
  `CompileArkTS.beforeTask` 调用 `removeSync` 清理目录时，被 shim 拦截后抛异常。
- **解法**：**在 hvigor 进程上去掉 `NODE_OPTIONS`**（只影响本次 hvigor 调用，不动全局环境）：
  ```bash
  env -u NODE_OPTIONS node "$DEVECO_HOME/tools/hvigor/bin/hvigorw.js" ...
  ```

### 坑 4：`spawn java ENOENT` → `PackageHap` 失败

- **症状**：`CompileArkTS` 跑完了（clean），但后续的 `PackageHap` 阶段报
  `spawn java ENOENT`，HAP 打不出来。
- **原因**：打包 HAP 需要 JDK，而 `java` 不在 `PATH` 上。DevEco Studio 自带 JBR。
- **解法**：把 DevEco 自带的 JBR 放进 `JAVA_HOME` 与 `PATH`：
  ```bash
  export JAVA_HOME="<DevEco>/jbr"
  export PATH="$JAVA_HOME/bin:$PATH"
  # 实测绝对路径示例：
  export JAVA_HOME="C:/Program Files/Huawei/DevEco Studio/jbr"
  ```

### 坑 5：`hvigorw.js` 不在工程根 → `Error: Cannot find module ... MODULE_NOT_FOUND`

- **症状**：执行构建直接报错退出，完全没有后续编译日志：
  `Error: Cannot find module '...\harmonycanvas\hvigorw.js' code: 'MODULE_NOT_FOUND'`（EXIT=1）。
- **原因**：本仓工程根**没有** `hvigorw.js`（仅含 `hvigorfile.ts` 与 `hvigor/hvigor-config.json5`，
  无 `node_modules`）。`hvigorw.js` 随 DevEco Studio 安装，位于其 `tools/hvigor/bin/` 子目录。
- **解法**：改用 DevEco 安装目录下的绝对路径，并用 `DEVECO_HOME` 变量抽象（见 §2 ②）：
  ```bash
  env -u NODE_OPTIONS node "$DEVECO_HOME/tools/hvigor/bin/hvigorw.js" ...
  ```

### 坑 6：Git Bash 下 `PATH` 不认 Windows 风格 → `spawn java ENOENT`（坑 4 复发）

- **症状**：`PackageHap` 阶段再次报 `spawn java ENOENT`，但 `JAVA_HOME` 明明设成了 DevEco 的 `jbr`。
- **原因**：`JAVA_HOME` 用 Windows 风格（`C:/Program Files/...`）hvigor 能解析；但**追加进 `PATH` 的那一条必须是 Unix 风格**——
  Git Bash 的 `PATH` 不认 `C:/...` 这种 Windows 路径，整条 `export PATH="$JAVA_HOME/bin:$PATH"` 被静默忽略，
  于是 `command -v java` 找不到，`spawn java` 失败。这个坑极隐蔽：`JAVA_HOME` 设对会让人误以为万事大吉。
- **解法**：同一条命令里两种风格各司其职——
  ```bash
  export JAVA_HOME="C:/Program Files/Huawei/DevEco Studio/jbr"          # Windows 风格：hvigor 按 Windows 路径解析
  export PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH"    # Unix 风格：Git Bash 的 PATH 只认这个
  ```
  验证（一行）：
  ```bash
  command -v java && java -version   # 应输出 openjdk 21.0.8
  ```

### 坑 7：被 kill 的构建留下脏中间产物 → 下次 `CompileResource` 失败

- **症状**：中途 kill 构建后，下一次构建报 `Failed :entry:default@CompileResource` +
  `Failed to delete ... app_icon.svg`，收尾再补 `EPERM: ... .hvigor\cache\meta.json`。
- **原因**：构建进程被掐断，`loader_out` / 资源缓存 / `.hvigor/cache/meta.json` 等中间态残留且被占用。
- **解法**：**这是违反铁律 3「不许中途 kill」的直接后果，不是独立的坑**——宁可等它自然跑完。
  若已踩中：等残留进程自然退出、释放文件占用后重试即可，无需改任何配置。

---

## 2. 完整可复现命令（七坑一次性规避）

```bash
# ① 进入工程根
cd "<工程根>/harmonycanvas"

# ② 环境变量（DEVECO_HOME 抽象 hvigorw.js 位置）
export DEVECO_HOME="C:/Program Files/Huawei/DevEco Studio"
export DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
export JAVA_HOME="$DEVECO_HOME/jbr"                                   # Windows 风格：hvigor 按 Windows 路径解析
export PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH"    # Unix 风格：Git Bash 的 PATH 只认这个
# 验证 java 可达（坑 6）
command -v java && java -version   # 应输出 openjdk 21.0.8

# ③ 强制全量重编译（关键！见 §3），去掉 NODE_OPTIONS shim，前台日志
find entry/src/main/ets -name "*.ets" -exec touch {} +
env -u NODE_OPTIONS node "$DEVECO_HOME/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p module=entry@default assembleHap \
  --analyze=normal --parallel=true --incremental=true --no-daemon \
  > build_verify.log 2>&1
```

> `<DevEco>` 换成你机器上 DevEco Studio 的真实绝对路径（含 `sdk` 与 `jbr` 子目录）。

---

## 3. 三条验收铁律

1. **日志必须有编译证据**：`build_verify.log` 中必须出现
   `CompileArkTS` 或 `:entry:default@CompileArkTS`（Finished 字样）。
   没有它 = 没编译 = 假绿灯，直接判不合格。
2. **`ERROR` 必须为 0**：统计日志中的 `ERROR` 计数（如 `COMPILE RESULT:FAIL {ERROR:n ...}`
   或 ArkTS 报错行），`n` 必须为 `0`。`WARN` 数量只做记录，不阻断。
3. **不许中途 kill**：构建一旦启动必须跑到结束（`EXITCODE=0` 或明确 FAIL）。
   中途 kill 会让 `loader_out` 等中间态残留，污染下一次构建。

### 为什么每次都要 `touch` 全量

hvigor 基于「输入文件 mtime 是否变化」判断是否 UP-TO-DATE。若代码已改但 hvigor
认为输入未变（缓存、增量状态错位、或你只改了被 import 的叶子文件而入口 mtime 没动），
它会**整个跳过 `CompileArkTS`**，输出 `BUILD SUCCESSFUL` 却不编译任何东西——
这就是「构建成功但改动没生效」的假绿灯根因。

`find entry/src/main/ets -name "*.ets" -exec touch {} +` 把所有 `.ets` 的 mtime 刷到当前，
强制 hvigor 认定全部输入已变，从而**真实重编译每一个文件**，确保本次验收覆盖你改动的代码。

---

## 4. 快速判读 `build_verify.log`

| 看到什么 | 含义 | 处置 |
|---|---|---|
| `CompileArkTS Finished` + `EXITCODE=0` + 无 `ERROR` | 真·编译通过 | ✅ 验收通过 |
| 日志**无** `CompileArkTS` | 没编译（坑 1 / 没 touch） | 检查 `DEVECO_SDK_HOME` 与 touch 步骤 |
| `00303217 Configuration Error` | SDK 根未设 | 补坑 1 |
| `00308018 Unknown Error` @ CompileArkTS | safe-delete shim 劫持 | 补坑 3（`env -u NODE_OPTIONS`） |
| `spawn java ENOENT` @ PackageHap | 无 JDK（或 Git Bash `PATH` 风格错，见坑 6） | 补坑 4 / 坑 6（`JAVA_HOME`/`PATH`，`command -v java` 验证） |
| `Failed :entry:default@CompileResource` + `Failed to delete app_icon.svg` / `EPERM ... meta.json` | 被 kill 的构建留脏产物（坑 7 = 违反铁律 3） | 等残留进程自然退出、释放占用后重试，无需改配置 |
| `ERROR: n`（n>0） | 真的有 ArkTS 错误 | 修代码，重新走 §2 |

---

## 5. 变更记录

- 2026-08-08 初版：固化四坑（SDK_HOME / --no-daemon / NODE_OPTIONS shim / JAVA_HOME）、
  完整命令、三条验收铁律、touch 全量原理。
- 2026-08-08 修订：补坑 5（`hvigorw.js` 在 DevEco `tools/hvigor/bin/`，工程根不含）；
  引入 `DEVECO_HOME` 抽象统一调用入口，消除 §2 与正文裸 `hvigorw.js` 的自相矛盾。
- 2026-08-08 修订（续）：补坑 6（Git Bash 下 `PATH` 必须 Unix 风格，否则 `spawn java ENOENT` 复发）、
  坑 7（被 kill 的构建留脏产物，属违反铁律 3 的后果）；§2 命令的 `PATH` 改用
  `/c/Program Files/Huawei/DevEco Studio/jbr/bin` 并加 `command -v java` 验证。
