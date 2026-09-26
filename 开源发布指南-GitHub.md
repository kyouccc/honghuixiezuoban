# 开源发布指南 · GitHub（honghuixiezuoban）

> **当前状态**：`D:\鸿绘协作板` 已是一个完整的 Git 仓库，可以直接推送。
>
> ```
> 仓库位置 : D:\鸿绘协作板
> 历史     : 3 个提交，含标签 v2.7.8-appstore（已上架版本）
> 跟踪文件 : 260 个 / 仓库体积 2.3 MB
> 许可证   : Apache-2.0
> 安全检查 : ✅ 密码未入库、✅ 证书未入库、✅ 无硬编码密钥
> ```

---

# 一、推送前最后确认（30 秒）

在 `D:\鸿绘协作板` 打开 Git Bash，执行：

```bash
# ① 确认工作区干净
git status

# ② 🔴 最重要：确认历史中没有任何密码
git grep -n "storePassword\|keyPassword" $(git rev-list --all) | grep -v template | grep -v your_password
# 期望：没有任何输出

# ③ 确认含密码的文件没被跟踪
git ls-files | grep build-profile
# 期望：没有任何输出（只有 .template 才可能出现在这里，那是安全的）
```

三项都通过再继续。

---

# 二、在 GitHub 创建仓库

1. 打开 https://github.com/new
2. 填写：

| 字段 | 填什么 |
|---|---|
| **Repository name** | `honghuixiezuoban` |
| Description | `鸿绘协作板 —— 鸿蒙原生分布式手写白板与空间化双链笔记（ArkTS / HarmonyOS NEXT）` |
| **Public / Private** | 选 **Public**（要开源） |
| ⚠️ Add a README file | **不要勾选**（本地已有） |
| ⚠️ Add .gitignore | **不要选**（本地已有） |
| ⚠️ Choose a license | **不要选**（本地已有 Apache-2.0） |

> 三个"不要勾选"很关键：勾了会让远程仓库先有内容，推送时需要额外合并步骤。

3. 点 **Create repository**
4. 创建后页面会显示仓库地址，形如：
   `https://github.com/你的用户名/honghuixiezuoban.git`

---

# 三、配置身份并推送

## 3.1 先设置你的 Git 身份（重要，会显示在提交记录里）

```bash
git config --global user.name "你的名字或昵称"
git config --global user.email "你的GitHub注册邮箱"
```

> 邮箱建议用 GitHub 提供的隐私邮箱（形如 `12345678+用户名@users.noreply.github.com`），
> 避免真实邮箱被爬虫抓取。可在 GitHub → Settings → Emails 里找到。

## 3.2 关联远程仓库并推送

```bash
cd /d/鸿绘协作板

git remote add origin https://github.com/你的用户名/honghuixiezuoban.git
git branch -M main
git push -u origin main
git push origin --tags          # 把 v2.7.8-appstore 标签一起推上去
```

## 3.3 认证方式（首次会要求）

GitHub 从 2021 年起**不再支持密码推送**，二选一：

### 方式 A：Personal Access Token（HTTPS，最简单）

1. GitHub → 头像 → **Settings** → 左侧最下 **Developer settings**
2. **Personal access tokens** → **Tokens (classic)** → **Generate new token (classic)**
3. Note 随意填，Expiration 选 90 天，勾选 **`repo`** 权限
4. 生成后**立刻复制**（只显示一次）
5. 推送时：
   - Username：你的 GitHub 用户名
   - Password：**粘贴刚才的 token**（不是你的登录密码）

> 为了避免每次都输，可让 Git 记住：
> ```bash
> git config --global credential.helper manager
> ```

### 方式 B：SSH 密钥（一劳永逸）

```bash
ssh-keygen -t ed25519 -C "你的邮箱"     # 一路回车
cat ~/.ssh/id_ed25519.pub               # 复制输出的公钥
```
把公钥粘贴到 GitHub → Settings → **SSH and GPG keys** → New SSH key，
然后把远程地址改成 SSH 形式：
```bash
git remote set-url origin git@github.com:你的用户名/honghuixiezuoban.git
```

---

# 四、推送后建议做的三件事

## 4.1 完善 README（开源项目的第一印象）

当前 README 偏内部文档风格，建议补充：

| 建议补充 | 说明 |
|---|---|
| **效果截图 / GIF** | 最有效的加分项。把 `resource/` 或真机截图放 `docs/images/` 后引用 |
| **功能特性列表** | 用 emoji + 短句列出：无限画布、压感手写、双链笔记、思维导图、闪卡复习 |
| **技术栈徽章** | HarmonyOS / ArkTS / Go 的 shield 徽章 |
| **快速开始** | 明确写：用 DevEco Studio 打开 → 等待 Sync 完成（会自动装依赖）→ 运行 |
| **⚠️ 换机后如何配签名** | 指向 `build-profile.json5.template`，否则别人克隆后无法打包 |

## 4.2 添加协作文件

| 文件 | 用途 |
|---|---|
| `CONTRIBUTING.md` | 贡献指南（如何提 PR、代码规范） |
| `CODE_OF_CONDUCT.md` | 行为准则 |
| `.github/ISSUE_TEMPLATE/` | Issue 模板（bug / feature） |
| `CHANGELOG.md` | 版本变更记录 |

## 4.3 打第一个 Release

GitHub → Releases → **Draft a new release**：
- Tag 选 `v2.7.8-appstore`
- 标题：`v2.7.8 —— 首个通过华为应用市场审核的版本`
- 说明里写清功能与已知限制（协作与设备管理功能已在 v2.7.8 中关闭入口，代码保留待下版本开启）

---

# 五、⚠️ 万一推送后才发现问题

| 情况 | 处理 |
|---|---|
| **发现密码/密钥被推上去了** | **立刻作废该凭据**（改密码、重新生成证书）—— 只删文件是**没用的**，git 历史里还在。然后 `git filter-repo` 重写历史 + 强推。**最省事的办法是删库重建** |
| 只是想改提交信息 | `git commit --amend`（未推送时）或 `git rebase -i`（已推送需强推） |
| 推错了仓库 | 直接删远程仓库，重新建 |

> **本项目当前状态**：密码与证书均未入库，历史中已确认无明文密码。
> **但请记住**：以后每次提交前，都别把 `build-profile.json5` 加进去（`.gitignore` 已挡住）。

---

# 六、日常开发（仓库已在 D 盘）

以后都在 `D:\鸿绘协作板` 工作：

```bash
cd /d/鸿绘协作板

# 开发 → 提交 → 推送
git status
git add -A
git commit -m "feat: 恢复设备管理功能"
git push

# 发新版本
# ① 改版本号（AppScope/app.json5 + Index.ets 的 APP_VERSION）
# ② DevEco 里 Clean → Rebuild 验证 0 错误
git add -A && git commit -m "release: v2.8.0"
git tag -a v2.8.0 -m "v2.8.0 提审版本"
git push && git push --tags
```

> **首次在 DevEco 打开 D 盘工程时**：需要等待 **Sync** 完成（会自动下载 `node_modules`，
> 约 220 MB）。同步完成后即可正常编译。

---

# 七、知识产权提醒（你已选择的路径）

你的决定：**不申请专利 → 可直接开源**；**维持 Apache-2.0**。

| 事项 | 说明 |
|---|---|
| **软著** | 开源**不影响**软著申请（登记制，不审查新颖性）。建议尽早办 —— 是保研、竞赛、求职的硬材料。材料：源代码前后各连续 30 页（每页 ≥50 行）+ 软件说明书 |
| **Apache-2.0 的含义** | 允许别人**商用并闭源分发**。若将来不想让别人拿去做闭源竞品，需要改许可证（但已发布的版本无法追回） |
| **品牌保护** | 代码开源 ≠ 商标开放。建议保留「鸿绘」名称与图标的使用权声明（可加到 README 末尾） |
| **⚠️ 已发现的商号风险** | 本项目已清除全部华为商号（`HarmonyCanvas` → `Honghui`）。**两处刻意保留的数据兼容键**（`harmonycanvas_favorites` / `HC_APP_ID`）不影响对外呈现，源码中已有注释说明 |

---

# 八、当前仓库快照

```
位置     : D:\鸿绘协作板
分支     : main
提交     : f07c47c  chore: 开源准备 —— 清除华为商号、移除排查残留、修正历史遗留配置
          7c8f404  docs: 添加 Git 使用指南
          5358f62  release: v2.7.8 —— 首个通过 AppGallery 审核的版本  ← 标签 v2.7.8-appstore
跟踪文件 : 260 个
体积     : 2.3 MB
许可证   : Apache-2.0
构建验证 : Go go build ✅ / ArkTS BUILD SUCCESSFUL ✅
```
