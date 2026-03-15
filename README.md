# MacFan

macOS 风扇控制工具，专为 Apple Silicon 设计。通过菜单栏实时监控温度与风扇转速，支持手动调速和自动配置方案。

## 功能

- **实时监控** — 菜单栏显示 CPU/GPU/SSD 温度及风扇转速
- **手动控制** — 拖动滑块设置任意风扇的目标转速
- **配置方案** — 按温度阈值自动调速，支持多条件触发（充电/电池/电量低于 X%）
- **内置预设** — Quiet / Performance / Full Speed 三套方案开箱即用
- **一次授权** — 特权 Helper 安装后以 LaunchDaemon 运行，无需反复输入密码
- **命令行工具** — `macfan-cli` 支持 status / set / max / auto / debug 命令

## 安装

### GUI 应用

从 [Releases](https://github.com/ryusaksun/macfan/releases) 下载最新 DMG：

1. 打开 `MacFan-vX.X.X.dmg`
2. 拖拽 **MacFan.app** 到 **Applications**
3. 启动后点击菜单栏图标 → **Install Helper**（需输入一次密码）

### 命令行工具

```bash
git clone https://github.com/ryusaksun/macfan.git
cd macfan
swift build -c release
# 二进制位于 .build/release/macfan-cli
```

## 使用

### GUI

启动后 MacFan 以菜单栏图标常驻，点击即可：

- 查看所有风扇转速（RPM 和百分比）
- 查看分类温度传感器读数
- 切换 Auto / Max 快捷模式
- 对单个风扇切换 Manual 模式并滑动调速
- 启用配置方案，温度变化时自动调整

### CLI

```bash
macfan-cli status          # 查看风扇和温度状态
macfan-cli list -v         # 列出所有传感器（含 SMC key 详情）
sudo macfan-cli set 0 3000 # 设置风扇 0 为 3000 RPM
sudo macfan-cli max        # 所有风扇全速
sudo macfan-cli auto       # 恢复自动控制
macfan-cli debug --scan    # 扫描所有 SMC 键（调试用）
```

> 写入操作（set / max / auto）需要 `sudo`。

## 架构

三层权限分离设计：

```
MacFan.app (用户权限)
    │
    ├── SMC 读取 (IOKit，无需 root)
    │   → 温度、风扇转速、电池状态
    │
    └── XPC ──▶ MacFanHelper (root daemon)
                  │
                  └── SMC 写入 (IOKit，需要 root)
                      → 设置风扇模式、目标转速
```

| 模块 | 说明 |
|------|------|
| `Sources/MacFanCore/` | 共享库：SMCKit、DataTypes、FanMonitor、ProfileManager |
| `Sources/MacFanApp/` | SwiftUI 菜单栏应用 |
| `Sources/MacFanHelper/` | 特权 XPC daemon（代码签名验证） |
| `Sources/macfan-cli/` | ArgumentParser 命令行工具 |

### 构建

```bash
# CLI（SPM）
swift build

# GUI（XcodeGen + Xcode）
xcodegen generate
xcodebuild -project MacFan.xcodeproj -scheme MacFan -configuration Release build
```

`MacFan.xcodeproj` 由 `project.yml` 生成，不入库。

## 配置方案

配置保存在 `~/Library/Application Support/MacFan/profiles.json`，每 2 秒评估一次：

- 规则按温度阈值降序排列，首个匹配的规则生效
- 支持 3°C 温度迟滞，避免频繁切换
- 触发条件：Always / Charging / On Battery / Battery Below X%

示例（Quiet 方案）：

| 温度 ≥ | 风扇转速 |
|--------|----------|
| 80°C | 100% |
| 70°C | 60% |
| 60°C | 30% |

## 系统要求

- macOS 13+ (Ventura)
- Apple Silicon (M 系列芯片)

## 许可

MIT License
