# 隐私合规优化文档（F-07）

## 一、当前实现状态

### 1. 权限配置（module.json5）

**已配置权限：**
```json5
"requestPermissions": [
  {
    "name": "ohos.permission.INTERNET",
    "reason": "$string:permission_internet_reason"
  },
  {
    "name": "ohos.permission.GET_NETWORK_INFO",
    "reason": "$string:permission_network_info_reason"
  },
  {
    "name": "ohos.permission.DISTRIBUTED_DATASYNC",
    "reason": "$string:permission_distributed_datasync_reason"
  },
  {
    "name": "ohos.permission.READ_MEDIA",
    "reason": "$string:permission_read_media_reason"
  },
  {
    "name": "ohos.permission.WRITE_MEDIA",
    "reason": "$string:permission_write_media_reason"
  }
]
```

**权限说明字符串：**
- `permission_internet_reason`: "用于同步白板数据、获取云端协作内容"
- `permission_network_info_reason`: "用于检测网络状态，优化数据同步策略"
- `permission_distributed_datasync_reason`: "用于跨设备协同编辑白板内容"
- `permission_read_media_reason`: "用于读取图片、PDF等媒体文件，支持插入图片和导出功能"
- `permission_write_media_reason`: "用于保存图片、PDF等文件，支持导出和分享功能"

### 2. 权限管理服务（PermissionManager.ets）

**已实现功能：**
- ✅ 权限检查（checkPermission）
- ✅ 权限申请（requestPermission）
- ✅ 批量权限申请（requestPermissions）
- ✅ 按需权限申请（requestNetworkPermission、requestMediaPermission、requestDistributedPermission）
- ✅ 权限申请回调（addPermissionCallback、removePermissionCallback）
- ✅ 权限说明获取（getPermissionReason）

**关键接口：**
```typescript
export enum PermissionType {
  INTERNET = 'ohos.permission.INTERNET',
  GET_NETWORK_INFO = 'ohos.permission.GET_NETWORK_INFO',
  DISTRIBUTED_DATASYNC = 'ohos.permission.DISTRIBUTED_DATASYNC',
  READ_MEDIA = 'ohos.permission.READ_MEDIA',
  WRITE_MEDIA = 'ohos.permission.WRITE_MEDIA'
}

export interface PermissionResult {
  permission: PermissionType;
  granted: boolean;
  reason?: string;
}
```

### 3. 隐私同意服务（PrivacyConsentService.ets）

**已实现功能：**
- ✅ 隐私同意状态检查（checkConsent）
- ✅ 隐私同意状态保存（acceptConsent）
- ✅ 隐私同意状态获取（isConsentAccepted）

**关键接口：**
```typescript
// 检查是否已同意隐私政策
async checkConsent(): Promise<boolean>

// 保存隐私同意状态
async acceptConsent(): Promise<void>

// 获取隐私同意状态
isConsentAccepted(): boolean
```

### 4. 隐私政策弹窗（PrivacyDialog.ets）

**已实现功能：**
- ✅ 隐私政策内容展示
- ✅ 同意/拒绝选项
- ✅ 拒绝后退出应用
- ✅ 同意状态保存

**隐私政策内容：**
- 信息收集与使用
- 权限说明
- 信息存储与保护
- 信息共享
- 用户权利
- 联系方式
- 政策更新

### 5. EntryAbility集成

**已实现功能：**
- ✅ 隐私同意服务初始化（privacyConsentService.init）
- ✅ 隐私同意检查（initServicesWithPrivacyCheck）
- ✅ 首次启动弹窗逻辑

## 二、优化建议

### 1. 权限申请时机优化

**当前问题：**
- 所有权限在应用启动时申请，可能造成用户困扰
- 未实现按需申请策略

**优化方案：**
```typescript
// 在需要使用权限时才申请
// 例如：用户点击"插入图片"时才申请媒体权限
async handleInsertImage(): Promise<void> {
  const results = await permissionManager.requestMediaPermission();
  
  if (results.every(r => r.granted)) {
    // 权限已授予，执行插入图片逻辑
    this.showImagePicker();
  } else {
    // 权限被拒绝，显示说明并降级
    this.showPermissionDeniedDialog('需要媒体权限才能插入图片');
  }
}
```

### 2. 权限拒绝降级方案

**当前问题：**
- 权限被拒绝后缺少降级方案
- 用户无法理解权限用途

**优化方案：**
```typescript
// 创建权限拒绝对话框
@CustomDialog
struct PermissionDeniedDialog {
  controller: CustomDialogController;
  @Prop permission: PermissionType;
  @Prop message: string;
  
  build() {
    Column() {
      Text('权限被拒绝')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
      
      Text(this.message)
        .fontSize(14)
        .fontColor('#666666')
        .margin({ top: 16 })
      
      Text(permissionManager.getPermissionReason(this.permission))
        .fontSize(12)
        .fontColor('#999999')
        .margin({ top: 8 })
      
      Row() {
        Button('取消')
          .onClick(() => this.controller.close())
        
        Button('去设置')
          .onClick(() => {
            // 跳转到系统设置页面
            this.openSystemSettings();
            this.controller.close();
          })
      }
      .margin({ top: 24 })
    }
  }
}
```

### 3. 隐私政策内容优化

**当前问题：**
- 隐私政策内容为硬编码，不易维护
- 缺少版本号和更新日期管理

**优化方案：**
```typescript
// 将隐私政策内容移至资源文件
// entry/src/main/resources/rawfile/privacy_policy.txt

// 在代码中读取
async loadPrivacyPolicy(): Promise<string> {
  const ctx = getContext(this) as common.UIAbilityContext;
  const resMgr = ctx.resourceManager;
  const content = await resMgr.getRawFileContent('privacy_policy.txt');
  return String.fromCharCode(...new Uint8Array(content));
}
```

### 4. 隐私同意状态持久化优化

**当前问题：**
- 隐私同意状态仅保存在Preferences，应用卸载后丢失
- 缺少隐私政策版本管理

**优化方案：**
```typescript
// 添加隐私政策版本管理
const PRIVACY_POLICY_VERSION = '1.0.0';

interface PrivacyConsentData {
  accepted: boolean;
  version: string;
  timestamp: number;
}

async checkConsent(): Promise<boolean> {
  const prefs = await preferences.getPreferences(this.context, PREFERENCES_NAME);
  const dataStr = await prefs.get(PRIVACY_CONSENT_KEY, '') as string;
  
  if (!dataStr) {
    return false;
  }
  
  const data = JSON.parse(dataStr) as PrivacyConsentData;
  
  // 检查版本是否匹配
  if (data.version !== PRIVACY_POLICY_VERSION) {
    // 隐私政策已更新，需要重新同意
    return false;
  }
  
  return data.accepted;
}
```

## 三、测试验证清单

### 1. 权限申请测试

- [ ] 首次启动：隐私政策弹窗显示
- [ ] 同意隐私政策：应用正常启动
- [ ] 拒绝隐私政策：应用退出
- [ ] 按需申请权限：权限申请时机正确
- [ ] 权限拒绝：降级方案生效

### 2. 隐私政策测试

- [ ] 隐私政策内容完整
- [ ] 隐私政策版本管理
- [ ] 隐私政策更新提示
- [ ] 隐私政策可查看

### 3. 权限说明测试

- [ ] 每个权限都有说明
- [ ] 权限说明准确清晰
- [ ] 权限说明符合应用商店要求

### 4. 隐私同意状态测试

- [ ] 隐私同意状态持久化
- [ ] 应用卸载后状态清除
- [ ] 隐私政策更新后重新提示

## 四、实现优先级

### P0（必须实现）
1. ✅ 权限配置与说明
2. ✅ 隐私同意服务
3. ✅ 隐私政策弹窗
4. ✅ EntryAbility集成

### P1（建议实现）
1. ⏳ 按需权限申请
2. ⏳ 权限拒绝降级方案
3. ⏳ 隐私政策版本管理

### P2（可选实现）
1. ⏳ 隐私政策内容外置
2. ⏳ 隐私政策更新通知
3. ⏳ 权限使用统计

## 五、相关文件

- `entry/src/main/module.json5` - 权限配置
- `entry/src/main/resources/base/element/string.json` - 权限说明字符串
- `entry/src/main/ets/common/services/PermissionManager.ets` - 权限管理服务
- `entry/src/main/ets/common/services/PrivacyConsentService.ets` - 隐私同意服务
- `entry/src/main/ets/components/PrivacyDialog.ets` - 隐私政策弹窗
- `entry/src/main/ets/entryability/EntryAbility.ets` - 应用入口集成

## 六、参考资料

- [HarmonyOS 权限开发指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/permissions-overview-V5)
- [HarmonyOS 隐私合规指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/privacy-compliance-V5)
- [华为应用市场审核规范](https://developer.huawei.com/consumer/cn/doc/app/50104)
