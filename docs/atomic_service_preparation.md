# 元服务/APP形态确认与素材准备（F-08）

## 一、元服务形态确认

### 1. 元服务特性

**免安装：**
- ✅ 用户无需安装即可使用
- ✅ 通过分享链接、卡片、搜索直达
- ✅ 应用体积需控制在2MB以内

**卡片：**
- ✅ 桌面卡片展示笔记列表
- ✅ 快速创建笔记卡片
- ✅ 协作邀请卡片

**分享：**
- ✅ 笔记分享链接
- ✅ 协作邀请链接
- ✅ 卡片分享

### 2. 元服务配置

**module.json5配置：**
```json5
{
  "module": {
    "name": "entry",
    "type": "entry",
    "deliveryWithInstall": true,
    "installationFree": true,  // 支持免安装
    "atomicService": {
      "support": true  // 声明为元服务
    }
  }
}
```

**app.json5配置：**
```json5
{
  "app": {
    "bundleName": "com.honghui.app",
    "vendor": "Honghui",
    "versionCode": 1000000,
    "versionName": "1.0.0",
    "icon": "$media:app_icon",
    "label": "$string:app_name",
    "description": "$string:app_desc",
    "minAPIVersion": 10,
    "targetAPIVersion": 11,
    "apiReleaseType": "Release",
    "debug": false,
    "authConfig": {
      "clientId": "YOUR_CLIENT_ID"  // 华为账号登录
    }
  }
}
```

## 二、素材准备清单

### 1. 应用图标

**规格要求：**
- 小图标：192x192px（PNG，透明背景）
- 大图标：512x512px（PNG，透明背景）
- 圆形图标：216x216px（PNG，透明背景）

**设计要点：**
- 简洁明了，易于识别
- 体现应用特色（白板/协作）
- 适配不同背景色

**文件路径：**
- `entry/src/main/resources/base/media/app_icon.png` - 应用图标
- `entry/src/main/resources/base/media/app_icon_round.png` - 圆形图标

### 2. 启动页

**规格要求：**
- 手机：1080x1920px
- 平板：1536x2048px
- 横屏：1920x1080px

**设计要点：**
- 品牌Logo居中
- 简洁背景色
- 避免文字（多语言适配）

**文件路径：**
- `entry/src/main/resources/base/media/startIcon.png` - 启动页图标

### 3. 宣传图

**规格要求：**
- 应用商店封面：1024x500px
- 截图：手机1080x1920px，平板1536x2048px
- 宣传视频：16:9，30fps

**设计要点：**
- 展示核心功能（白板协作、跨设备同步）
- 突出差异化特性
- 多语言适配

**文件路径：**
- `docs/assets/cover.png` - 应用商店封面
- `docs/assets/screenshot_phone_1.png` - 手机截图1
- `docs/assets/screenshot_phone_2.png` - 手机截图2
- `docs/assets/screenshot_tablet_1.png` - 平板截图1
- `docs/assets/screenshot_tablet_2.png` - 平板截图2

### 4. 卡片素材

**规格要求：**
- 2x2卡片：108x108px
- 2x4卡片：216x108px
- 4x4卡片：216x216px

**设计要点：**
- 简洁信息展示
- 快速操作入口
- 适配暗色模式

**文件路径：**
- `entry/src/main/resources/base/media/widget_2x2.png` - 2x2卡片背景
- `entry/src/main/resources/base/media/widget_2x4.png` - 2x4卡片背景
- `entry/src/main/resources/base/media/widget_4x4.png` - 4x4卡片背景

## 三、元服务卡片配置

### 1. 笔记列表卡片（2x4）

**功能：**
- 展示最近笔记列表
- 点击笔记快速打开
- 快速创建笔记按钮

**配置文件：**
```json5
{
  "widget": {
    "name": "NoteListWidget",
    "description": "展示最近笔记列表",
    "srcEntry": "./ets/widgets/NoteListWidget.ets",
    "minSupportVersion": 10,
    "widgetConfig": {
      "minDimensions": "2x4",
      "maxDimensions": "4x4",
      "updateDuration": 1  // 每小时更新一次
    }
  }
}
```

### 2. 快速创建卡片（2x2）

**功能：**
- 一键创建新笔记
- 选择笔记模板
- 快速启动应用

**配置文件：**
```json5
{
  "widget": {
    "name": "QuickCreateWidget",
    "description": "快速创建笔记",
    "srcEntry": "./ets/widgets/QuickCreateWidget.ets",
    "minSupportVersion": 10,
    "widgetConfig": {
      "minDimensions": "2x2",
      "maxDimensions": "2x2"
    }
  }
}
```

### 3. 协作邀请卡片（2x4）

**功能：**
- 展示协作邀请信息
- 一键接受邀请
- 查看协作详情

**配置文件：**
```json5
{
  "widget": {
    "name": "CollabInviteWidget",
    "description": "协作邀请卡片",
    "srcEntry": "./ets/widgets/CollabInviteWidget.ets",
    "minSupportVersion": 10,
    "widgetConfig": {
      "minDimensions": "2x4",
      "maxDimensions": "2x4"
    }
  }
}
```

## 四、元服务分享链接

### 1. 笔记分享链接

**格式：**
```
https://honghui.com/note/{noteId}?share={shareToken}
```

**参数：**
- `noteId`: 笔记ID
- `shareToken`: 分享令牌（有效期7天）

**实现：**
```typescript
async generateShareLink(noteId: string): Promise<string> {
  const shareToken = await this.generateShareToken(noteId);
  return `https://honghui.com/note/${noteId}?share=${shareToken}`;
}
```

### 2. 协作邀请链接

**格式：**
```
https://honghui.com/collab/{sessionId}?invite={inviteToken}
```

**参数：**
- `sessionId`: 协作会话ID
- `inviteToken`: 邀请令牌（有效期24小时）

**实现：**
```typescript
async generateInviteLink(sessionId: string): Promise<string> {
  const inviteToken = await this.generateInviteToken(sessionId);
  return `https://honghui.com/collab/${sessionId}?invite=${inviteToken}`;
}
```

### 3. 深度链接处理

**实现：**
```typescript
// 在EntryAbility中处理深度链接
onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
  const uri = want.uri;
  
  if (uri?.startsWith('honghui://note/')) {
    // 处理笔记链接
    const noteId = uri.split('/')[2];
    router.pushUrl({ url: 'pages/NotePage', params: { noteId } });
  } else if (uri?.startsWith('honghui://collab/')) {
    // 处理协作链接
    const sessionId = uri.split('/')[2];
    router.pushUrl({ url: 'pages/CollabPage', params: { sessionId } });
  }
}
```

## 五、元服务优化建议

### 1. 体积优化

**目标：** 控制在2MB以内

**优化方案：**
- 压缩图片资源（WebP格式）
- 移除未使用的资源
- 代码混淆和压缩
- 动态加载非核心功能

### 2. 性能优化

**目标：** 3秒内启动

**优化方案：**
- 延迟加载非必要模块
- 优化首屏渲染
- 使用懒加载图片
- 减少网络请求

### 3. 用户体验优化

**目标：** 无缝体验

**优化方案：**
- 免安装提示
- 加载动画
- 离线缓存
- 错误处理

## 六、测试验证清单

### 1. 元服务形态测试

- [ ] 免安装启动
- [ ] 卡片展示正确
- [ ] 分享链接有效
- [ ] 深度链接处理

### 2. 素材测试

- [ ] 应用图标显示正确
- [ ] 启动页显示正确
- [ ] 宣传图符合规范
- [ ] 卡片素材适配暗色模式

### 3. 卡片功能测试

- [ ] 笔记列表卡片更新
- [ ] 快速创建卡片可用
- [ ] 协作邀请卡片接受

### 4. 分享功能测试

- [ ] 笔记分享链接有效
- [ ] 协作邀请链接有效
- [ ] 深度链接跳转正确

## 七、实现优先级

### P0（必须实现）
1. ✅ 元服务形态确认
2. ⏳ 应用图标准备
3. ⏳ 启动页准备
4. ⏳ 元服务配置

### P1（建议实现）
1. ⏳ 宣传图准备
2. ⏳ 卡片素材准备
3. ⏳ 元服务卡片实现
4. ⏳ 分享链接实现

### P2（可选实现）
1. ⏳ 宣传视频准备
2. ⏳ 多语言素材
3. ⏳ 体积优化

## 八、相关文件

- `entry/src/main/module.json5` - 元服务配置
- `AppScope/app.json5` - 应用配置
- `entry/src/main/resources/base/media/` - 素材目录
- `entry/src/main/ets/widgets/` - 卡片目录（待创建）
- `docs/assets/` - 宣传素材目录（待创建）

## 九、参考资料

- [HarmonyOS 元服务开发指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/atomic-service-V5)
- [HarmonyOS 卡片开发指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/widget-development-V5)
- [华为应用市场素材规范](https://developer.huawei.com/consumer/cn/doc/app/50105)
