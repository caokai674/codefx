<p align="center"><strong>Codefx CLI</strong> is a coding agent from OpenAI that runs locally on your computer.
<p align="center">
  <img src="https://github.com/caokai674/codefx/blob/main/.github/codex-cli-splash.png" alt="Codex CLI splash" width="80%" />
</p>
</br>
If you want Codex in your code editor (VS Code, Cursor, Windsurf), <a href="https://developers.openai.com/codex/ide">install in your IDE.</a>
</br>If you want the desktop app experience, run <code>codex app</code> or visit <a href="https://chatgpt.com/codex?app-landing-page=true">the Codex App page</a>.
</br>If you are looking for the <em>cloud-based agent</em> from OpenAI, <strong>Codex Web</strong>, go to <a href="https://chatgpt.com/codex">chatgpt.com/codex</a>.</p>

---

## Quickstart

### Installing Codefx on Linux x86_64

[Codefx CLI 0.164.0](https://github.com/hitmux/codefx/releases/tag/rust-v0.164.0) is a stable release. Prebuilt packages are currently available for Linux x86_64 (musl).

Save and close active Codex sessions and stop any local app-server daemon before replacing the CLI:

```sh
curl -fsSL https://raw.githubusercontent.com/hitmux/codefx/main/scripts/install/install-codefx.sh | sh
```

Then verify the selected command:

```sh
codex --version
```

The command and executable remain named `codex`; version output reports `codefx 0.164.0`. The installer downloads and verifies SHA-256 checksums and the staged executable version before replacing the visible CLI.

Current replacement scope:

- Process shutdown, waiting and restart require manual handling. Running-process inspection protects cleanup of managed standalone releases.
- Package-manager detection inspects the first `codex` on PATH and uses heuristics for npm, Bun and Homebrew. pnpm, Vite+, multiple Node installations and custom native paths require manual review.
- An independently installed app-server daemon retains its own package and requires a separate migration.
- Other platform packages and native replacement validation remain pending.

[Review the replacement script](https://github.com/hitmux/codefx/blob/main/scripts/install/install-codefx.sh).

### Using Codex with your ChatGPT plan

Run `codex` and select **Sign in with ChatGPT**. We recommend signing into your ChatGPT account to use Codex as part of your Plus, Pro, Business, Edu, or Enterprise plan. [Learn more about what's included in your ChatGPT plan](https://help.openai.com/en/articles/11369540-codex-in-chatgpt).

You can also use Codex with an API key, but this requires [additional setup](https://developers.openai.com/codex/auth#sign-in-with-an-api-key).

## Docs

- [**Codex Documentation**](https://developers.openai.com/codex)
- [**Contributing**](./docs/contributing.md)
- [**Installing & building**](./docs/install.md)
- [**Open source fund**](./docs/open-source-fund.md)

This repository is licensed under the [Apache-2.0 License](LICENSE).
