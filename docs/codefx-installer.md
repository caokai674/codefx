# Codefx 安装与升级

安装脚本在 Linux、macOS 和 Windows 上提供同一套安全切换流程，支持各系统的 x86_64 和 ARM64 架构。Linux 使用 musl 安装包；macOS 自动识别 Apple Silicon，包括 Rosetta 终端；Windows 使用原生 PowerShell 脚本。

安装包是否可用，以对应 Release 的附件和本平台 `.sha256` 文件（或旧版 `codex-package_SHA256SUMS`）为准。缺少本机安装包或校验记录时，安装会退出并保留原版本。32 位系统不受支持。

## 入口

- Linux / macOS：[`scripts/install/install-codefx.sh`](../scripts/install/install-codefx.sh)
- Windows：[`scripts/install/install-codefx.ps1`](../scripts/install/install-codefx.ps1)
- 基础安装器：[`install.sh`](../scripts/install/install.sh)、[`install.ps1`](../scripts/install/install.ps1)

入口脚本会把安装器源码引用解析为固定的 Git 提交，再下载和运行该提交的基础安装器。下载要求 HTTPS，有重试和超时。可以使用 `CODEFX_INSTALL_REF` 固定审核过的提交。遇到 GitHub API 限流时，可通过环境变量 `CODEFX_GITHUB_TOKEN` 提供只读令牌；安装器只对本仓库的 API 元数据请求附加认证，不把令牌写入安装配置，也不传给启动的 Codefx 或 daemon。

## 参数

| 目的 | Linux / macOS | Windows |
| --- | --- | --- |
| 查看计划，保持安装不变 | `--dry-run` | `-DryRun` |
| 指定版本 | `--release 0.164.0` | `-Release 0.164.0` |
| 请求运行中的会话正常退出 | `--stop-running` | `-StopRunning` |
| 保留独立 daemon 的包与更新设置 | `--keep-daemon` | `-KeepDaemon` |
| 进程操作超时 | `CODEFX_PROCESS_TIMEOUT=30` | `-ProcessTimeout 30` |
| 等待安装锁的上限 | `CODEFX_LOCK_TIMEOUT=120` | `-LockTimeout 120` |

进程超时允许 1–300 秒，安装锁等待允许 1–600 秒。默认安装最新正式版；显式指定版本会固定版本，取消该安装的自动跟随 latest 设置。

`--dry-run` / `-DryRun` 读取发布元数据并列出命令来源，不下载完整安装包、不停止进程，也不验证完整安装包的可执行性。

## 下载与切换

1. 读取 Codefx Release 元数据，确认当前系统和架构的附件存在。
2. 获取安装锁；检测到上次中断的事务时，先恢复原安装。
3. 优先下载已发布的本平台 `.sha256` 校验文件，兼容旧版全平台校验清单；下载安装包，并核对校验文件及安装包的摘要与 GitHub 发布记录一致。
4. 在独立目录中检查归档路径、文件类型、包清单、资源和可执行程序。拒绝路径穿越、链接文件和特殊文件。程序必须正常退出并准确报告 `codefx VERSION`。
5. 检查运行中进程，保存命令入口、版本选择、更新标记、PATH 配置和 daemon 选择的恢复记录。
6. 切换版本目录与命令入口，验证新命令；需要时迁移独立 daemon 并检查健康状态。
7. 完成事务，保留恢复记录。失败时恢复原入口、配置和同版本目录的旧文件。

SHA-256 能验证下载内容与发布记录一致；它不替代对发布者及其账号安全的信任。安装器不会自行提升权限。

## 正在运行的 Codex

默认检测当前用户的 Codex 会话，发现运行中进程便退出，原安装保持可用。

请先保存工作并关闭会话，再安装。如果选择停止会话，应从独立的系统终端运行并显式传入 `--stop-running` / `-StopRunning`。安装器发现自己在 Codex 的祖先进程树中时，会要求改用外部终端。

Linux / macOS 请求进程响应 SIGTERM。Windows 请求有窗口的程序正常关闭；没有可关闭窗口的控制台会话需要用户自行退出。安装器等待有限时间，超时即退出并恢复原安装。它不会用强制结束来处理用户会话。并发启动的新会话仍可能使切换失败，此时保留恢复信息并报告具体错误。

## npm、pnpm、Bun、Vite+、Homebrew 与原生安装

安装器列出 PATH 中的 `codex` 命令，使用独立的原生安装目录和优先命令入口完成切换。旧包管理器的登记和其他 Node 版本中的包会保留；安装器不自动运行全局卸载命令。这支持多包管理器、多 Node 版本和自定义前缀环境，也保留返回原安装的路径。

Linux / macOS 默认入口是 `~/.local/bin/codex`，可用绝对路径 `CODEX_INSTALL_DIR` 修改。Shell 配置会将该目录置于 PATH 前方；当前终端需按脚本输出更新 PATH，或打开新终端。Shell alias、function 和命令缓存需要在使用它们的终端中检查。

Windows 默认入口是 `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin`，使用 junction 进行选择，更新用户 PATH，并由入口脚本更新当前 PowerShell 的 PATH。支持 Windows PowerShell 5.1 和 PowerShell 7。Windows 合并 PATH 时系统项先于用户项，系统级旧命令可能仍被新终端优先选中；安装器会检测并报告实际冲突，提供新程序的完整路径。它也会提示当前会话中的 alias、function 等遮蔽。使用 `Get-Command codex -All` 排查，按原包管理器的方式处理系统级旧命令。

自定义原生安装、系统包管理器拥有的文件和管理员安装会保留。Windows 的可识别旧版原生平铺目录会在新包验证后整体备份，再切换入口；空目录也可直接使用并在失败时恢复。含其他文件的未知目录或不受支持的 reparse point 会保留并提示处理。自定义命令目录必须位于安装器管理的包目录之外。

验证：

```sh
codex --version
```

预期输出 `codefx 0.164.0`。Unix 可用 `command -v codex` 查看入口；Windows 使用 `Get-Command codex -All`。

## 独立 app-server daemon

发现已经配置的独立 daemon 时，默认使用新 CLI 的 `app-server daemon update --from-cli --yes` 迁移其包。原先运行中的 daemon 需要显式允许停止；迁移后恢复运行并校验版本。原先停止的 daemon 在迁移后保持停止。`--from-cli` 会将独立 daemon 固定到这份已验证的 CLI 包，不会自动跟随后续版本；要重新启用 Codefx 正式版更新，需运行 `codex app-server daemon update`。CLI 自身的更新检查仍指向 Codefx。

`--keep-daemon` / `-KeepDaemon` 用于保留其独立包与更新设置；使用该选项时应先自行关闭运行中的 Codex 进程。保留的旧官方 daemon 也会保留原有更新来源。

Rust 自动更新器会传递 `CODEX_INSTALL_IF_LATEST`、`CODEX_INSTALL_IF_CURRENT`、`CODEX_INSTALL_DAEMON_ONLY` 等保护参数。入口完整透传这些参数，由 Rust 协调运行中的进程；安装器不会在该路径尝试停止更新器父进程。

## 失败与恢复

下载、校验、进程检查失败时，会退出并给出原因。切换过程中失败会自动恢复；恢复自身失败时会保留 `<安装根目录>/.transaction`，并报告需要关注的路径。下次安装在获得锁后会先重试恢复。请保留该目录及 `.backup.*`，直到确认原命令和 daemon 状态正常。

成功事务的入口和配置备份保存在 `.rollback.<时间>.<PID>`。同版本目录被修复时，其旧内容保存在 `releases/.backup.*`。这些目录用于排查和恢复；它们可能占用磁盘，确认新版本稳定后可以自行清理。正常版本保留策略仍会考虑当前选择、前一选择和运行中的程序。

断电、磁盘损坏、文件被外部程序同时修改或系统拒绝恢复操作时，自动恢复可能无法完成。安装器会保留诊断和恢复记录。

## 自动更新来源与验证范围

首次迁移会清理沿用的官方版本检查缓存，原缓存随事务备份保留；后续同源更新保留新的缓存与忽略版本设置。Codefx CLI 的更新检查和更新入口指向 `hitmux/codefx` 的正式 Release。独立 daemon 迁移后使用 Codefx 包；保留的其他安装按各自管理器的设置更新。

专用 CI 在 Linux、macOS 和 Windows 的原生 runner 上执行安装器回归检查。Windows 使用真实 PE 可执行文件、tar 包和 junction，并分别运行 PowerShell 5.1 与 7。发布工作流为三系统、两架构生成包，在对应原生 runner 上执行版本与资源检查，每个平台的包与校验文件均验证后发布，可独立安全安装；所有平台验证完成后再汇总全局校验清单，并运行真实原生安装与 daemon 迁移检查。
