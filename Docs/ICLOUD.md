# 在 Mac 与 iPad 上启用 iCloud

## 准备工程

1. 安装 Xcode，登录自己的 Apple 开发账号。
2. 在 `Config/Base.xcconfig` 中设置唯一 `PRODUCT_BUNDLE_IDENTIFIER` 和自己的 `DEVELOPMENT_TEAM`。
3. 将 `MARGIN_CLOUD_CONTAINER` 改为你的容器，例如 `iCloud.com.example.Libere`。这个例子不是已创建的容器。
4. 选中 App Target，在 **Signing & Capabilities** 启用 **iCloud → CloudKit**，创建或选择与上面完全相同的容器；两个平台使用相同容器。
5. Cloud 构建的 entitlements 已包含 CloudKit 和相应平台的推送环境声明。确认开发描述文件包含这些能力。iPad 的 Background Modes 保留 Remote notifications。当前前台同步不使用后台推送刷新。
6. 选择 **MarginNotes-iCloud** 方案，分别在登录同一 Apple 账号的 Mac 与 iPad 上运行。
7. 点击应用右下角 iCloud 状态启用/同步。首次会创建私有记录区域。

`MarginNotes` 方案默认 `MARGIN_CLOUD_ENABLED = NO`，可独立验证本地功能。`MarginNotes-iCloud` 使用 iCloud 配置并将该值设为 `YES`。不要只改 Info.plist 而遗漏签名与容器权限。

## CloudKit 数据

使用 private database，custom zone 为 `MarginNotesV1`。

| 记录类型 | 字段 | 用途 |
| --- | --- | --- |
| MarginPage | payload: Asset | 一页/文件夹的 JSON，包括文字、锚点、手写与版本向量 |
| MarginPage | revision: String | 本次内容版本 UUID |
| MarginPage | vector: Bytes | 云端回执确认的因果版本 |
| MarginAsset | file: Asset | 导入的附件文件 |

首次开发构建在 Development 环境建立记录与字段。准备 TestFlight/App Store 前，应在 CloudKit Console 将 schema 部署到 Production，并重新配置发布用签名、推送环境及打包。仓库提供开发运行配置；账号、容器和发布签名需要由构建者自行配置。

## 同步时机

开启同步后，应用在前台每 30 秒尝试同步；回到前台与点击状态按钮也会同步。CloudKit 服务可能延迟或返回错误，UI 会保留待同步状态。本机原子写入先于云操作。

`CKSyncEngine` 状态写入 `Sync/engine.json`；记录系统字段用于乐观并发；独立 outbox 和工作区在同一次保存中落盘。上传期间继续编辑不会被旧回执误判为已同步。恢复账号或网络后可手动重试；本地持久化失败或云端记录被直接删除时会暂停同步。

首次成功连接后会将 iCloud 账号 ID 绑定到这份本地资料库。更换账号不会把原资料自动上传到新账号。回到原账号并重启应用后恢复。跨账号迁移应先导出完整备份并明确选择新的资料库，而非删除内部状态文件。

## 双设备验收

- Mac 建一页，输入格式文字与公式，导入 PDF；同步后在 iPad 确认内容和附件。
- iPad 新建三个锚点、两条文字批注，锁定资料，再写手写批注；Mac 同步后确认几何位置。
- 两端离线编辑同一页的不同内容，再连接网络同步。两个完整版本应可找到，不能静默丢掉一个版本。
- 网络上传期间继续修改同页；上传旧回执到达后，新修改仍应留在待同步列表。
- 删除与编辑并行时，编辑版本保留；单设备正常删除后，另一端出现回收站状态。
- 退出或更换 iCloud 账号，确认原内容仍在本机且未发往另一个账号。

以上是使用自己的容器与设备时需要执行的验收步骤，不是已通过的多设备测试结果。
