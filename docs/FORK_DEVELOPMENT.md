# Forvey CotEditor 开发交接

记录日期：2026-10-17。行为基线为本仓库的五次功能提交，最后一笔为 `af1640e`。本文依据当前源码、此前验收记录和用户最终选择整理；未验证事项单独列出，不把尝试过的方案写成已实现功能。

## 项目身份与工作位置

| 项目 | 约定或当前事实 |
| --- | --- |
| 正式仓库 | `https://github.com/forvey/CotEditor.git` |
| 本地固定位置 | `~/workspace/CotEditor`，后续迭代统一使用此目录 |
| 早期误放位置 | `~/Documents/Codex/2026-10-13/ba/CotEditor`；迁移时先推送，再从远端重新克隆，不只复制工作树 |
| 上游基线 | `9984e70`，之后有五笔定制功能提交 |
| Bundle ID | `com.forvey.CotEditor`，与官方 `com.coteditor.CotEditor` 分离 |
| 本机安装位置 | `/Applications/CotEditor Forvey.app`；进程显示名仍为 CotEditor |
| 已安装版本 | `7.2.0-alpha` / build `853`，本地 ad-hoc 签名 |
| 最低系统版本 | 工程、包和已安装应用均声明 macOS 26.0 |
| 已构建架构 | 现有本机安装版为 `arm64`，不是 Universal |

仓库位置、应用位置和用户数据位置互不等同。重新克隆代码不会更新已安装应用，也不会自动迁移草稿或收藏。不要把个人恢复 SQL、会话备份、书签或默认应用设置备份提交到公共仓库。

## 已实现功能与源码入口

| 功能 | 现有行为 | 主要入口 |
| --- | --- | --- |
| JSON / SQL 格式化与压缩 | `⌥⌘L` 切换，作用于全文；SQL 为 PostgreSQL，保留大小写 | `ContentLayout.swift`、`JSONLayout.swift`、`SQLCompanion.swift` |
| INSERT 对应提示 | 双击列名显示对应值；双击值显示列名；原文对应位置高亮；单击或编辑清除 | `SQLInsert.swift`、`SQLLexer.swift`、`SQLCompanion.swift`、`EditorTextView.swift` |
| 气泡内容自适应 | 短内容使用较小气泡，长内容换行或滚动；上限 500 × 260 点，窄窗口继续限宽 | `SQLCompanion.show` |
| 单窗口页签 | 打开、新建统一进入同一编辑器窗口，`＋` 单页签时也常驻 | `DraftWorkspace.swift`、`DocumentController.swift`、`DocumentWindow.swift` |
| 页签关闭外观 | 关闭按钮在页签内部左侧，当前页签或悬停时出现 | `WorkspaceTabItem`、`WorkspaceTabStrip` |
| 关闭与退出恢复 | 红色关闭按钮、`⌘Q` 先备份后退出；`⌘S` 才写回原文件 | `DraftWorkspace`、`DraftStore`、`Document.swift`、`DocumentWindowController.swift` |
| 关闭页签恢复 | `⇧⌘T` 恢复最近关闭的 20 个页签 | `DraftWorkspace.prepareToClose` / `reopenTab` |
| 文件收藏 | 文件菜单及页签右键收藏；非当前页签可直接操作；未保存草稿禁用收藏 | `ForkMenus.swift`、`FavoriteFiles.swift`、`WorkspaceTabItem.menu` |
| 未命名编号复用 | 选择当前空闲的最小编号，关闭后可复用，重启保持草稿名 | `DraftWorkspace.assignDraftName`、`Document.workspaceDraftName`、`Draft` |

完整路径：

- 核心模块：`Packages/CustomizationCore/Sources/CustomizationCore/`。
- 原生气泡及格式化编辑入口：`CotEditor/Sources/Document Window/Text View/SQLCompanion.swift`。
- 文本鼠标事件和高亮调用：`CotEditor/Sources/Document Window/Text View/EditorTextView.swift`。
- 页签、草稿与生命周期：`CotEditor/Sources/Document/DraftWorkspace.swift`。
- 每个文档的编辑视图缓存：`CotEditor/Sources/Document Window/Content View/ContentViewController.swift`，由 `WindowContentViewController.swift` 转接。
- 菜单和收藏持久化：`CotEditor/Sources/Application/ForkMenus.swift`。
- 定制菜单本地化：`CotEditor/Resources/Localizations/Fork.xcstrings`。
- 本地签名：`Configurations/CodeSigning.xcconfig`、`CotEditor/CotEditor-AdHoc.entitlements`。
- Xcode 工程：`CotEditor.xcodeproj/project.xcproj`。

## 实现逻辑

### 格式化与压缩

1. 优先看编辑器语法：JSON、SQL、PostgreSQL。纯文本时再根据 `{` / `[` 或首个非注释 SQL 关键字推断；不能识别就用气泡提示选择语法。
2. 取不可变的全文快照，取消前一次格式化任务，在后台计算。返回主线程时检查任务取消状态和当前正文是否仍与快照一致；过期结果不写回。
3. 使用文本系统的 `replace` 标准编辑入口及独立 undo 分组。一次格式化对应一次撤销，不直接重置 `textStorage` 或整个文档。
4. 解析失败、结果无变化或 token 校验不通过时，不替换正文。错误用原生气泡显示，不依赖系统脚本的退出码弹窗。

JSON 使用词法和结构校验，保留数字、转义序列、键顺序及重复键的原始 token；不经过浮点数或字典重新编码。多行内容压缩为 token 拼接，单行内容按两空格缩进。严格接受一个 JSON 根值；多个对象直接连续粘贴、尾逗号等不会被擅自修复。结构校验限制嵌套深度为 512。

SQL 格式化使用随包携带的 `sql-formatter` 15.9.0 浏览器构建，通过 JavaScriptCore 执行，不需要 Node.js。参数固定为 PostgreSQL、四空格缩进、表达式宽度 70，关键字、函数、类型和标识符大小写均为 `preserve`。多条格式化查询之间留空行。

SQL 切换模式依据 token 之间的换行判断，忽略顶层语句分号后的换行和行注释换行；因此“多条 SQL 各占一行”的压缩结果仍能再次格式化。压缩使用括号栈，顶层分号后换行；字符串内部换行和行注释后的必要换行保留。不能用 `split(';')` 或替换全部空白实现。

转换前后比较 SQL token 的种类和原始文本，包含注释、引号及操作符，并额外验证相邻字符串字面量之间是否跨行，防止改变 PostgreSQL 的字符串连接语义。这个校验是保守的内容保护，不是完整的 PostgreSQL 语义解析器。

### INSERT 双向对应与气泡

- 解析显式字段列表的 `INSERT INTO … (columns) VALUES (…)`，按括号和方括号嵌套层级分隔字段、值与语句；字符串、美元引号、注释内的逗号和分号不参与分割。
- 所有源位置使用 UTF-16 `NSRange`，与 AppKit 一致，避免中文和 emoji 导致偏移错误。
- 列位置映射到所有 VALUES 行的同一列；值位置映射回一个列名。多行值按编号展示对应内容，不生成整张字段映射列表。
- `INSERT SELECT`、省略列名、列数和值数不一致时不猜测映射。该模块不是完整 SQL AST，不能承诺覆盖所有 CTE、方言或 INSERT 扩展写法。
- 双击在应用自身 `mouseDown` 流程内触发后台查询。回到主线程同样校验正文未变化，然后绘制对应范围的高亮、把 `NSPopover` 锚定在文中位置。
- 提示只读取文本并绘制；不替换正文、不跳转光标、不挪动选区、不使用剪贴板或模拟按键。单击、编辑、切换页签和关闭提示时清理高亮及旧查询。
- 气泡按字体测量自然宽高，限制到可见编辑区域内；最小约 64 × 40 点，最大 500 × 260 点，内容可选择和滚动。

### 单窗口、页签和撤销

`DraftWorkspace` 管理一组 `Document`、一个共享的物理窗口控制器和当前文档。各文档的编辑视图控制器按文档对象缓存，切换时复用，避免每次重新创建 `NSTextView` 丢失选区和撤销栈。关闭文档时再释放其缓存及沙盒访问范围。

页签栏是标题栏 accessory 中的自绘视图，并非 AppKit 系统页签栏。这样能固定显示 `＋` 并禁止拖出新窗口，但外观要单独维护：后续按用户反馈补齐等宽占栏、内部左侧关闭按钮和悬停显示。设置、查找等辅助窗口仍保留；本版禁用文件夹窗口，允许一次打开多个单独文件。

`⌘N` / `⌘T` 新建页签，`⌘数字` 选择页签，`⌘W` 关闭页签。关闭最后一个页签会创建空白页签，保持唯一窗口与 `＋` 存在；点击红色窗口关闭按钮则走备份后退出。

### 草稿持久化与恢复

- `Document.autosavesInPlace`、`autosavesDrafts` 关闭，独立保存会话，避免无提示退出时自动覆盖原文件。
- 正文修改和页签操作触发延迟约一秒的会话保存；关闭页签和退出前必须同步保存成功。失败则保留文档、回退关闭记录或取消退出。
- `Draft` 保存正文、稳定 UUID、文件 URL / 书签、原文件修改时间、编码与 BOM、换行符、语法、选区、修改状态和可选草稿名称。
- 会话协议目前为 `version = 1`。读取时校验版本、活动页签、UUID 唯一性和 UTF-16 选区边界。以后更改结构需考虑旧会话兼容，不能直接把不可读会话当作空会话覆盖。
- `DraftStore.save` 先验证新数据；只有旧主文件校验通过时才更新 `session.previous.json`，然后原子替换 `session.json`。目录权限 0700、文件 0600，内容未加密。
- 加载主文件失败时读取上一份有效备份；两份均不可读时保留原文件并阻止后续覆盖，需要先备份再处理。
- 恢复未保存改动时，只有原文件仍可访问且修改时间一致，才把改动关联到原文件。文件丢失、权限不足或外部修改时，将正文恢复为独立草稿，避免覆盖外部内容。
- 切换页签保留内存中的撤销栈；应用重启后恢复正文和选区，不恢复撤销栈。

沙盒中的典型会话位置：

```text
~/Library/Containers/com.forvey.CotEditor/Data/Library/Application Support/com.forvey.CotEditor/Workspace/
  session.json
  session.previous.json
```

### 收藏和未命名编号

收藏模型按标准化文件 URL 去重，重复收藏更新书签。`ForkMenus` 将其 JSON 数据保存到当前应用的 UserDefaults 键 `ForveyFavoriteFiles.v1`，与最近文件独立；打开时解析 security-scoped bookmark。若收藏数据解码失败，禁用修改，避免覆盖损坏数据。

页签右键菜单通过 `representedObject` 携带被点击的 `Document`，不依赖当前活动页签；未保存文档没有文件 URL，所以收藏项禁用并给出说明。

未命名编号由工作区查看当前占用名称后分配最小空闲值。`workspaceDraftName` 随会话保存；恢复旧会话时只整理系统默认的“Untitled / 未命名 + 数字”，保留自定义名称和恢复文件名。

## 已定结论与废弃方案

| 问题或尝试 | 最终结论 |
| --- | --- |
| 用 CotEditor 用户脚本做格式化 | 已迁入原生菜单和核心模块；本机早期 Python / JS 格式化脚本已删除，不是运行依赖 |
| 系统提示 `Script task exited with status 1` | 系统脚本退出码无法提供合适的产品体验；原生工具显示可读错误，失败不替换原文 |
| SQL 格式化统一大小写 | 用户不需要；全部保留大小写 |
| SQL 压缩成整篇一行 | 不接受；顶层每条语句单独一行 |
| 快捷键跳转字段和值 | 用户认为来回跳转无用；采用双击原地提示 |
| 鼠标自动悬浮跟随 + 独立小工具 | 用户不接受额外 App、常驻进程和辅助功能授权；不再恢复此方案 |
| 向 SQL 写入映射注释 | 用户明确否定；提示不得污染正文 |
| 新页签或分栏显示对照列表 | 用户不接受来回切换、页签堆积和无滚动联动；不作为最终方案 |
| 控制台或独立列表提示窗 | 全屏时会切换界面；最终使用文内原生气泡，只展示对应内容 |
| 较大的固定气泡 | 已按内容自适应，并保留长内容的大小上限 |
| 系统多窗口和默认页签行为 | 定制版统一单编辑器窗口，辅助窗口仍保留 |
| 未命名编号一直增长 | 不使用系统全局计数，改为工作区空闲编号与会话持久化 |
| 默认打开文件关联 | 属于每台 Mac 的 LaunchServices 设置，只处理常用类型，不把 `public.data` 等所有文件都接管；没有写入应用启动逻辑 |
| Intel 与安装包 | 当前安装版只有 arm64；Intel / Universal 未构建和验收，用户已取消额外打包，不自行继续 |
| 代码目录和远端备份 | 正式仓库使用 `~/workspace/CotEditor`；本地提交不算远端保存，推送后必须核对远端 SHA |
| 工具安装 | 用户明确要求不自行安装任何东西；使用现有工具，缺失时先说明 |

早期外部脚本提示试验曾出现连续按键后原文丢失且无法撤销，用户的两条 INSERT 后经恢复找回。这是已发生的事故现象；没有保留可审阅的完整根因报告，不能把“快捷键冲突”或某个具体实现细节写成已证实原因。后续预防落在原生只读气泡、标准可撤销编辑、异步结果校验、隔离测试和关闭前备份上，不重新启用旧脚本复现用户文档。

## 构建、安装与排障

### 已确认的环境要求

当前上游 main 已采用 Xcode 27 的 `project.xcproj` 格式，Swift Package tools version 为 6.3；需要完整 Xcode，Command Line Tools 不足以构建应用。本机以 macOS 27、Xcode 27.0（27A266a）、Apple Silicon 完成过构建和验收。

优先对单条命令设置开发者目录，不擅自切换全局 `xcode-select`：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/CustomizationCore

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme CotEditor \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS_SUFFIX=-AdHoc \
  -skipPackagePluginValidation

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -scheme CotEditor -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -skipPackageUpdates -skipPackagePluginValidation
```

最后一条命令仅以 arm64 为目标，不能据此声称产物支持 Intel。SDK 配置包含 x86_64 目标，但应用及全部依赖仍需实际构建、签名和目标机器验收。macOS 26 的最低版本声明也不等于已经在 macOS 26 真机验收。

### 记录过的坑与处理边界

| 现象 | 已确认的处理或结论 |
| --- | --- |
| 只装 Command Line Tools、旧 `swift` 不能读当前工程 | 使用完整 Xcode 27，设置本次命令的 `DEVELOPER_DIR`；不要套用旧 `.pbxproj` 的编辑方式 |
| 新工程格式的本地 Swift Package 引用、测试签名配置出错 | `67f6cb5` 已补显式包引用；应用选择 ad-hoc entitlements，测试 bundle 不附应用的 entitlements |
| 自动化 shell 内 SwiftPM manifest 报 `sandbox_apply: Operation not permitted` | 当时运行环境存在嵌套沙盒限制，增加普通文件权限没有解决；曾改用 Xcode GUI 完成构建。这不代表正常终端的 `xcodebuild` 必然失败 |
| 尝试 `-IDEPackageSupportDisableManifestSandbox YES` | 当前 `xcodebuild` 不识别；`XBS_DISABLE_SANDBOXED_BUILDS=1` 当时也没有解决问题，不作为可靠构建步骤 |
| SwiftLint 插件的 SourceKitten 仍找到旧工具链 | 当时临时为缓存插件注入正确 `DEVELOPER_DIR` 后 GUI 构建成功，随后恢复插件原文和文件权限；不是源码依赖，不应要求保留缓存补丁 |
| GUI 看似成功但构建了 Debug | scheme 的 ProfileAction 指向 Release；当时使用 Product → Build For → Profiling 验证 Release，不能仅凭按过 Build 就声称是 Release |
| 无法直接替换 `/Applications` 中应用，报 `Operation not permitted` | 当时 shell 写入许可仍受 macOS App 管理限制；通过 Finder 替换，之后比较可执行文件哈希并校验签名；不为此放宽系统安全设置 |
| SwiftPM 首次获取依赖耗时、网络或锁定版本解析失败 | 保留锁定版本，先检查包解析日志及网络；临时代理、镜像和下载脚本不成为项目永久依赖，使用后还原 Git 配置 |
| 构建自动抽取字符串导致无关 `.xcstrings` 改动 | 提交前检查差异，只保留与本次功能相关的本地化更新 |
| Git 能公开拉取但不能 push | 读取公开仓库不代表已认证；系统已有 `osxkeychain` helper，但还需要钥匙串中有可用 GitHub 凭据。不能用 GitHub 账户密码替代 HTTPS 令牌，也不把 token 写到 remote URL 或仓库 |
| HTTPS 推送提示 `Send failure: Broken pipe` | 2026-10-17 实测直连 GitHub 超时，使用本机系统已配置的 HTTP 代理则成功访问公开 Git 服务。Git 不一定跟随 macOS 系统代理；先对比直连与现有代理，再用 `git -c http.proxy=http://127.0.0.1:端口 …` 对单次命令指定代理，不固化全局代理，也不关闭 TLS 校验。此错误本身不证明令牌无效；失败的请求可能尚未把凭据保存到钥匙串 |
| `git status` 显示干净或本地 ahead | 只说明本地工作树和提交状态，不能证明远端已有代码；以 `git ls-remote` 校验 |

沙盒、插件或安装问题应先看具体错误，不能反复加无效参数、修改全局工具链或安装新工具。当前环境与早期沙盒环境可能不同，历史失败只作为排障线索。

### 本机清理与迁移注意事项

2026-10-15 按用户要求清理了临时安装、代理、下载和测试脚本、通用 SQL/JSON 样例、工作区 `.build`、编译/索引产物及日志，合计约 2.5 GB。保留源码、Git 历史、正式测试、已安装应用、构建依赖缓存、恢复 SQL、会话及安装备份，清理后核验过应用签名、草稿和备份哈希。

旧 Xcode `SourcePackages` 依赖缓存可能仍在；克隆到 workspace 后 DerivedData 名称会随路径改变，不假定新工程能自动复用旧缓存。需要恢复构建时重新解析现有锁定依赖，不恢复临时代理或缓存补丁。临时日志已清理，所以不能声称今天还能打开全部历史日志。

安装更新前备份当前应用和真实会话；只打包 `.app` 与必要许可证，不把用户数据装进去。更新后核验路径、版本、架构、签名和基本编辑行为。个人机器上的默认文件关联需单独设置，不是仓库或安装包可携带的全局配置。

## 验证记录与后续验收

2026-10-15 已记录通过：

- `CustomizationCore` 8 项测试：JSON 原始值、PostgreSQL 往返与大小写、多语句压缩、字符串/注释保护、UTF-16 字段映射、草稿损坏恢复与文件权限、收藏持久化去重、写入失败保护等。
- 应用 `NativeEditorToolsTests` 3 项测试：格式化一次撤销/重做、期间新编辑使旧结果作废、切换页签后复用编辑视图并保留撤销和选区。
- Release 构建及本机人工验收：SQL/JSON 格式化与压缩、SQL 分行、撤销、全屏字段/值气泡、紧凑尺寸、固定 `＋`、页签关闭外观、收藏重启持久化、红色关闭后草稿恢复。
- 页签右键收藏及编号更新：再次构建 Release、运行 8 项核心测试；实测非当前页签收藏/取消、草稿收藏禁用、关闭“未命名 3”后复用 3、重启名称保持；原有草稿 ID 和正文哈希一致。

边界：未跑完整上游全部测试矩阵；没有 Intel / Universal 产物验收；没有在真机上模拟退出时磁盘写满；磁盘写入失败通过核心模块测试覆盖；没有性能或大文件持续运行指标。CI 使用 `xcode-27` runner 标签，fork 必须实际有相应 runner，不能假定 push 后 CI 自动可运行。

后续按改动范围选用以下验收，全部使用临时、通用示例：

1. 格式化：大整数、Unicode 转义、重复 JSON 键、多条 SQL、行/块注释、美元字符串、自定义运算符和大小写；连续触发、格式化中编辑及一次撤销。
2. 气泡：中文/emoji、函数/数组、多行 VALUES、多个 INSERT；双击双向映射，单击/编辑/换页签后清除；正文和选区保持，长短内容尺寸合理，全屏不跳页面。
3. 页签与会话：单文件 `＋`、多文件单窗口、关闭最后页签、关闭窗口退出、重启恢复、切换后撤销、`⇧⌘T`、未命名编号复用。
4. 收藏：右键非当前页签、禁用未保存草稿、去重、取消、重启及文件访问失效时错误处理。
5. 数据保护：恢复遇外部修改、主备份损坏、无写权限；必须保留原文和有效备份，不因测试损坏用户数据。

本次补录仅改文档，不需要重建应用或重跑功能测试；应检查 Markdown 本地链接、源码入口、提交引用和 Git 差异。

## 功能提交索引

| 提交 | 内容 |
| --- | --- |
| `8d81d43` | 无损 JSON/PostgreSQL、SQL 词法和 INSERT 映射、草稿/收藏模型、核心测试及 CI 包矩阵 |
| `973505a` | 原生气泡、固定页签、菜单/收藏、草稿恢复、单窗口、ad-hoc 配置和应用测试 |
| `67f6cb5` | Xcode 27 显式包引用、本地测试签名和会话恢复相关修正 |
| `749caaa` | 气泡按内容缩放、页签关闭按钮回到内部左侧及布局修正 |
| `af1640e` | 页签右键收藏、未命名空闲编号复用与名称持久化 |

后续每次行为修改更新本文件的相应章节，并在提交说明写明触发条件、结果、验证范围和未覆盖事项，不只追加聊天过程。远端保存完成后核对：

```sh
git status --short --branch
git rev-parse HEAD
git ls-remote origin refs/heads/main
```

只有远端 main 与预期提交一致、workspace 新克隆也包含全部提交后，才移除旧的代码副本。恢复 SQL、应用备份和用户会话不属于旧代码副本。
