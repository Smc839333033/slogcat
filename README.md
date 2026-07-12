# slogcat

一个 macOS 端实时抓取 Android / HarmonyOS 日志的工具，提供过滤、屏蔽、搜索等功能。轻量高性能，适合不想为看日志而启动 Android Studio / DevEco Studio 的开发者。

## 截图

| 夜间模式 | 日间模式 |
| :---: | :---: |
| ![dark mode](docs/screenshot-dark.png) | ![light mode](docs/screenshot-light.png) |

## 环境要求

- macOS 14.0 (Sonoma) 或更高
- Xcode Command Line Tools（`xcode-select --install`）
- 抓取 Android 日志：Android SDK platform-tools 中的 `adb`（自动检测 `~/Library/Android/sdk/platform-tools/adb`，也可在设置中手动指定路径）
- 抓取 HarmonyOS 日志（可选）：HarmonyOS/OpenHarmony SDK 中的 `hdc`（自动检测 DevEco Studio 应用包及常见 SDK 路径，也可在设置中手动指定路径）。未安装 `hdc` 不影响 Android 使用

## 功能

- 实时流式抓取 Android `adb logcat` 与 HarmonyOS `hdc shell hilog`，50ms 增量追加，滚动丝滑
- 两平台设备统一混合在同一下拉列表，带 `[ADB]` / `[HDC]` 标签；后台自动轮询热插拔设备
- 切换设备（含跨平台切换）时自动清空日志并重新开始，不同来源日志不混淆
- 按平台自动分派日志解析器，HarmonyOS 日志格式与 Android 独立处理，互不影响
- NSTextView + 环形缓冲区（默认 20000 行，可配置），零 diff 追加
- 后台 Actor 离线构建 NSAttributedString，主线程不卡顿
- 多规则过滤系统：内容/Tag 的包含/排除/正则，PID 精确匹配
- 排除优先级高于包含，包含之间为 OR 关系
- 实时搜索：增量扫描新追加文本，匹配数量/位置实时更新，跳转时锁定位置不被新日志冲走
- 日间/夜间双主题，Nothing-style 极简 UI
- 字体大小、最大显示行数、主题模式持久化
- 自定义应用图标，支持打包为 .app / .dmg

## 快速开始

### 源码运行

```bash
cd slogcat
swift run
```

### 编译 Release

```bash
swift build -c release
```

产物路径：`.build/release/Slogcat`

### 打包为 .app / .dmg

```bash
./build-app.sh          # 仅生成 .app
./build-app.sh --dmg    # 同时生成可分发的 .dmg 安装包
```

产物路径：
- `build/slogcat.app` — 可直接双击运行或拖入 Applications
- `build/slogcat.dmg` — DMG 安装包（挂载后拖动 slogcat.app 到 Applications 即可安装）

`build-app.sh` 会自动完成：release 编译 → 组装 .app bundle（含 Info.plist + AppIcon.icns）→ ad-hoc 签名。加 `--dmg` 时额外把 .app 与 `Applications` 快捷方式打进 DMG，用户挂载后拖拽即可安装。

## 项目结构

```
slogcat/
├── Package.swift                  # SPM 包定义
├── build-app.sh                  # 打包脚本
├── Resources/
│   ├── AppIcon.icns              # 应用图标
│   └── Info.plist                # Bundle 配置
└── Sources/Slogcat/
    ├── SlogcatApp.swift           # @main 入口
    ├── Models.swift               # Platform / LogLevel / LogEntry / Device / FilterRule
    ├── FilterEngine.swift         # 过滤规则编译与匹配（平台无关）
    ├── RingBuffer.swift           # 环形缓冲区
    ├── Components.swift           # LogConfig / DotGridBackground / 工具组件
    ├── Adb/
    │   ├── AdbProcess.swift       # adb 子进程封装 + 路径检测
    │   ├── DeviceManager.swift    # adb 设备列表
    │   ├── LineParser.swift       # Android logcat 行解析
    │   ├── HdcProcess.swift       # hdc 子进程封装 + 路径自动检测
    │   ├── HdcDeviceManager.swift # hdc 设备列表（hdc 缺失时静默）
    │   └── HilogLineParser.swift  # HarmonyOS hilog 行解析
    ├── Core/
    │   ├── LogPipeline.swift      # 后台 Actor：按平台解析+过滤+AttributedString 构建
    │   └── LogStore.swift         # @Observable UI 状态容器 + 平台分派
    ├── Theme/
    │   └── LogTheme.swift         # 主题 + ThemeManager + TechField
    └── Views/
        ├── ContentView.swift      # 主视图 + Toolbar + 设置页
        ├── FilterPanel.swift      # 过滤器 UI + FlowLayout
        └── LogTextView.swift       # NSTextView 封装 + LogCoordinator
```

## 技术栈

- Swift 5.10+ / SwiftUI (macOS 14+)
- SPM executable target（无 Xcode 项目）
- NSTextView via NSViewRepresentable（绕过 SwiftUI List 性能瓶颈）
- `@Observable` + `@MainActor` 状态管理
- `actor LogPipeline` 后台离线构建
- UserDefaults 持久化配置

## 许可

MIT
