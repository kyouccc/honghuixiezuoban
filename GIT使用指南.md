# Git 使用指南 · 鸿绘协作板

> 本仓库已建立，当前状态：
> - 提交 `5358f62` —— 已上架版本 v2.7.8 的完整源码
> - 标签 **`v2.7.8-appstore`** —— 锁定提审通过的源码，随时可回滚
> - 跟踪文件 285 个，仓库体积约 2.1 MB

---

## 一、三个最重要的事实

1. **`build-profile.json5` 没有入库**（里面有明文签名密码）。
   它是本地文件，**切换版本时不会被覆盖或删除**，所以回滚完全正常。
   只有「换新电脑重新克隆」时才需按 `build-profile.json5.template` 重新配一次签名。

2. **回滚已上架版本**只要一条命令：
   ```bash
   git checkout v2.7.8-appstore
   ```

3. **桌面已放物理备份**：`鸿绘-源码备份-v2.7.8.zip`（3.37 MB，**含完整 git 历史**）。
   即使本仓库被误删，解压即可完整还原。

---

## 二、日常开发流程（每改一小步就提交一次）

```bash
cd C:\Users\27968\WorkBuddy\2026-08-03-10-35-19\harmonycanvas

git status                # 看改了哪些文件
git diff                  # 看具体改了什么
git add -A                # 把改动加入暂存区
git commit -m "fix: 修复某某问题"     # 提交
```

**提交信息建议**（一眼看懂改了什么）：
| 前缀 | 用途 | 例子 |
|---|---|---|
| `feat:` | 新功能 | `feat: 恢复设备管理入口与运行时权限申请` |
| `fix:` | 修 bug | `fix: 修复文本编辑后画布不刷新` |
| `refactor:` | 重构 | `refactor: 拆分白板页 Builder` |
| `release:` | 发版本 | `release: v2.8.0` |

---

## 三、发新版本的标准流程

```bash
# ① 改版本号（两处都要改，且必须同时改）
#    AppScope/app.json5          → versionName / versionCode
#    entry/src/main/ets/pages/Index.ets → APP_VERSION（「我的」页显示的版本号）
#    规则：versionName 加 0.0.1，versionCode 加 1

# ② 编译验证（务必 0 错误再提交）
#    在 DevEco Studio 里执行：Sync → Clean Project → Rebuild Project

# ③ 提交并打标签
git add -A
git commit -m "release: v2.8.0 —— 恢复设备管理功能"
git tag -a v2.8.0 -m "v2.8.0 提审版本"

# ④ 出包上传 AGC
#    Build → Build Hap(s)/APP(s) → release 已签名
```

> **重要**：**每次提审前都打一个标签**。这样一旦审核驳回、或新版出问题，
> 你能一条命令回到"上次通过的那个版本"。

---

## 四、常用回滚操作

```bash
# 看所有已标记的版本
git tag -l

# 看某个标签的详情
git tag -n99 v2.7.8-appstore

# 【只想看看】旧版本长什么样（看完要 git switch main 回来）
git checkout v2.7.8-appstore

# 【回到 main 分支】
git switch main

# 【基于已上架版本开一个修复分支】（推荐用于"小修补后重新提审"）
git switch -c hotfix-2.7.9 v2.7.8-appstore

# 【撤销还没提交的改动】（危险，会丢弃你未提交的工作！）
git restore .

# 【查看某次提交改了什么】
git show 5358f62 --stat
```

> ⚠️ `git restore .` 会**永久丢弃未提交的修改**，执行前先 `git stash` 或先 commit。

---

## 五、备份到云端（可选但强烈建议）

本仓库**已排除签名密码**，可以安全推到远程仓库做异地备份。

```bash
# 以 Gitee 为例（先在网页上建一个**私有**仓库）
git remote add origin https://gitee.com/你的用户名/honghui-board.git
git push -u origin main --tags
```

之后每次备份：
```bash
git push
git push --tags
```

> **推送前自查**（确认没有密码混入）：
> ```bash
> git grep -n "storePassword\|keyPassword" $(git rev-list --all) 2>/dev/null | grep -v template
> # 期望：只看到 build-and-sign.bat 里的占位符 your_password
> ```

---

## 六、被 git 忽略的东西（不要手动加回）

| 忽略项 | 原因 |
|---|---|
| `build-profile.json5` | **含明文签名密码** |
| `node_modules/` `oh_modules/` | 依赖，可 `ohpm install` 还原 |
| `entry/build/` `build/` `.hvigor/` | 构建产物 |
| `.idea/` `local.properties` | IDE 与机器专属配置 |
| `*.log` `bl_*.txt` `_*.txt` `probe*` | 历次排查的临时文件 |
| `*.p12` `*.cer` `*.p7b` | 证书材料 |

---

## 七、换电脑怎么恢复

1. 解压 `鸿绘-源码备份-v2.7.8.zip`（或 `git clone` 远程仓库）
2. 用 DevEco Studio 打开 `harmonycanvas`
3. **配置签名**：File → Project Structure → Signing Configs
   - 勾选「Automatically generate signature」（需登录华为账号），或
   - 手动选择 `D:/honghui_board_debug.p12` 等文件并填入密码
   （参考 `build-profile.json5.template` 顶部说明）
4. 等待 Sync 完成 → 即可编译

> 注意：驱动盘 `D:` 上的签名材料（`.p12` / `.p7b` / `.cer`）**也要单独备份**，
> 它们不在本仓库内。丢失后需重新在 AGC 申请证书。

---

## 八、当前仓库快照

```
提交   : 5358f62  release: v2.7.8 —— 首个通过 AppGallery 审核的版本
标签   : v2.7.8-appstore
分支   : main
文件数 : 285
版本   : 2.7.8 / 2007008
权限   : ['ohos.permission.INTERNET']

功能开关（本版本状态）：
  FEATURE_COLLAB_ENABLED           = false   协作（跨设备共享白板）
  FEATURE_DEVICE_DISCOVERY_ENABLED = false   设备管理（附近设备）
  ↑ 两者代码完整保留，下版本置 true + 恢复权限声明即可启用
```
