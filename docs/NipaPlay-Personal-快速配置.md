# NipaPlay Personal 快速配置

## WebDAV 媒体库

1. 在 WebDAV 设置中添加本机可访问的连接；Windows 可使用 CloudDrive2 提供的 WebDAV 地址，Android 填写该设备能访问的地址。
2. 打开媒体库管理，添加云媒体库，选择连接并浏览到要管理的目录。只会索引用户选择的根目录，不会改动云盘原始文件。
3. 在「设置 → 实验室」分别控制「本地媒体库刮削模式」和「WebDAV 媒体库刮削模式」开关。每项互不影响：关闭使用 NipaPlay 原版流程，开启使用 TMDB-ID 模式，从目录名识别 TMDB ID；TMDB-ID 扫描只列目录和文件元数据，不读取视频正文。本地扫描后可从「本地 TMDB 媒体库」打开海报墙，即使作品没有 Bangumi 关联也能查看已索引的 TMDB 元数据。
4. 在同一页面切换「动画详情页模式」：关闭为原版布局，开启为分类模式，作品详情页增加正片、特典、CDs 和 Scans 分类。文件归属/分类可在作品文件列表中人工修改并锁定；重扫会保留锁定关系。
5. 若要抓取 TMDB 电影资料，在「设置 → 实验室 → TMDB 元数据访问令牌」粘贴 TMDB 账户 API 设置中的 Read Access Token。令牌保存于设备安全存储，不会同步；TV 条目优先使用弹弹play映射，未匹配时回退到 TMDB，Movie 直接使用 TMDB。

## 跨设备同步

1. 在同步设置中配置同一个可写 WebDAV 同步目录，并在设备上启用自动同步或手动同步。
2. 先在负责扫描的设备添加并扫描媒体库。其他设备同步后会导入索引和作品关系，不会自动重新扫描媒体目录。
3. 在其他设备的媒体库管理中为导入的媒体库选择本机 WebDAV 连接和对应目录。逻辑媒体来源 ID 与相对路径用于定位资源；连接地址和凭据保存在各设备本机。
4. 文件还不能访问时仍可浏览已同步的目录和作品资料；开始播放或阅读时按提示配置本机来源。

播放进度与作品关联通过现有增量同步传输。修改媒体库后可手动同步，避免等待低频后台同步。

## CDs、CUE 与 Scans

- 音频文件可从作品的 CDs 分类打开，使用 NipaPlay 原播放器的暂停、跳转和队列控制。
- `.cue` 文件显示在 CDs 中；打开后选择曲目，应用读取所需的 CUE 文本并按 `INDEX 01` 跳到曲目起点。CUE 引用的音频必须已在同一索引库中。
- Scans 支持 JPG/JPEG、PNG 和 WebP。阅读器按需读取当前图和相邻页缓存，工具栏切换单页/双页；Windows 支持左右方向键。

## 备份与恢复

在「设置 → 备份与恢复」创建 `.npb` 完整备份，选择包含「媒体库」和「观看历史」；在另一设备选择性恢复相同类别。恢复会合并数据，不会把设备专属连接凭据写入共享媒体库快照。恢复后仍需在本机配置 WebDAV 连接和目录映射。

## 构建发行包

项目要求 Flutter、Android SDK/NDK、Windows Visual Studio C++ 工具链及 Rust 工具链。执行：

```powershell
flutter test --no-pub
flutter analyze
.
scripts\package_personal_release.ps1 -Flutter 'D:\path\to\flutter.bat' -Build
```

Windows 便携 ZIP 和 Android APK 会写入 `release/`。Android 使用本机 `android/key.properties` 与 `.personal-signing/NipaPlayPersonal.jks` 固定签名；二者均被 Git 忽略，密钥应安全离线备份，不要提交到仓库。未配置签名时 Gradle 会退回 debug 签名，不能用于覆盖已安装的个人正式版。

Windows 设置和数据库保存在 `%APPDATA%\com.aimessoft\NipaPlay Personal`，与官方版分开。Android 包名为 `com.clainst.nipaplay.personal`，可与官方版并装。

## 跟进官方稳定版

仓库应保留 `upstream` 指向 AimesSoft 官方仓库、`origin` 指向个人 fork，且已启用 `git rerere`。工作区干净并位于 `personal/stable` 时运行：

```powershell
./scripts/update-upstream.ps1 -Version v1.11.12
```

脚本只创建 `upgrade/<版本>` 分支并合并指定的正式版本标签，不会推送，也不会自动覆盖稳定分支。解决冲突后完成测试、Windows/Android 构建和人工启动检查，再将升级分支合并回 `personal/stable`。

## 尚需真实环境验收

模拟 WebDAV 测试可以验证扫描过程不读取视频内容；真实 CloudDrive2/WebDAV 网络行为、Android 真机播放/翻页、两台真实设备同步，以及不同安卓厂商的音频解码仍需在用户自己的设备和服务器上确认。本环境不能代替这些实测。

## 本机验收记录（2026-11-02）

| 项目 | 结果 | 验证依据 |
| --- | --- | --- |
| 自动化测试 | 通过 | `flutter test --no-pub --reporter json`：1,516 项完成，0 项失败、0 项跳过；包含 WebDAV 请求拦截、媒体索引同步往返和人工关联冲突用例。 |
| 本次改动静态分析 | 有既有提示，无错误 | 设置页、媒体库页面和设置页测试共报告 90 条 issue（warning/info），没有 error。 |
| 应用与测试目录分析 | 有既有提示，无错误 | `flutter analyze --no-pub lib test` 报告 2,036 条 issue（198 warning、1,838 info），没有 error。 |
| 全项目静态分析 | 未通过 | 完整分析报告为 5,479 条 issue，其中包含 build 生成物、vendored 第三方代码及仓库既有 lint；不将其记为通过。 |
| Windows 发布构建 | 通过 | `scripts/package_personal_release.ps1 -Build` 完整执行成功；程序隐藏启动后保持运行 8 秒。 |
| Android 发布构建 | 通过 | 同一打包脚本成功生成 arm64 APK；`apksigner` 验证 v2 签名，证书 SHA-256 为 `a083e7205dc014dbfd1a0b52f67a3f91a934ffe94b0f3d27ee268166570b4a9e`。 |
| 真实设备与服务器 | 未验证 | 当前环境没有连接的 Android 设备，也未配置用户的 CloudDrive2/WebDAV 媒体目录；真实播放、阅读、跨设备网络同步需在目标设备上验收。 |

最新产物位于 `release/NipaPlay-Personal-Windows-Portable.zip` 和 `release/NipaPlay-Personal-Android.apk`。重新打包脚本会清理可能由测试残留的 Android 测试插件注册表，再为 release 重新生成，避免测试专用插件进入正式变体。
