# Tailcat Manager for macOS

SwiftUI 设备侧栏应用，管理多个独立 Tailcat → ADB 会话。第一版面向本机使用，macOS 13 及以上；当前构建目标为 Apple Silicon。

下载最新版：[GitHub Releases](https://github.com/suyunkai/tailcat-tool/releases/latest)。发行 ZIP 仅包含应用包；`SHA256SUMS` 用于核对下载文件。Tailcat、ADB 和 scrcpy 由本机工具或 Homebrew 提供。

项目源码采用 [MIT License](LICENSE)。官方 Tailcat 猫图参考及衍生应用图标保留上游 BSD 3-Clause 许可，详见 [第三方素材声明](THIRD_PARTY_NOTICES.md)。

## 构建和启动

需要 macOS Command Line Tools（Swift 5.9+）或 Xcode，以及支持 `forward`、`parse` 的 Tailcat。已验证本机 Tailcat v0.7.0。

```sh
bash scripts/build-app.sh
open "dist/Tailcat Manager.app"
```

脚本同时生成 `dist/Tailcat-Manager-<版本>.zip`，其中只包含已签名的应用包。

也可以开发运行：

```sh
swift run TailcatManager
```

应用从 Homebrew、`~/.local/bin`、Android SDK 和 PATH 检测工具。“工具设置”可指定 Tailcat、ADB、scrcpy 可执行文件和地址簿目录。ADB 必需；scrcpy 仅用于屏幕控制。

缺失组件可以点侧栏或工具设置中的“安装”，也可点“安装缺失组件”依次安装全部缺失工具。使用 Homebrew 官方命令：[Tailcat](https://formulae.brew.sh/formula/tailcat) 为 `brew install tailcat`，[ADB](https://formulae.brew.sh/cask/android-platform-tools) 为 `brew install --cask android-platform-tools`，[scrcpy](https://formulae.brew.sh/formula/scrcpy) 为 `brew install scrcpy`。界面显示进度和日志，支持取消及失败后重试，成功后自动保存路径。已存在的工具直接检测并配置。

安装只在用户点击时运行；该次命令关闭 Homebrew 自动更新、已安装包升级、安装后清理和依赖包检查，避免额外变动。安装缺失工具所必需的依赖仍交由 Homebrew 处理。未检测到 Homebrew 时提供官方安装页面入口，需要先完成 Homebrew 安装。

本地 `.app` 默认使用固定的本机开发签名，不是经过 Developer ID 签名和公证的分发包。首次打包会在 `~/Library/Application Support/TailcatManager/Signing/` 创建专用签名钥匙串，后续打包复用；私钥不进入项目、应用包或 ZIP，不修改系统信任设置，用户的钥匙串搜索列表会保持原样。也可用环境变量 `TAILCAT_SIGNING_IDENTITY` 指定现有签名身份。请保留签名目录，重新生成身份会使已有授权失效。

打包时发现目标应用正在运行，会将新版放到 `dist/<版本>/Tailcat Manager.app`，保留当前实例的连接；退出旧版后再打开新包。没有打包现有连接地址、用户私钥或外部工具二进制。

## 使用

- 首次启动时，如果应用还没有设备，会导入现有 `tailcat-adb/users/` 地址簿。之后可点工具栏“导入地址簿”，只添加缺失用户，保留 GUI 内的编辑。
- 工具栏“测试全部设备”可一键测试我的设备和临时设备的 Tailcat ping，显示每台的响应、延迟、直连或 DERP 中继路径、已有 ADB 状态和测试时间。每台 ping 5 秒超时，外层最多 8 秒，并发最多 3 台；支持取消和重试，不创建转发或执行 ADB connect/disconnect。结果是一次测试的快照：收到 pong 确认 Tailcat 可达；未收到 pong 也可能是服务器版本不支持或新链路建连超时，不能据此断定已有 ADB 离线。ADB 列显示当前已有会话的状态；未连接设备的 ADB 端口、授权和 Shell 权限仍需实际连接后检查。
- 工具栏闪电按钮、侧栏“新建临时连接”或 `⌘⇧N` 可建立临时设备。只需填写连接地址，名称可选；本地端口默认自动分配。临时设备单独分组，支持多台同时连接以及全部常用 ADB 操作。
- 临时配置和凭据仅保存在内存中，不写配置文件、Keychain 或 CLI 地址簿。断开后在本次运行中仍可重连；关闭临时设备或退出应用时停止其通道并清除临时配置。需要保留时点“保存到我的设备”，当前 UUID、通道和正在执行的任务保持，凭据从此保存到 Keychain。
- 默认地址簿位于 `${XDG_STATE_HOME:-~/.local/state}/tailcat-adb`。Finder 启动不一定继承终端的 XDG 环境变量，自定义位置请在设置中指定。
- 地址簿是只读来源；不改写 `address`、`current-user`、`local-port`、PID 或日志，也不接管现有 CLI 通道。
- 启动和运行期间约每 3 秒识别已有 CLI 通道，在对应设备下显示“CLI 外部连接”、本地入口、PID、设备型号和 ADB 状态。支持同一设备多个 CLI 端口，并可与该设备的 GUI 通道分别显示。
- 识别会核对 `bridges/<port>.pid`（兼容旧 `bridge.pid`）、实际 socat 命令、监听 PID/端口、连接地址与 GUI 当前凭据；跳过符号链接、失效 PID、端口不一致及其他进程。识别不会连接、重连、断开或结束 CLI 进程。
- 已在线的 CLI 外部连接可以使用终端、安装 APK、文件传输、Shell、链路探测和 scrcpy；会自动读取设备信息，也可点“刷新信息”。执行设备操作前再次核对 CLI 的进程、监听和 ADB 状态；入口被替换或设备未授权时拒绝操作。CLI 的重连、断开仍由 CLI 控制。
- 添加设备后选择“连接”。每台设备有独立进程和 ADB serial，支持同时连接。自动端口从 5556 到 5655 逐个实际绑定，已有监听端口保持；也可为设备指定固定端口。
- 待授权、离线、转发进程退出分别显示。只有 ADB `device` 状态允许安装、文件传输、Shell 和 scrcpy。
- 所有任务在启动时固定设备、ADB 路径及 serial。切换侧栏不会改变任务目标；重连、断开会先取消该设备正在执行的任务。
- 支持 APK 覆盖安装、文件/目录上传下载、单条 Shell 命令、系统 Terminal 和独立 scrcpy 窗口。任务输出与取消按钮位于底部。
- 关闭主窗口后连接继续运行，从菜单栏重新打开；退出应用会停止 GUI 启动的设备任务（包括 CLI 入口上的 GUI 任务）及应用创建的通道，只对应用自建通道的 serial 执行 `adb disconnect`，保留 CLI 通道，不会重启全局 ADB 服务。
- ADB 离线时最多尝试 6 次恢复，间隔逐步增加；待授权不自动重试。唤醒后重新检测。转发进程退出时由用户点击“重新连接”。

取消会停止本机命令进程，远端已经发生的安装或文件写入不会自动回滚。传输任务、Shell 命令、连接状态都有超时；持续使用的 scrcpy 会话最多运行 24 小时。

## 配置与凭据

设备连接地址仍存入本机登录 Keychain。macOS 对 ad-hoc 和本机证书签名的程序使用每次构建的代码哈希进行额外授权检查，因此只固定 GUI 签名还不足以避免更新后重复授权。

应用第一次启动会校验并安装一个固定版本的凭据助手到 `~/Library/Application Support/TailcatManager/CredentialHelper/v1/`，后续 GUI 更新复用同一文件。助手只接受与自己使用同一签名证书、且身份为 `cc.coauto.tailcat-manager` 的直接父进程；它只操作本应用服务下的 UUID 凭据，通过匿名管道传递数据，地址不进入命令参数或日志。设备凭据不迁出 Keychain。授权后的值仅在本次 GUI 运行的内存中缓存。

首次切换到新版时，旧条目仍可能需要授权一次：输入登录钥匙串密码并点“始终允许”，每个设备条目独立授权。后台 CLI 检测禁止弹窗；需要授权时可主动点侧栏“授权识别 CLI 连接”，或连接该设备。保留固定助手和签名目录，正常更新不重新授权。开发时直接 `swift run TailcatManager` 使用开发进程自己的 Keychain 身份，授权可能与打包应用不同。

名称、端口和工具路径保存在：

```text
~/Library/Application Support/TailcatManager/configuration.json
```

目录权限为 700，配置文件为 600；配置文件不包含连接凭据。日志自动隐藏完整 `tc...` 地址。每次 GUI 连接、单设备链路探测和批量测试中的每台设备都显式使用 `--key=new`，在各自进程内生成独立临时身份，避免多个进程共用 `client-default` 争用 DERP 通道。身份不落盘，重连或重新探测会生成新身份；不会读取、导出或替换用户保存的客户端私钥。升级前已启动的通道保持原身份，重新连接后才使用新身份。

如果远端配置了只允许固定客户端公钥的白名单，临时身份需要远端允许后才能连接；仍可通过现有 CLI 使用已授权的固定身份，再由 GUI 识别该 CLI 外部连接并执行 ADB 操作。GUI 不修改 CLI 的身份和会话；GUI 发起的探测仍使用独立临时身份，白名单拒绝探测不表示已有 CLI/ADB 断线。

使用 Clash Verge 的 TUN 时，建议在“订阅 → 全局扩展脚本”的 `main` 函数返回前加入以下内容，让 Tailcat 的 STUN、DERP 和对端 UDP 使用一致的直连出口；保留原脚本的其他逻辑，再点“重新激活订阅”。规则只匹配 `tailcat` 进程，其他程序继续使用原有规则。不要只放行 STUN 的 IP 或端口，也不要覆盖整份 `rules`。其他代理客户端请使用对应的进程分流功能。

```js
const rule = "PROCESS-NAME,tailcat,DIRECT";
config.rules = [rule, ...(config.rules || []).filter(item => item !== rule)];
```

配置直连和独立身份能排除本机的分流与身份冲突；能否打洞还取决于两端 NAT、UDP 防火墙等网络条件。探测界面的路径属于该次独立探测，不能证明另一个已运行的转发会话正在直连。

源码仓库只包含代码、测试、构建脚本和图标资源。本机配置、连接地址簿、Keychain 内容、私钥及证书导出、日志和 `.build` / `dist` 构建输出不上传；`.gitignore` 已排除相应文件与目录。测试中的完整 Tailcat 地址来自官方公开文档示例，其余地址为测试时生成的模拟值。

## 验证

```sh
swift run TailcatChecks
swift run TailcatChecks --native-tailcat
swift run TailcatChecks --native-tailcat --keychain
bash scripts/check-signing.sh
```

验证程序不依赖 XCTest / Swift Testing，适用于只有 Command Line Tools 的机器。覆盖双设备隔离、固定任务目标、待授权、连接取消、重连取消旧任务、异常退出、地址簿只读导入、配置权限、参数传递、双管道输出、进程超时和取消；另外覆盖临时设备不落盘、不访问持久凭据、独立关闭、保存时保留正在执行的任务、保存失败回滚，CLI 多端口识别、入口更换拒绝操作、元数据和 ADB/scrcpy 操作、退出取消 GUI 任务但保留 CLI 通道，以及 Homebrew 命令、批量安装、自动配置、失败和取消。安装行为使用模拟 Homebrew，不改动本机已安装组件。

`--native-tailcat` 额外使用已安装 Tailcat 创建两个本地监听端口，验证每次启动显式使用独立身份、就绪输出、端口避让和独立退出；通过两个 `--key=new printpub` 进程确认临时公钥不同。监听测试使用官方公开示例地址，不拨号到远端，不连接真实车机。该验证不等于实车端到端验收。

`--keychain` 使用随机 UUID 的模拟凭据验证 Keychain 的创建、读取、更新和删除，结束后删除测试条目，不读取真实设备凭据。

`check-signing.sh` 使用随机 UUID 的模拟凭据，验证不同 GUI 构建复用固定助手后仍能无弹窗读取；ad-hoc 调用方及同证书但应用身份不同的调用方被拒绝。结束后删除测试条目及临时助手，不读取真实设备凭据。行为检查还覆盖凭据缓存更新、后台无交互读取、批量 ping 的并发上限、超时、取消、结果解析和输出脱敏。

界面演示：

```sh
open "dist/Tailcat Manager.app" --args --demo
```

演示模式使用内存配置和模拟命令，不读取真实地址簿、不写 Keychain，也不执行真实设备操作。退出已启动的普通实例后，再启动演示模式。

## 目录

- `Sources/TailcatCore`：配置、地址簿、Keychain、进程与独立会话、任务和 ADB 状态管理。
- `Sources/TailcatManager`：SwiftUI 侧栏、设备详情、表单、菜单栏和演示环境。
- `Tests/TailcatCoreTests`：可独立运行的行为验证程序。
- `scripts/build-app.sh`：Release 构建与本地 `.app` 打包。
- `resources/AppIcon.png`：图标原图；`scripts/build-icon.sh` 生成包含标准与 Retina 尺寸的 `AppIcon.icns`，随应用包一起签名。

第一版不包含远端 Tailcat 部署、客户端密钥管理、内嵌视频/终端、云同步或应用内自动更新。

正常退出会清理连接。强制结束应用或应用崩溃后的孤儿进程恢复尚未实现；旧监听会被新实例避让，第一版不会按 PID 文件自动结束不明进程。
