# 开源发布指南 · GitHub（honghuixiezuoban）

> **当前状态**：`D:\鸿绘协作板` 已是一个完整的 Git 仓库，**万事俱备，只差推送**。
>
> ```
> 仓库位置 : D:\鸿绘协作板
> 远程     : https://github.com/qywccc/honghuixiezuoban.git
> 提交     : 6 个，作者均为 qywccc <2796824564@qq.com>
> 标签     : v2.7.8-appstore（已上架版本）
> 分支     : main
> 跟踪文件 : 261 个 / 仓库体积 2.3 MB
> 许可证   : Apache-2.0
> 安全检查 : ✅ 密码未入库、✅ 证书未入库、✅ 历史中无真实密码
> ```

---

# ★ 最快路径：双击一个脚本

推送涉及认证与网络，**必须在你自己的终端执行**（我的运行环境被限制访问 GitHub）。
直接在文件管理器里双击：

```
D:\鸿绘协作板\推送到GitHub.bat
```

脚本会自动完成：清除代理 → 安全检查 → 推送 main → 推送标签。
若提示输入凭据：**用户名填 `qywccc`，密码填 Personal Access Token**（见第三节）。

> ⚠️ **为什么不能用我的环境推送**：实测发现，我的运行环境走一个内部代理
> （`http://127.0.0.1:64918`），该代理**不允许访问 github.com**，报
> `CONNECT tunnel failed, response 502`；而绕过代理直连又被禁止
> （`Could not connect to server`）。这是环境限制，与仓库配置无关。

---

# 一、推送前最后确认（30 秒，可选）

在 `D:\鸿绘协作板` 打开 Git Bash：

```bash
git status                       # 应显示 working tree clean
git log --oneline --decorate     # 应看到 6 个提交 + v2.7.8-appstore 标签
git remote -v                    # 应指向 github.com/qywccc/honghuixiezuoban.git
```

安全三项（脚本也会自动跑）：

```bash
git ls-files | grep -x build-profile.json5     # 期望：无输出
git ls-files | grep -iE '\.(p12|p7b|cer)$'     # 期望：无输出
git log -p --all | grep -oE 'storePassword=[0-9A-F]{40,}'   # 期望：无输出
```

---

# 二、GitHub 仓库已创建（你已完成 ✅）

| 项 | 值 |
|---|---|
| 仓库地址 | https://github.com/qywccc/honghuixiezuoban |
| 可见性 | Public |
| 初始内容 | 空（已确认"三个不要勾选"都没勾，本地推送无需合并） |

---

# 三、认证方式（首次推送会要求）

GitHub **不接受登录密码**，二选一：

## 方式 A：Personal Access Token（HTTPS，最省事）

1. GitHub → 头像 → **Settings** → 左侧最下 **Developer settings**
2. **Personal access tokens** → **Tokens (classic)** → **Generate new token (classic)**
3. Note 填 `push-honghui`，Expiration 选 90 天，**勾选 `repo` 权限** → Generate
4. **立刻复制**（只显示一次）
5. 推送时：
   - Username：`qywccc`
   - Password：**粘贴刚才的 token**（不是你的 QQ 邮箱密码，也不是 GitHub 登录密码）

让 Git 记住凭据（避免每次输入）：

```bash
git config --global credential.helper manager
```

## 方式 B：SSH 密钥（一劳永逸）

```bash
ssh-keygen -t ed25519 -C "2796824564@qq.com"    # 一路回车
cat ~/.ssh/id_ed25519.pub                       # 复制输出
```

把公钥粘贴到 GitHub → Settings → **SSH and GPG keys** → New SSH key，
然后切换远程地址：

```bash
git remote set-url origin git@github.com:qywccc/honghuixiezuoban.git
```

---

# 四、手动推送命令（不用脚本时）

```bash
cd /d/鸿绘协作板
git push -u origin main
git push origin --tags          # 把 v2.7.8-appstore 标签也推上去
```

> **若报 `CONNECT tunnel failed` / `502` / `Could not connect`**：
> 你本机存在代理。先清除再推：
> ```bash
> unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
> git push -u origin main
> ```
> 若清除后连不上，说明你的网络需要代理才能访问 GitHub → **开启代理软件（VPN）后重试**。

> **若报 `CRYPT_E_REVOCATION_OFFLINE`**：
> ```bash
> git config --global http.schannelCheckRevoke false
> # 仍不行则换 SSL 后端：
> git config --global http.sslBackend openssl
> ```
> （已为你设置好这两项，正常不会再遇到）

---

# 五、推送成功后建议做的三件事

## 5.1 完善 README（开源项目的第一印象）

| 建议补充 | 说明 |
|---|---|
| **效果截图 / GIF** | 最有效的加分项。截图放 `docs/images/` 后引用 |
| **功能特性列表** | 无限画布、压感手写、双链笔记、思维导图、闪卡复习 |
| **技术栈徽章** | HarmonyOS / ArkTS / Go 的 shield 徽章 |
| **快速开始** | 明确写：DevEco Studio 打开 → **等待 Sync 完成**（自动装依赖）→ 运行 |
| **⚠️ 换机后配签名** | 指向 `build-profile.json5.template`，否则别人克隆后无法打包 |

## 5.2 添加协作文件

`CONTRIBUTING.md`（贡献指南）、`.github/ISSUE_TEMPLATE/`（Issue 模板）、`CHANGELOG.md`

## 5.3 打第一个 Release

GitHub → Releases → **Draft a new release**：
- Tag 选 `v2.7.8-appstore`
- 标题：`v2.7.8 —— 首个通过华为应用市场审核的版本`
- 说明写清功能与已知限制（协作与设备管理已关闭入口，代码保留待下版本开启）

---

# 六、⚠️ 万一推送后才发现问题

| 情况 | 处理 |
|---|---|
| **发现密码/密钥被推上去了** | **立刻作废该凭据**（改密码、重新申请证书）—— 只删文件是**没用的**，git 历史里还在。然后重写历史 + 强推，或**直接删库重建**（最省事） |
| 只是想改提交信息 | 未推送：`git commit --amend`；已推送：`git rebase -i` 后强推 |
| 推错了仓库 | 删掉远程仓库，重新建 |

> **本项目当前状态**：密码与证书均未入库，历史中已确认无真实密码。
> 以后每次提交前都别把 `build-profile.json5` 加进去（`.gitignore` 已挡住）。

---

# 七、日常开发（以后都在 D 盘）

```bash
cd /d/鸿绘协作板

git status
git add -A
git commit -m "feat: 恢复设备管理功能"
git push

# 发新版本
# ① 改版本号（AppScope/app.json5 的 versionName/versionCode + Index.ets 的 APP_VERSION）
# ② DevEco 里 Clean → Rebuild，确认 0 错误
git add -A && git commit -m "release: v2.8.0"
git tag -a v2.8.0 -m "v2.8.0 提审版本"
git push && git push --tags
```

> **首次在 DevEco 打开 D 盘工程**：需等待 **Sync** 完成（自动下载 `node_modules`，约 220 MB），
> 同步完成后即可正常编译。

---

# 八、知识产权提醒（你已选择的路径）

你的决定：**不申请专利 → 可直接开源**；**维持 Apache-2.0**。

| 事项 | 说明 |
|---|---|
| **软著** | 开源**不影响**软著申请（登记制，不审查新颖性）。建议尽早办 —— 保研、竞赛、求职的硬材料。材料：源代码前后各连续 30 页（每页 ≥50 行）+ 软件说明书 |
| **Apache-2.0 的含义** | 允许别人**商用并闭源分发**。若将来不想让别人拿去做闭源竞品，需改许可证（但已发布版本无法追回） |
| **品牌保护** | 代码开源 ≠ 商标开放。建议在 README 末尾声明「鸿绘」名称与图标的使用权保留 |
| **商号风险** | 本项目已清除全部华为商号（`HarmonyCanvas` → `Honghui`）。**两处刻意保留的数据兼容键**（`harmonycanvas_favorites` / `HC_APP_ID`）不影响对外呈现，源码中已有注释说明 |
| **QQ 邮箱会公开** | 提交记录里 `2796824564@qq.com` 会被所有人看到（可能收到垃圾邮件）。若在意，可在 GitHub → Settings → Emails 开启「Keep my email address private」，获取 `数字+qywccc@users.noreply.github.com` 后替换 |

---

# 九、当前仓库快照

```
位置     : D:\鸿绘协作板
分支     : main
远程     : https://github.com/qywccc/honghuixiezuoban.git
提交     : 942f4dc  chore: 推送脚本安全检查改为真实判定
          e87fa02  docs: 添加 GitHub 开源发布指南
          ed7dfd1  chore: 开源准备 —— 清除华为商号、移除排查残留、修正历史遗留配置
          0a9ce68  docs: 添加 Git 使用指南
          b53ac4f  release: v2.7.8 —— 首个通过 AppGallery 审核的版本  ← v2.7.8-appstore
作者     : 全部为 qywccc <2796824564@qq.com>
跟踪文件 : 261 个
体积     : 2.3 MB
许可证   : Apache-2.0
构建验证 : Go go build ✅ / ArkTS BUILD SUCCESSFUL ✅
```


---
