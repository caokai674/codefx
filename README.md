<p align="center"><strong>Codefx CLI</strong> is a fork of OpenAI Codex CLI with resilient retries and Codefx release updates.
<p align="center">
  <img src="https://github.com/hitmux/codefx/blob/main/.github/codex-cli-splash.png" alt="Codex CLI splash" width="80%" />
</p>
</br>
If you want Codex in your code editor (VS Code, Cursor, Windsurf), <a href="https://developers.openai.com/codex/ide">install in your IDE.</a>
</br>If you want the desktop app experience, run <code>codex app</code> or visit <a href="https://chatgpt.com/codex?app-landing-page=true">the Codex App page</a>.
</br>If you are looking for the <em>cloud-based agent</em> from OpenAI, <strong>Codex Web</strong>, go to <a href="https://chatgpt.com/codex">chatgpt.com/codex</a>.</p>

---

## Quickstart

### Installing Codefx

[Codefx CLI 0.165.0](https://github.com/hitmux/codefx/releases/tag/rust-v0.165.0) is a stable release. Native packages and installer checks cover:

| Platform     | Architectures        |
| ------------ | -------------------- |
| Linux (musl) | x86_64, ARM64        |
| macOS        | Intel, Apple Silicon |
| Windows      | x64, ARM64           |

Use the reviewed installers below or the [verified installer bundle](https://github.com/hitmux/codefx/releases/download/rust-v0.165.0/codefx-installers-38f48572fe9f.zip). The original `rust-v0.165.0` source archive contains historical wrappers that uninstall existing packages before downloading; the revised installers are maintained independently of that binary build tag.

Linux / macOS -- download the complete bootstrap before executing it:

```sh
(
  set -eu
  installer="$(mktemp)"
  trap 'rm -f "$installer"' EXIT
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 10 --max-time 120 \
    https://raw.githubusercontent.com/hitmux/codefx/main/scripts/install/install-codefx.sh -o "$installer"
  sh "$installer"
)
```

Windows -- run in a non-elevated PowerShell:

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop -Uri 'https://raw.githubusercontent.com/hitmux/codefx/main/scripts/install/install-codefx.ps1').Content))
```

Verify the selected command with `codex --version`; the executable remains named `codex` and reports `codefx 0.165.0`.

The installer verifies release checksums, archive paths, package metadata and the staged executable before switching commands. It records the previous installation and restores it if cutover fails. Existing npm, pnpm, Bun, Vite+ and Homebrew registrations remain available; the new native command uses a dedicated installation directory.

Running Codex sessions and managed daemons are checked **before large package downloads**. In an interactive terminal, the installer asks for explicit approval before closing sessions. Answering no (the default) leaves Codex running and cancels the installation; non-interactive runs fail safely. For unattended updates you can pass `--stop-running` (Unix) / `-StopRunning` (Windows) from an external terminal. To wait for sessions to exit naturally, use `--defer-until-idle` / `-DeferUntilIdle` (900-second default, configurable timeout). Windows console sessions without a closeable window may still need to be closed manually. Configured independent daemons are migrated through the verified new CLI, with their original running or stopped state preserved. This migration pins the daemon to the verified CLI package; `codex app-server daemon update` returns it to Codefx production updates.

Codefx update checks use Codefx releases. The first migration clears the shared upstream version cache, with its original contents retained in the transaction backup. `--release` / `-Release` pins a version; the default follows the latest stable release.

[Installer options and recovery guide](docs/codefx-installer.md) ; [Linux/macOS source](scripts/install/install-codefx.sh) ; [Windows source](scripts/install/install-codefx.ps1) ; [Native installation checks](https://github.com/hitmux/codefx/actions/runs/40171185576)

### Using Codex with your ChatGPT plan

Run `codex` and select **Sign in with ChatGPT**. We recommend signing into your ChatGPT account to use Codex as part of your Plus, Pro, Business, Edu, or Enterprise plan. [Learn more about what's included in your ChatGPT plan](https://help.openai.com/en/articles/11369540-codex-in-chatgpt).

You can also use Codex with an API key, but this requires [additional setup](https://developers.openai.com/codex/auth#sign-in-with-an-api-key).

## Docs

- [**Codex Documentation**](https://developers.openai.com/codex)
- [**Contributing**](./docs/contributing.md)
- [**Installing & building**](./docs/install.md)
- [**Open source fund**](./docs/open-source-fund.md)

This repository is licensed under the [Apache-2.0 License](LICENSE).
