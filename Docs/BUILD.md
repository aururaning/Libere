# 构建、测试与打包

## 环境

- Mac 和完整 Xcode。0.6.10 已使用 Xcode 27.2 完成构建；这是已验证环境，不表示所有较早版本均不可用。
- 运行目标为 macOS 14+、iPadOS 17+。部分输入行为会按系统版本启用。
- Python 3，用于工程验证、资源生成和打包脚本。
- Notebook 执行需要选中的 Python 环境安装 `jupyter_client` 与 `ipykernel`。Agent MCP 桥接器只使用 Python 标准库，要求 Python 3.9+。

若系统未选择完整 Xcode，可为当前终端指定实际安装位置：

```bash
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
xcodebuild -version
```

以下命令都在仓库根目录运行。工程内部 target、scheme 和包名保留 `MarginNotes`，显示名称与可执行文件名为 `Libere`。

## Mac 本地构建

仅构建：

```bash
bash Scripts/build-mac-local.sh
```

构建并打开：

```bash
bash Scripts/run-mac.sh
```

输出为 `.build/XcodeProducts/Debug/Libere.app`。脚本使用 Xcode 处理图标资源，再以 `-O -whole-module-optimization` 编译本地运行的可执行文件并临时签名；按当前机器架构构建，不生成通用二进制。默认本地构建关闭 CloudKit。

`--reuse-sdk-build` 仅用于相同源代码和资源已完成 SDK 构建的开发场景。日常构建使用不带该参数的命令。

## Mac 安装包

从源码完整构建并生成 PKG：

```bash
bash Scripts/build-mac-package.sh
```

已有本地构建产物时，单独打包：

```bash
python3 Scripts/package-mac.py
```

打包默认读取 `.build/XcodeProducts/Debug/Libere.app`，输出到 `dist/`：

- `Libere-<版本>-<架构>.pkg`
- 同名 `.pkg.sha256` 校验和
- 同名 `.pkg.manifest.json` 验证清单

可传入 `--app /path/to/Libere.app` 和 `--output-dir /path/to/output`。脚本拒绝覆盖已有同名文件。需要 DMG 时使用 `--format dmg`；其创建和验证需要当前 Mac 允许设备映像操作。

PKG 安装目标固定为 `/Applications/Libere.app`，不通过应用标识查找其他位置的副本；包内没有安装脚本。打包本身不安装应用。脚本校验源应用、复制后的应用及解包后的内容和签名，并写出校验和与清单。

Mac 本地构建会在签名前将 LICENSE、NOTICE 和 THIRD_PARTY_NOTICES.md 放入应用资源目录，打包时核对它们与源码一致。分发其他方式构建的版本时，也应附带这些许可与声明文件。

## Xcode 与 iPad

1. 打开 `MarginNotes.xcodeproj`，选择 `MarginNotes` scheme。
2. Mac 目的地选择 `My Mac`；iPad 目的地选择相应模拟器。
3. 在真实 iPad 上运行时，设置自己的签名 Team 和唯一 Bundle Identifier，按 Xcode 提示配置设备。
4. 使用 CloudKit 时，按 [ICLOUD.md](ICLOUD.md) 配置自己的容器与权限，再选择 `MarginNotes-iCloud` scheme。

仓库里的应用与 CloudKit 标识是开发默认值；独立分发自己的构建时，应配置自己的签名身份与容器。

## 检查命令

快速检查工程引用和资源：

```bash
python3 Scripts/verify_project.py
```

核心模型与原生交互检查：

```bash
bash Scripts/check-core.sh
bash Scripts/check-native.sh
```

SwiftPM XCTest、Python Agent 桥接测试，以及 Mac / iPad Simulator / iPad 设备 SDK 构建：

```bash
bash Scripts/check.sh
```

`check.sh` 需要 Xcode 的 iOS Simulator 与设备 SDK。中间构建数据使用临时目录，检查日志与产物写入 `.build/`。Agent 的真实本机通信可另行执行 `bash Scripts/check-native.sh --test-agent-transport`；Notebook 实际内核检查为 `python3 Scripts/test_notebook_kernel.py`，需要前述 Python 依赖。

## 资源维护

更换品牌源图后生成图标：

```bash
bash Scripts/prepare-brand-assets.sh
```

仅在维护场景示例时重建素材：

```bash
mkdir -p .build/module-cache
xcrun swiftc -module-cache-path .build/module-cache Scripts/MakeShowcasePDFs.swift -o .build/MakeShowcasePDFs
.build/MakeShowcasePDFs .build/showcase-assets
python3 Scripts/generate-showcase.py
```

场景中使用固定页面与附件 ID。不要通过更换 ID 强制覆盖用户已经编辑过的示例内容。

本地打包使用临时签名，不能代替 Developer ID 发行签名或 Apple 公证。构建和测试通过也不代替系统文件授权、真实触控、随航或 CloudKit 多设备验收，具体范围见 [VALIDATION.md](VALIDATION.md)。
