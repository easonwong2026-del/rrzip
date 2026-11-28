# FinderSync 任务转交方案

## 目标与边界

Finder 扩展识别选择项、构建菜单并投递任务。压缩、解压、密码、进度、取消及退出收尾由主程序执行。App 服务仍作为 Finder 扩展不可用时的兼容入口。

## 方案比较

| 方案 | ad-hoc 签名 | Developer ID 签名并公证，扩展开启沙盒 | 判断 |
| --- | --- | --- | --- |
| Mach / XPC | 需要可用的服务注册、沙盒查找和对端身份校验。没有稳定签名身份时，不能以签名同源作为授权前提。 | 可使用 App Group 命名空间内的服务，校验调用方签名和用户身份。另需解决冷启动、断线恢复和持久排队。 | 适合后续实时进度和双向控制，需要独立生命周期管理。 |
| App Group 文件队列 + 唤起主程序 | 当前 ad-hoc 产物没有可依赖的共享容器配置。开发过渡可沿用已有的用户级应用支持目录，但权限应缩至队列子目录。共享容器须按目标系统实测。 | 应用和扩展使用同一 App Group。系统提供共享容器，进程重启后仍能恢复接收和查重。 | 推荐首期。沿用现有文件转交经验，覆盖冷启动与恢复。 |
| 自定义 URL Scheme | 可以发送唤醒信号。调用方和这次菜单操作没有可靠关联。 | 公证不会限制其他应用触发该 URL，也无法防止同名 scheme 冲突。 | 只适合作为可选唤醒入口，URL 不携带可执行任务、路径或密码。 |

Apple 为 App Group 提供共享容器及带组名前缀的 Mach/XPC 服务名。沙盒进程访问组外的全局 Mach 服务通常还需要单独授权。[App Groups Entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.application-groups) · [App Sandbox Temporary Exception Entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)

Finder 扩展已能根据 appex 路径定位主程序。发布一条请求后，用 `NSWorkspace.openApplication(at:configuration:completionHandler:)` 唤起对应 app。主程序在启动、激活和接收目录变动通知时扫描队列。唤醒回调只表示系统接受启动请求，任务是否受理以队列中的回执为准。[Finder Sync](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html) · [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication%28at%3Aconfiguration%3Acompletionhandler%3A%29?language=objc) · [Custom URL Scheme](https://developer.apple.com/documentation/Xcode/defining-a-custom-url-scheme-for-your-app)

## 请求、回执与任务生命周期

队列包含 `inbox/`、`claimed/` 和 `status/`。扩展先写同目录临时文件，随后原子改名为 `inbox/<UUID>.json`。主程序原子移动到 `claimed/` 后才受理。每个请求只代表一次用户点击，重复通知和同一请求的传输重试使用原 UUID，用户再次点击生成新 UUID。

| 记录 | 字段 |
| --- | --- |
| 请求 | `version`、`id`、`createdAt`、`operation`、`sources`、`destination`、`conflictPolicy` |
| 文件引用 | 路径、显示名和可选的最小书签。书签使整条请求超出队列上限时，重试只携带已校验的路径。 |
| 操作 | `extractHere`、`extractToFolder`、`compressZip`、`compressSevenZip`、`compressEach`。扩展只提交白名单操作。 |
| 目标 | 可选的已授权目录引用，或由主程序按原目录和该操作的规则计算。解压到已有目录时默认跳过同名文件，压缩输出重名时自动改名。 |
| 回执 | `version`、`id`、`state`、`updatedAt`、`completedCount`、`totalCount`、可选 `fraction`、`errorCode`、`message`、产物显示名。 |

- 读入前核对文件名与 UUID、版本、数量和大小上限。应用支持目录限定为当前用户拥有的普通目录，队列文件拒绝软链和未知字段指定的任意命令。ad-hoc 的同 UID 目录不能证明发送者身份，主程序仍要核对操作、文件和落点。
- 同一 UUID 在待处理、运行和终态中只能受理一次。启动后将上次遗留的已领取任务标为 `interrupted`，提示检查结果，再由用户发起新请求，避免重复写入。
- 以 30 秒无受理回执作为启动异常提示，排队文件保留 10 分钟；超时后写 `expired`。已经运行的任务没有统一时限，大归档由用户主动取消，结束后保留回执 24 小时供扩展或主程序读取。
- 回执阶段为 `queued`、`running`、`needsPassword`、`succeeded`、`failed`、`cancelled`、`expired` 或 `interrupted`。退出接管时，新请求记录 `appQuitting` 并留在终态，已受理任务遵循主程序的等待与取消规则。
- 主程序以独立的进程内任务 ID 登记引擎和正式写入。任务卡显示 7-Zip 报告的百分比，tar 使用不确定进度。队列在项目完成及状态切换时写回执。卡片取消和取消退出都会终止当前引擎并清理暂存，已经发布的项目保留。
- 无权限返回 `accessDenied`，沙盒书签失效时请用户在主程序重选文件或目标目录。其他错误沿用归档安全预检、密码、占用及取消语义。密码只由主程序交互获取，队列、回执和日志均不保存密码。

App Group 共享的是队列数据，文件访问仍依赖系统授予的选择权限。跨进程书签和持久化书签的授权行为不同，必须在 macOS 14 及较新版本中验证 Finder 选择所得授权能否被主程序使用；授权不足时在主程序重新选择。[Accessing Files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

## Entitlements 收敛

1. 签名版将 `com.apple.security.application-groups` 配到主 app 和 Finder 扩展，组名按 Apple 当前 macOS App Group 规则选取，同一开发者签名。Quick Look 无任务转交职责。
2. 扩展不再直接调用压缩引擎或写解压目标后，先在签名版移除应用支持目录例外。等已选择文件和目标书签用例通过，再将 `user-selected.read-write` 收至实际需要的访问级别。
3. 对 `ArchiveFinder-adhoc.entitlements` 先验证只需写队列和计算文件引用的路径。通过后移除 `/` 与 `/private/var/folders/` 的绝对路径例外，并将原应用支持目录读写缩为队列子目录。兼容性失败时明确提示用主程序操作，尤其需要密码或 7-Zip 的项目。
4. Developer ID 签名、公证与文件访问权限分别验证。可用性以真实 Finder 进程读取共享容器、主程序收件和书签授权三项均通过为准。

## 实施和测试

1. **先验证签名链路。** 用只读的探针请求检查 Finder 在 ad-hoc 和 Developer ID 下能否发布，主程序在冷启动和已运行时能否受理，回执是否回到扩展。覆盖两种系统版本、Finder 重启和扩展重装。
2. **接入任务队列。** 先迁移普通 ZIP 的「解压到此处」与同名目录，复用冲突策略和安全预检。覆盖重复请求、损坏 JSON、并发领取、唤醒失败、权限失效、已设置退出等待和领取后崩溃。
3. **迁移其余动作。** 验证 7Z 压缩、密码连续重试、解压取消和退出等待。检查 iCloud 占位、本地卷、移动盘及 SMB/NFS。确保目标未授权时不写文件、同名文件不被覆盖、退出后无失控子进程。
4. **再收紧沙盒。** 在应用及扩展打包、公证并正常启用后跑实际 Finder 操作矩阵。对照 `codesign` 的生效 entitlements 与系统沙盒日志，确认仅保留实际用到的权限。回归通过后停用旧的 Finder 直跑路径。
