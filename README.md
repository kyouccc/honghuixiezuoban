# 鸿绘协作板 Honghui

> 鸿蒙生态中「分布式协同 + 原子化服务 + 端侧AI」三位一体的实时协作白板应用

## 项目结构

```
honghui/
├── entry/                     # 鸿蒙元服务主模块 (ArkTS + ArkUI)
│   ├── module.json5           # 模块配置（Ability声明/NFC权限/元服务卡片）
│   ├── build-profile.json5    # 编译配置（资源压缩/代码混淆）
│   └── src/main/ets/
│       ├── entryability/      # 应用入口（NFC/DeepLink处理）
│       ├── pages/             # 页面（白板/加入房间/设备管理）
│       ├── engine/            # 白板引擎（Canvas渲染/笔触/图层/形状/橡皮/撤销）
│       ├── crdt/              # CRDT RGA算法引擎
│       ├── distributed/       # 分布式软总线（设备发现/角色分配/状态监听）
│       ├── ai/                # MindSpore Lite端侧AI（草图识别/OCR/端云协同）
│       ├── network/           # 网络层（WebSocket/信令编解码/REST API）
│       ├── widget/            # 元服务卡片
│       ├── model/             # 数据模型
│       └── common/            # 公共工具（常量/日志/UUID/性能追踪）
├── backend/                   # Go后端服务
│   ├── cmd/signal-gateway/    # 信令网关入口
│   ├── deploy/k8s/            # K8s部署配置（CCE弹性扩缩）
│   └── Dockerfile             # 容器构建
├── proto/                     # Protobuf信令协议定义
└── docs/                      # 架构设计文档
```

## 上架鸿蒙应用市场步骤

### 1. 开发环境准备
```bash
# 安装 DevEco Studio 5.0+
# 下载地址: https://developer.huawei.com/consumer/cn/download/

# 安装 hvigor 构建工具
# DevEco Studio 自带，命令行使用:
hvigorw --version
```

### 2. 构建hap包
```bash
# Debug构建
hvigorw assembleHap -p buildMode=debug

# Release构建（含代码混淆和资源压缩）
hvigorw assembleHap -p buildMode=release

# 输出路径: entry/build/default/outputs/default/
```

### 3. 生成签名证书
1. DevEco Studio → Build → Generate Key and CSR
2. 在 AppGallery Connect (https://developer.huawei.com) 注册应用
3. 下载Profile文件(.p7b)
4. 配置签名: File → Project Structure → Signing Configs

### 4. 提交审核
1. 登录 https://developer.huawei.com → 应用市场
2. 创建应用 → 填写应用信息
3. 上传hap包
4. 提交审核（通常3-5个工作日）

### 5. 元服务备案
- 元服务需要单独备案（参考华为元服务审核指南）
- 在AGC中配置元服务信息
- 关联FormExtensionAbility

## 技术亮点

| 特性 | 技术方案 | 指标 |
|------|---------|------|
| 分布式组网 | OpenHarmony分布式软总线 + NFC | 碰一碰3秒加入（实测中位3.2s） |
| 白板引擎 | ArkUI Canvas + Catmull-Rom | 笔触≤9ms / ≥55FPS |
| 多人协作 | CRDT RGA算法 + WebSocket + Redis分片广播 | P95≤150ms |
| 无网协同 | 近场软总线直连 + CRDT向量时钟对账合并 | 断外网可协作（SV-09） |
| 弹性架构 | 华为云CCE + HPA + CronHPA定时预扩 + 优雅驱逐 | 10000并发（常态10 Pod承载2万连接） |
| 端侧AI | MindSpore Lite INT8量化（QuickDraw/CASIA-HWDB微调） | 模型≤20MB / 推理≤50ms |
| AI纪要官 | CRDT操作日志 → 已备案大模型 → 元服务卡片推送 | 会后自动纪要/待办 |

## 开源协议

本项目采用 [Apache License 2.0](./LICENSE)，第三方依赖许可清单见 [NOTICE](./NOTICE)。

## 快速开发

```bash
# 启动Go后端（本地开发）
cd backend
go run cmd/signal-gateway/main.go

# 部署到K8s
kubectl apply -f backend/deploy/k8s/
```

## 文档索引

| 文档 | 说明 |
|---|---|
| [架构时序图](./docs/sequence-diagram-v2.mermaid) | 端到端调用流程 |
| [架构类图](./docs/class-diagram-v2.mermaid) | 核心数据模型 |
| [构建与验证](./docs/BUILD-VERIFY.md) | 如何编译与自检 |
| [隐私合规](./docs/privacy_compliance.md) | 权限与数据合规说明 |
| [原子化服务准备](./docs/atomic_service_preparation.md) | 免安装卡片能力规划 |
| [折叠屏适配](./docs/fold_screen_adaptation.md) | 大屏 / 折叠形态适配 |
| [一多适配](./docs/one_multiple_adaptation.md) | 一次开发多端部署 |
| [PDF 栅格化可行性](./docs/v2q1-pdf-rasterize-feasibility.md) | 批注底图技术选型 |
| [图标规范](./docs/icon-migration-guide.md) | 图标资源规范 |
| [验收报告模板](./docs/verification-report-template.md) | 真机验证记录模板 |
| [测试说明](./tests/README.md) | 单元测试与回归说明 |
| [签名配置模板](./build-profile.json5.template) | 换机后如何恢复签名 |
| [命令行打包脚本](./build-and-sign.bat) | 命令行构建与签名 |
