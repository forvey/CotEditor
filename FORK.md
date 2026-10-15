# Forvey 定制版

此 fork 将编辑功能放在 CotEditor 本体中，不依赖额外 App、鼠标监听器、辅助功能权限或外部脚本。

## 使用

- **⌥⌘L**：全文 JSON / PostgreSQL 格式化与压缩切换。可先选择 JSON 或 SQL 语法；纯文本也会识别常见语句。保留 SQL 大小写、字符串、注释和 JSON 数字的原始拼写。压缩 SQL 时，每条顶层语句单独一行；行注释和字符串内部的换行保留。不能安全转换时不替换文本。格式化使用标准编辑接口，可一次撤销。
- 在显式列名的 `INSERT INTO … (columns) VALUES (…)` 中**双击字段或值**：气泡仅展示对应内容，同时标记其位置；单击或编辑即取消。支持多行 VALUES、函数、数组、引号和美元字符串。多行 VALUES 中一个列名可能对应多个值；不展示整张字段映射列表。INSERT SELECT、缺少列名或字段数量不一致时不推测对应关系。
- 文件统一追加到同一个编辑器窗口的页签；**右侧＋一直可见**。支持 ⌘N / ⌘T、⌘数字、切换页签、页签关闭按钮及 ⌘W。页签不支持拖出独立窗口。设置、查找等辅助窗口仍保留。此版本禁用文件夹窗口，可一次选择多个文件。
- **红色窗口关闭按钮或 ⌘Q**：先备份所有页签和草稿，再退出，不弹保存文件对话框。**⌘S 才写入原文件**。下次启动自动恢复草稿、页签、语法、编码及选区。切换页签保留各自的撤销栈；重启后不恢复撤销栈。
- 关闭页签后，可用**⇧⌘T**恢复最近关闭的 20 个页签。备份失败时保留页签或取消退出，并显示错误。
- **文件 → 收藏文件**：收藏当前已保存的文件、打开收藏、移除收藏。未命名草稿须先保存才能收藏。收藏与最近文件分别保存，重启后仍保留。使用 macOS 文件书签维持沙盒访问权限。

会话文件在应用自身 Application Support 下的 `com.forvey.CotEditor/Workspace`，包含 `session.json` 和上一份有效备份。主文件损坏时尝试上一份；两份都不可读时保留文件并阻止覆盖，应先手动备份目录后处理错误。恢复未保存改动时，如果原文件丢失、无法访问或修改时间已变化，将内容恢复为未命名草稿，避免覆盖外部修改。备份以当前用户权限保存（目录 0700、文件 0600），未加密。

定制版 Bundle ID 为 `com.forvey.CotEditor`，与官方版的偏好设置和沙盒数据分开。源码提交不会替换机器上已安装的官方 CotEditor。

## 构建与验证

项目沿用上游 `main` 的 Xcode 27 项目格式（`project.xcproj`）及 Swift 6.3+ 要求，需要完整 Xcode；Command Line Tools 无法完成应用构建。请打开 `CotEditor.xcodeproj`，使用 CotEditor scheme。默认使用本地 ad-hoc 签名，不需要上游开发团队证书。

```sh
swift test --package-path Packages/CustomizationCore
xcodebuild test -scheme CotEditor CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS_SUFFIX=-AdHoc -skipPackagePluginValidation
```

独立模块覆盖格式转换、SQL 词法与字段映射、备份损坏恢复、写入失败和收藏持久化。应用测试 `NativeEditorToolsTests` 覆盖格式化撤销、异步结果过期及页签切换后撤销。完整应用及这些应用测试必须在装有 Xcode 的环境运行；上游 CI 的 `xcode-27` runner 标签也需要可用的 runner。

2026-10-15 已在 macOS 27、Xcode 27.0（27A266a）、Apple Silicon 上完成验证：独立模块 8 项测试和 `NativeEditorToolsTests` 3 项应用测试全部通过。构建使用默认 SwiftPM 缓存目录；本机仍将 Command Line Tools 设为默认时，可在命令前加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。Release 版本可用 `xcodebuild build -scheme CotEditor -configuration Release -destination 'platform=macOS,arch=arm64' -skipPackageUpdates -skipPackagePluginValidation` 构建。

人工验收应使用临时文件：单文件时＋可见；连续打开文件只有一个编辑器窗口；格式化后撤销及切换页签后撤销；全屏双击字段/值显示气泡且文本不变；收藏后重启仍可打开；未保存草稿退出重启恢复；磁盘写入错误时退出被取消。

## 第三方代码

SQL 格式化内置 [sql-formatter](https://github.com/sql-formatter-org/sql-formatter) 15.9.0 的浏览器 UMD 构建，使用 JavaScriptCore 执行，无需 Node.js。MIT 许可证随模块资源提供：`Packages/CustomizationCore/Sources/CustomizationCore/Resources/sql-formatter-LICENSE.txt`。JSON 通过保留原始 token 的验证和排版实现，避免浮点或大整数重编码。
