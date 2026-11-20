# 用 GitHub 自身环境改造 RustDesk 安卓端（零本地环境方案）

目标：不装 Flutter / Rust / NDK / Android SDK，全部在 GitHub 上完成「改代码 → 编译 → 出 APK → 装手机」。

## 当前实际状态（已落地）

| 项 | 值 |
|---|---|
| Fork 仓库 | https://github.com/lvc00/rustdesk |
| 工作分支 | `ui-ux`（只作 workflow 载体；**构建时检出 upstream tag `1.5.3`**，不用 ui-ux 的源码树打包） |
| 基线版本 | **1.5.3**（tag 不带 `v` 前缀，commit `95cca3f`） |
| Flutter | **3.24.5**（上游 CI 对 Android 用的就是这个版本） |
| 官方 APK 产物名 | `rustdesk-1.5.3-aarch64-signed.apk` |
| 生效的 workflow | `.github/workflows/android-build2.yml`（检出 upstream 1.5.3 + 叠加 P1 补丁，自包含） |
| 本地产物名 | `app-arm64-v8a-release.apk`（`--split-per-abi`） |
| 日志文本通道 | 每次跑完强制推到 `ci-log` 分支的 `diag.txt`；本机 `raw.githubusercontent.com` 不通时，改用 `api.github.com/repos/lvc00/rustdesk/contents/diag.txt?ref=ci-log` 读 |
| 免登录下载通道 | `android-build2.yml` 内置 `Publish APK to Release`，构建成功即覆盖 Release `ux-latest` |
| 直链 | `https://github.com/lvc00/rustdesk/releases/download/ux-latest/rustdesk-1.5.3-ux-arm64-v8a.apk`（29.3 MB，无需登录，不过期） |
| 当前最新包 | **v5**（29,286,855 字节 / sha256 `b675ed38…34abd`）—— 收紧后的滑窗判据 + 自带底部工具栏改造 |
| 本机落地 | `C:\Users\a1324\Downloads\rustdesk-1.5.3-ux-arm64-v8a.apk` |
| 已废弃 | `.github/workflows/publish-apk.yml` 现为一次性的 `Setup 153` 造分支脚本（push 含 workflow 的提交会被 `GITHUB_TOKEN` 拒绝），保留仅为留档，**不要再用** |

> **2026-11-20 P3 记录：双指误拖窗口 / 输入法唤不起 / 快捷键自定义**
>
> > ⚠️ 本节的「自绘键盘页 / 快捷键页 / 悬浮球 / 状态栏」在 **P5（v5）已整体撤除**，
> > 改为改造 RustDesk 自带底部工具栏，详见文末 P5 记录。下面保留的是当时的排查过程，仅作留档。
>
> 用户实测三点问题，逐一定位：
>
> **1. 「偶尔双指拖动窗口」= 我自己复刻了原版逻辑**
> `_moveTwoFingers()` 里原本照搬 upstream `onTwoFingerScaleUpdate()`：
> `canvasModel.updateScale(ratio, focal)` 之后再 `panX/panY`；并且捏合判定阈值只有
> `1.5%`（最小 1px），双指滚动时两指间距的自然抖动就会被判成「捏合」，
> `scale` 因此漂到 1.01 以上，此后**每一次双指操作都走 `scale > 1.01` 的 pan 分支** → 画面跟着手走。
> 修法（`_TwoMode` 状态机，一次手势只锁一种模式）：
> - 阈值提到 **6%**，且两指落下后先观察 **70ms**，够不够明显捏合再决定；
> - **捏合时只缩放，不平移**；
> - 平移只在 `scale > 1.12`（真正放大后）才允许，且 100% 由 UU 层接管；
> - 未缩放的双指 100% 是滚轮。
>
> **2. 「输入法输入框点了没用」= 原生窗口 flag 被关着**
> RustDesk 在 `remote_page.initState` 调 `gFFI.invokeMethod("enable_soft_keyboard", false)`，
> 原生侧（`MainActivity.kt`）会给窗口加 `FLAG_ALT_FOCUSABLE_IM` —— **这个 flag 会禁止任何
> TextField 弹出软键盘**，不只是 RustDesk 自己的隐藏输入框。所以点输入框毫无反应。
> 修法：打开键盘页 / 点输入框时先 `widget.ffi.invokeMethod('enable_soft_keyboard', true)`，
> 再 `_imeFocus.requestFocus()` + `TextInput.show`；关闭面板时还原为 `false`。
> （用 `widget.ffi` 而不是 `gFFI`，避免为一个全局变量 import 整个 `common.dart`。）
>
> **3. 快捷键自定义 + 全键盘**
> - 快捷键页：长按任意快捷键进入编辑器（改名 / 勾 Ctrl·Alt·Shift·Win / 从 ~80 个主键里选），
>   支持新增、删除、恢复默认；持久化到 `bind.mainSetLocalOption('uu_shortcuts_v1')`。
> - 键盘页：QWERTY + 数字 + 三行符号（`` ` ~ ! @ # $ % ^ & * ( ) _ + { } | : " < > ? ``）
>   + Tab/Esc/Back/Enter/Space/Del/Ins/Home/End/PgUp/PgDn/Caps/方向键/F1–F12。
>   字符走 `bind.sessionInputString`（所见即所得，不受远端布局影响；按住 Ctrl/Alt/Win 时自动
>   转成真实组合键），控制键走 `inputModel.inputKey`。
>
> **构建侧踩的两个坑（都已修进 workflow）**
> - `flutter build apk` 成功打印 `✓ Built ...` 后仍会以 **rc=2** 退出（`Caught exception:
>   Already watching path` 触发 Flutter 的 `ToolExit`），`set -o pipefail` 直接把步骤判失败。
>   改为**按产物判定**：`set +e` 接住 rc，只要 `$OUT` 存在就继续，否则 `exit 1` 并打 `::error::`。
> - 千万不要在构建前 `rm build/app/outputs/flutter-apk/*.apk` —— Gradle 认为
>   `assembleRelease` 已是最新，**跳过打包**，flutter 找不到 APK 直接失败。改用 `touch` 标记 +
>   `-ot` 判断新鲜度。
> - `ci-log` 的 `diag.txt` 曾长期不更新（`git commit` 无改动时返回非零导致没产生新 commit），
>   现在 diag 里写了 `run id / attempt / 时间戳`，内容必然变化，通道恢复。
>
> **编译失败的真因（记一笔，避免重犯）**：`isAndroid` 定义在 `common.dart`，**不在 `consts.dart`**。
> 写 `import 'consts.dart'` 然后直接用 `isAndroid` 会直接编译失败（构建 70 秒即退出，走不到 Gradle）。
> 轻量正确写法：`import 'package:flutter_hbb/native/common.dart' if (dart.library.html)
> 'package:flutter_hbb/web/common.dart';` 然后用 `isAndroid_`。
>
> 验证：run `44685834600` 全 20 步绿；`libapp.so` 中 `uu_shortcuts_v1`、`自定义快捷键`、
> `系统输入法`、`完整键盘`、`收起键盘`、`恢复默认快捷键` 均在（中文按 UTF-16LE 计），JNI 仍 16 符号；
> arm64 设备卸载重装后启动 pid 21727，无崩溃。APK 29,312,764 字节 sha256 `d89b61d2…136347`。

> **2026-11-20 P2 记录：UU 风格交互增强（双指缩放 + 工具箱浮层）**
>
> 用户反馈 P1 手势生效但与 UU 远程仍有差距（点名双指缩放、键盘方式、快捷键方式、状态栏位置）。
> 本次只改 `raw_trackpad.dart` 一个文件（workflow 补丁清单已含它，挂载点不变），全部 UI 以
> Stack 叠加层实现，不动 upstream 页面结构：
>
> - **双指捏合 = 缩放屏幕**：复用 1.5.3 原版 `canvasModel.updateScale(ratio, focal)` +
>   `panX/panY`（与原版 `onTwoFingerScaleUpdate` 的 mobile 分支一致）；缩放后双指拖动 = 平移画面；
>   未缩放时双指仍是滚轮（保留 P1 已验证手感）。缩放/滚动按两指间距变化 >1.5% 或 >1px 判定，
>   一旦进入缩放模式本次手势锁定，防抖动误触。
> - **单指长按 500ms = 右键**（Timer 实现，移动超 slop 自动取消）。
> - **三指轻点 = 呼出/收起工具箱**。
> - **UU 工具箱浮层**：可拖动悬浮球（吸附边界）+ 模态面板，三个页签：
>   - 快捷键：修饰键锁定（Ctrl/Alt/Shift/Win，sticky，影响功能键）+ 常用组合键
>     （Ctrl+C/V/X/Z/A/S/F/N、Alt+Tab、Alt+F4、Win+D/E/L、任务管理器、Ctrl+Alt+Del）+
>     功能键（Esc/Tab/Enter/退格/Del/Home/End/PgUp/PgDn/截图/方向键/F1-F12）；
>   - 键盘：TextField 唤起系统输入法，中文经 `sessionInputString` 整串发送（composing 保护）；
>   - 视图：放大/缩小/复位 100%、状态栏位置（顶部/底部/隐藏）、手势层 UU/原生切换。
> - **状态栏**：30px 半透明条（绿点 + 缩放百分比实时显示，`AnimatedBuilder` 监听 canvasModel），
>   位置可切换；空白区用 opaque GestureDetector 吞点击，防止穿透误触远端。
>
> 键名坑：`VK_LWIN` 无效，Win 键用 `Meta`（1.5.3 `input_model.dart` 同款）；`clamp()` 返回
> `num` 需 `.toDouble()`；AOT 快照中含中文的字符串按 UTF-16LE 存储，验证进包要按 UTF-16 搜。
>
> **验证**：run `44665715380` 全 20 步绿；libapp.so 中 `CtrlAltDel`=2、`UU 工具箱`(UTF-16)=1、
> `三指轻点`=2、JNI 仍 16 符号；arm64 设备启动正常（pid 16243，无崩溃）。浮层挂在远程会话
> 画面内，首页不显示属预期，实际效果需远控时确认。
>
> **2026-11-20 修复记录：启动闪退已解决**>
> **现象**：上一版 APK 装到设备后启动即崩，`logcat` 报
> `java.lang.UnsatisfiedLinkError: No implementation found for void ffi.FFI.setDocumentLogsEnabled(boolean)`。
>
> **根因**：`ui-ux` 分支实际基于 master，其 `ffi.kt` 声明了 **18** 个 `external fun`（多出
> `setDocumentLogsEnabled`、`setInputServiceOpen`）；而官方 1.5.3 的 `librustdesk.so` 只导出
> **16** 个 `Java_ffi_FFI_*`。Kotlin 声明与 native 实现错位，`MainApplication` 一启动就调那个
> 没有实现的符号，必崩。
>
> **修法**：不再用 ui-ux 的源码树打包。`android-build2.yml` 的 `actions/checkout` 改为直接检出
> **upstream `rustdesk/rustdesk` tag `1.5.3`**，再用 `api.github.com` 拉取 ui-ux 上仅有的两个
> P1 文件（`raw_trackpad.dart`、`remote_input.dart`）覆盖，FRB bridge 也从 1.5.3 自己的
> `src/flutter_ffi.rs` 重新生成。于是 Kotlin/JNI 声明、Rust 签名、`.so` 三者全部对齐 1.5.3。
>
> **验证**：新包 `classes*.dex` 中已无 `setDocumentLogsEnabled` / `setInputServiceOpen` 字符串；
> 内置 `librustdesk.so` 恰好导出 16 个 JNI 符号；在 arm64 设备（Android 9 / Phh-Treble GSI）
> 安装启动后进程常驻、无 `UnsatisfiedLinkError`，`_globalFFI init` 正常完成并渲染首页。
>
> **2026-11-20 补记：手势仍无变化的真根因**
>
> 上述包虽然不崩了，但手势与原版一致。排查发现 `Fetch native libs from official APK` 步骤用
> `unzip "lib/<abi>/*"` 把官方 APK 的 **`libapp.so`（Dart AOT 快照）也一并拷进了 `jniLibs/`**，
> Gradle 打包时它直接盖掉了我们自己编译的 Dart 代码 —— 于是 `RawTrackpadLayer` 从未进入 APK，
> UI 始终是官方原版。
>
> 证据：旧包 `libapp.so` 中 `RawTrackpadLayer` 出现 **0** 次、`RawTouchGestureDetectorRegion` 3 次；
> 修复后变成 **3** 次 / 3 次，`libapp.so` 的 md5 也从 `1523bece…` 变为 `b9933985…`。
>
> 修法：只从官方 APK 取 `librustdesk.so` + `libc++_shared.so`，并显式删除 `jniLibs` 下的
> `libapp.so` / `libflutter.so`；同时在 `Build APK` 紧前重写一次补丁，构建后强制断言
> `RawTrackpadLayer` 已在 `libapp.so` 内，否则整条流水线失败（不再静默交付原版）。

> **2026-11-20 P4 记录：最新版双指缩放失效（v3 回归，已修）**
>
> 现象：v3 包双指滚动正常，但**双指捏合完全不缩放**；退回 v2 包缩放可用。
>
> 根因在 v3 新写的 `_TwoMode` 判定条件：
> `spanRate = |Δspan| / span`（**单帧**间距变化率）> `6%` 才算捏合，同时 **70ms** 观察窗一到就锁成 `scroll`/`pan`。
> 正常捏合每帧间距只变 2%~4%（6% 相当于 375%/秒），70ms 内几乎不可能达标 →
> 手势被提前锁死成滚动，而锁定后不再重新判定，**整段手势再没有机会进入 pinch**。v2 用的是 `1.5% / 1px`
> 逐帧阈值，所以能触发，但代价是滚动时容易误判成捏合（也就是上一轮「双指拖动窗口」的来源）。
>
> 修法（`_moveTwoFingers`）：
> 1. 判定量改成**累计间距变化 `_spanTravel` vs 累计焦点位移 `_focalTravel`** 的对比：
>    `_spanTravel > 10px && _spanTravel > _focalTravel * 0.65` → pinch。捏合时两指张开远快于整体位移，滚动时相反，与速度无关。
> 2. 观察窗放宽到 **110ms**，且锁定后仍允许被真正的捏合**接管**（`_spanTravel > 26px && > _focalTravel * 1.2`），
>    避免「前 100ms 没识别出来，缩放就整段死掉」。
> 3. 进入 pinch 的瞬间把此前累计的间距变化**一次性补上**（`span / _spanStart`，clamp 到 0.8~1.25），
>    否则慢速捏合会出现「手指动了但画面不动」。
> 4. pinch 一旦成立永不回退，滚动/平移仍保持单一模式。
>
> 离线用同一套阈值做了状态机仿真（60Hz）：慢速捏合 64ms 判定为 pinch；锚定一指捏合 64ms；纯滚动 112ms 锁 scroll 且 1.4s 内不误判；
> 已放大时平移锁 pan；先滚动后张开能在 608ms 被捏合接管。
>
> 验证：run `44690240641` 全 20 步绿；APK 29,313,094 字节 sha256 `dbdc2e5a…f4f0`；
> `libapp.so` md5 由 v3 的 `aa7726cf…` 变为 `4ef8e0a3…`（确认新 Dart 代码进包），`RawTrackpadLayer`=3；
> `librustdesk.so` 仍是 16 个 `Java_ffi_FFI_*`（JNI 对齐）；arm64 真机（Android 9）卸载重装后 pid 25775 启动无崩溃。

> **2026-11-20 P5 记录：缩放过敏收紧 + 撤掉自建浮层、改造自带工具栏（v5）**
>
> 1. **双指缩放太敏感**（用户反馈：双指滚动时很容易被缩放）。v4 的判据 `_spanTravel > _focalTravel * 0.65`
>    用的是**整段手势的累计量**：滚动时两指间距会有 15%~25% 的自然漂移，累计几秒后就超过 0.65 的比值门槛，
>    于是纯滚动被误判成捏合。
>    修法：改判据为**指数衰减滑窗**（只看最近 ~3 帧的趋势，不看重历史累计）——
>    `_winSpan = _winSpan*0.7 + dSpan`、`_winFocal = _winFocal*0.7 + focalMove`，
>    要求 `winSpan > 3.5 && winSpan > winFocal * 1.2 && spanTravel >= max(spanStart*0.12, 30px) && spanStart > 60`。
>    效果：纯滚动时 `winSpan` 被焦点位移压制，永远不达标；真捏合时 `winFocal` 很小，一帧就能翻上去。
>    离线 60Hz 仿真结论：6px/帧滚动 + 20/40/60/80px 间距漂移**全部不误判**；
>    慢速捏合 192ms 识别、锚定一指捏合 240ms、先滚后捏 832ms 接管成功。
>    进入 pinch 时仍补 `span/_spanStart`（clamp 0.91~1.10），避免慢速捏合画面滞后。
> 2. **撤掉自建 UU 浮层**。删除 `raw_trackpad.dart` 里的悬浮球、三页工具箱、顶部状态栏、自绘键盘页、
>    快捷键页，以及 `UUShortcut` / `_combo` / `_charToVk` / `_kShortcutStore` 等全部键盘相关代码
>    （文件从 700+ 行降到 404 行，只剩纯手势）。跨文件只剩一个信号：
>    `final ValueNotifier<int> uuToolbarToggleTick`，三指轻点时自增。
> 3. **直接改造 RustDesk 自带底部工具栏**（`remote_page.dart` 的 `getBottomAppBar()`），仿 UU 远程：
>    圆角深色浮条（`0xF21F2124` / radius 20 / 高 58 + `SafeArea`）+ 图标上、文字下（10px），
>    六个按钮等距排列：断开 / 键盘 / 手势 / 显示 / 聊天 / 更多。
>    `initState` 里 `uuToolbarToggleTick.addListener(_onUuToolbarTick)`，`dispose` 里 `removeListener`；
>    `_onUuToolbarTick()` 顺手关掉手势帮助页再切换 `_showBar`，这样三指轻点只切换工具条、不叠两层浮层。
> 4. **原版手势图改成与补丁一致**。`gesture_help.dart` 新增 `_gestureTiles(width)`，条目改为：
>    单指轻点=左键、单指长按=右键、单指滑动=移动光标、双击后拖动=拖拽、
>    双指上下滑=滚轮、双指捏合=缩放、双指拖动=平移（放大后）、三指轻点=显示/隐藏工具栏，
>    替掉原来「三指上下滑=滚轮 / 双指移动=画布移动」这套与本补丁不符的说明。
> 5. **CI 从 2 个补丁文件扩到 4 个**：`raw_trackpad.dart` / `remote_input.dart` / `remote_page.dart` /
>    `gesture_help.dart`，`Apply P1 UX patch` 与 `Build APK` 紧前 re-apply 两处都改成 `for f in \` 续行写法
>    （多行 `FILES="..."` 字符串会把后续行顶格、破坏 YAML，`run 44698749378` 就是这么挂的，jobs=0 无 step 日志）。
>
> **v5 验证**：commit `9820373`（`.github/workflows/android-build2.yml` 16322 字节，与本地 `diff` 逐字节 IDENTICAL）；
> run `44701344858` **20 步全绿**；APK **29,286,855** 字节 sha256 `b675ed38…34abd`；
> `libapp.so` md5 `4a45aed5…`（v4 `4ef8e0a3…` → v5 又变了，确认新 Dart 代码进包），
> APK 内标记 `RawTrackpadLayer`=3、`_uuBarButton`=1、`_gestureTiles`=1、`uuToolbarToggleTick`=2，
> 旧浮层标记 `UUShortcut`=0、`_kShortcutStore`=0（确认已彻底移除）；
> `librustdesk.so` 仍是 **16** 个 `Java_ffi_FFI_*`；arm64 真机 `6f96a11` 卸载重装后 pid 28361 启动无崩溃、首页正常渲染。

### 安装须知（重要）

每次 CI 构建都会新生成一份 debug keystore，**签名不固定**。如果你手机上还装着上一版，
直接覆盖安装会报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，必须先卸载再装：

```bash
adb uninstall com.carriez.flutter_hbb
adb install rustdesk-1.5.3-ux-arm64-v8a.apk
```

要以后能直接覆盖升级，得在仓库里固定一份 keystore（`ANDROID_KEYSTORE_BASE64` 等 secrets）。


本目录是可以直接覆盖到 fork 仓库根目录的文件包：

```
.github/workflows/build-apk-dart-only.yml   路线 A：跳过 Rust，10 分钟出包
.github/workflows/build-apk-full.yml        路线 B：完整编译 Rust core，一次 40~70 分钟
.devcontainer/                              Codespaces 环境（Flutter + Rust + NDK 全预装）
scripts/fetch-so.sh                         从官方 APK 里抽 librustdesk.so
scripts/init-fork.sh                        一次性初始化 fork 的脚本
docs/patch-plan.md                          交互层要改哪些文件（UU 式手势）
```

---

## 0. 先选路线

| 路线 | 用什么 | 单次出包 | 适用 |
|---|---|---|---|
| **A. github.dev + Actions（纯 Dart）** | 浏览器改代码，Actions 打 APK | **8~12 分钟** | 只改 Flutter 交互层（手势/UI/悬浮球/键盘）——也就是这次 90% 的活 |
| **B. Actions 全量编译** | 同上，但自己编 Rust core | 40~70 分钟（有缓存 15~25） | 要改 `src/client.rs` 的事件处理、加相对移动语义 |
| **C. Codespaces** | 云上 VS Code，能跑 `flutter analyze`、`cargo check`、断点 | — | 需要补全、跳转、静态检查时 |

**核心技巧（路线 A）**：RustDesk 的安卓 APK 里，核心逻辑在 `lib/<abi>/librustdesk.so`，Flutter 侧通过 `flutter/lib/generated_bridge.dart` 调它。只要你不动 Rust 侧的函数签名，就**可以直接把官方 Release APK 里的 `.so` 拿来复用**，跳过一次 40 分钟的 Rust 交叉编译。UI/手势改动全在 Dart 层，这条路完全够用。

> 前提：`.so` 的版本必须和你 fork 的 Dart 分支是同一版本（bridge 签名要对得上）。做法是 fork 时打一个 tag 记住基线版本。

---

## 1. 一次性准备（10 分钟）

### 1.1 Fork

网页上点 Fork 即可，或者本地跑 `scripts/init-fork.sh`。两个关键动作：

```bash
# 1) 克隆自己的 fork，并把上游加为 remote
git clone https://github.com/<你的账号>/rustdesk.git
cd rustdesk
git remote add upstream https://github.com/rustdesk/rustdesk.git
git fetch upstream --tags

# 2) 从某个正式版本切出工作分支（记住这个版本号，路线 A 要用）
git checkout -b ui-ux v1.4.2     # 版本号换成 upstream 上实际存在的 tag
```

### 1.2 关掉上游的一堆 workflow（必做）

fork 会继承上游全部 CI，你每次 push 会同时触发十几个桌面端构建，把额度烧光。

`Settings → Actions → General → Disable actions` 先全关，再逐个启用。或者更干脆：

```bash
# 只留自己的两个，其余全删
git rm -r .github/workflows
# 再把本目录的 workflows 拷回来
cp -r <本目录>/.github/workflows .github/
git commit -m "ci: replace upstream workflows with android-only build" && git push
```

### 1.3 仓库设成 Public

- **公开仓库的 Actions 免费且不限时长**，私有仓库 2000 分钟/月，全量构建跑七八次就没了。
- RustDesk 是 **AGPL-3.0**，你分发改过的 APK 本来就必须开源，Public 正好合规。

---

## 2. 路线 A 实操：10 分钟一个包的迭代闭环

### 2.1 在浏览器里改代码

在你的 fork 页面按 **`.`**（英文句号），直接在 `github.dev` 里打开 VS Code 网页版。改 `flutter/lib/...` 下的文件，提交到 `ui-ux` 分支。

`github.dev` 不能编译，但改代码、看 diff、提交完全够。

### 2.2 Actions 自动出包

push 到 `ui-ux` 且动了 `flutter/lib/**` 时，`build-apk-dart-only.yml` 自动跑：

1. checkout（`submodules: recursive`）+ 装 JDK 17 + Flutter 3.24.5 + Rust 1.75（带 `rustfmt`）
2. `cargo install cargo-expand@1.0.95` + `flutter_rust_bridge_codegen@1.80.1`（有缓存时跳过）
3. `flutter pub get`
4. **生成 FRB 绑定**：`flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h`
5. 从官方 Release APK 解出 `lib/<abi>/*.so`（**整个目录**，含 `libc++_shared.so`）放进 `flutter/android/app/src/main/jniLibs/<abi>/`
6. `sed` 把 `signingConfigs.release` 换成 `.debug`（跟上游无密钥时的做法一致）
7. `flutter build apk --release --target-platform android-arm64 --split-per-abi`
8. 上传 artifact；并把构建日志推到 `ci-log` 分支

### 2.3 装到手机

**首选：直接用 Release 直链**（不用登录、不会因 14 天保留期失效）：

```
https://github.com/lvc00/rustdesk/releases/download/ux-latest/rustdesk-1.5.3-ux-arm64-v8a.apk
```

或者：Actions 运行页 → Artifacts → 下载 zip（**注意：Artifact 必须登录 GitHub 才能下**，curl 匿名请求会被拒）→ 手机上装。默认 debug 签名，可以直接装（会提示「未知来源」，允许即可）。

Release 由 `publish-apk.yml` 维护：它每次会自己找 `android-build2.yml` 最近一次**成功**的运行，取 `rustdesk-ux-apk` 产物，`--clobber` 覆盖同名资产。所以以后重新构建完，只要让这个 workflow 再跑一次，直链指向的就是新包。

> 踩过的坑：`gh release` 系列命令在没有 `actions/checkout` 的 job 里会报 `unable to determine repository` 并以 exit 1 退出，必须在 workflow 级 `env` 里给 `GH_REPO: ${{ github.repository }}`。


首次装建议先卸掉官方版，包名相同会冲突（除非你改了 `applicationId`）。

> 想彻底共存：把 `flutter/android/app/build.gradle` 里 `applicationId "com.carriez.flutter_hbb"` 改成 `com.yourname.rustdesk.ux`。

### 2.4 迭代节奏

| 操作 | 耗时 |
|---|---|
| 网页改 3 行 Dart | 1 分钟 |
| Actions 出包 | 8~12 分钟（首次 15） |
| 下载 + 装机 + 试手感 | 3 分钟 |

一天能跑 15~20 轮，够把手势调到「对」。真机手感这种东西只能靠这个循环磨。

---

## 3. 路线 B：要动 Rust core 时的全量编译

`build-apk-full.yml` 手动触发，输入 ABI / NDK 版本。它做的事：

1. 释放 runner 磁盘（删 dotnet / ghc / CodeQL，不删 Android SDK）
2. JDK 17 + Android SDK + 指定版本 NDK
3. Rust stable + `cargo-ndk` + 四个 android target
4. `Swatinem/rust-cache` 缓存 `~/.cargo` 和 `target/`（第二次构建直接省 30 分钟）
5. 调用仓库自带的安卓构建脚本（`flutter/build_android.sh`，若无则 `python3 build.py --flutter`）
6. 若脚本没产出 APK，再补一次 `flutter build apk`
7. 上传 artifact

**必须注意的三件事**：

- **ABI 只编 `arm64-v8a`**。ubuntu runner 只有 14G 空闲磁盘，四个 ABI 一起编必然 `No space left on device`。
- **NDK 版本必须和 `flutter/android/app/build.gradle` 里的 `ndkVersion` 一致**，否则链接阶段报一堆符号问题。workflow 里做成了输入参数。
- 若报 `libvpx` / `opus` / `aom` 找不到，把 `with_vcpkg` 打开，会装 vcpkg 的 android triplet。

---

## 4. 路线 C：Codespaces（需要跳转/补全时用）

`.devcontainer/` 已配好 Flutter + Rust + Android SDK + NDK，开箱可用。

```bash
# 建一个够用的机器（默认 2 核 8G 编 Rust 会超时）
gh codespace create -R <你的账号>/rustdesk -b ui-ux --machine standardLinux8gb
```

进去之后：

```bash
flutter pub get --directory flutter
cd flutter && flutter analyze          # Dart 静态检查，改手势时很有用
cd .. && cargo check                   # Rust 侧改动的快速校验（不交叉编译）
```

**Codespaces 不能直连手机**，所以它只用来「写 + 检查」，出包还是走 Actions。非要真机调试，只能：手机开无线调试（`adb tcpip 5555`）→ `gh codespace ports forward 5555:5555` → 容器里 `adb connect localhost:5555`，然后 `flutter run`。能通，但不如直接侧载省事。

---

## 5. 签名与分发

默认产物是 debug 签名，自己装没问题，但不能上架、不能覆盖安装正式版。

要稳定升级，用 secrets 配一个固定 keystore：

```bash
keytool -genkey -v -keystore rd.jks -keyalg RSA -keysize 2048 -validity 10000 -alias rd
base64 -w0 rd.jks > rd.jks.b64
```

把这几个加到 `Settings → Secrets and variables → Actions`：

| Secret | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `rd.jks.b64` 全文 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | `rd` |
| `ANDROID_KEY_PASSWORD` | key 密码 |

然后在 `flutter/android/key.properties` 里按 RustDesk gradle 的约定接上（不同版本字段名略有差异，看 `flutter/android/app/build.gradle` 的 `signingConfigs`）。

想每次 tag 自动发 Release（手机直接下 APK），加一步 `softprops/action-gh-release`，把 `flutter/build/app/outputs/flutter-apk/*.apk` 挂上去。

---

## 6. 踩坑清单（按遇到概率排序）

| 现象 | 原因 / 解法 |
|---|---|
| `Keystore file not set for signing config release` | **实测踩到**：`build.gradle` 的 `signingConfigs.release` 没填密钥。上游自己的做法是无密钥时 `sed -i "s/signingConfigs.release/signingConfigs.debug/g"`，照抄即可 |
| `Process 'command 'cargo'' finished with non-zero exit value 101`（build.gradle line 37） | **实测踩到**：`build.gradle` 配置阶段会执行 `cargo metadata`，而 fork 里 `libs/` 子模块是空的 → workspace 成员缺失。解法：`actions/checkout` 加 `submodules: recursive`，并确保 runner 上有 cargo（`dtolnay/rust-toolchain@stable`） |
| `'RustdeskImpl' isn't a type` | **实测踩到**：`flutter/lib/generated_bridge.dart` 是**构建产物，不在仓库里**。只改 Dart 也必须先跑 FRB codegen |
| `'rustfmt' is not installed for the toolchain` | **实测踩到**：FRB codegen 内部调用 `cargo expand`，需要 rustfmt 组件。`dtolnay/rust-toolchain` 加 `components: rustfmt` |
| 装完打开闪退 / `UnsatisfiedLinkError` | `.so` 版本和 Dart 层不匹配，或 jniLibs 少了 `libc++_shared.so`。做法：整目录解压官方 APK 的 `lib/arm64-v8a/` |
| `UnsatisfiedLinkError: librustdesk.so` | jniLibs 目录名不对，必须是 `arm64-v8a` / `armeabi-v7a` / `x86_64` |
| `No space left on device` | 只编 arm64，或改用 `ubuntu-22.04` + 删 dotnet 的步骤 |
| NDK 相关链接错误 | NDK 版本和 gradle 不一致 |
| push 触发十几个构建 | 上游 workflow 没删干净 |
| 构建 45 分钟超时 | 加 rust-cache / gradle cache，并设 `timeout-minutes: 150` |
| 覆盖安装失败 | 包名相同但签名不同，先卸载；或改 `applicationId` |
| Codespaces 编 Rust 卡死 | 免费额度机器太弱，换 8 核，或者干脆别在 Codespaces 编 |

---

## 7. 现在就做的下一步

1. Fork → 删上游 workflow → 拷入本目录 `.github/` 和 `scripts/` → 设 Public
2. 手动触发一次 `Build APK (Dart-only)`，确认**未改任何代码也能出包**（先验证管道通，再改逻辑）
3. 按 `docs/patch-plan.md` 从「悬浮球工具栏」这种低风险改动开始，一轮一轮替换
4. 手感改动优先级：trackpad 状态机 > 本地光标预测 > 中文输入 > 滚轮 > 悬浮球

---

## 8. P1 手势层（已落地，可直接装包验证）

新增 `flutter/lib/common/widgets/raw_trackpad.dart`，`RawTrackpadLayer` 用裸 `Listener` 接管触摸，绕开手势竞技场和 `kPanSlop`：

| 操作 | 行为 |
|---|---|
| 单指移动 | 立即移动远端光标（零门槛，不再等 18px） |
| 单指轻点 | 左键单击 |
| 单指长按 500ms | 右键单击 |
| 双击后继续拖 | 拖拽（按下左键保持） |
| 双指上下滑 | 滚轮（24px 一格，带累积） |
| 双指捏合 / 张开 | 画面缩放（以两指中心为焦点） |
| 双指拖动（仅在已放大时） | 平移已放大的画面（`scale > 1.12` 才允许） |
| 双指轻点 | 右键单击 |
| 三指轻点 | 显示 / 隐藏底部工具栏（`uuToolbarToggleTick` → `remote_page` 切 `_showBar`） |

手势模式（`_TwoMode`：`scroll` / `pinch` / `pan`）一次手势内按**指数衰减滑窗**判定
（`_winSpan` 对比 `_winFocal`，只看最近约 3 帧的趋势），捏合一旦成立就不再回退。
v4 修了「捏合判定被过早锁死」导致的缩放失效；v5 修了「累计量判据导致滚动被误判成缩放」（缩放过敏），
两段排查记录见上文 P4 / P5。

接入点只有一处：`remote_input.dart` 里 `_RawTouchGestureDetectorRegionState.build()`。
一键回退：把 `raw_trackpad.dart` 顶部的 `useRawTrackpadLayer` 改成 `false`，即恢复原手势路径（不需要动别的文件）。
