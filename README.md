# ai-workstation

A sandboxed setup for AI coding agents on Windows and Linux, built for C++/Qt work.

- **OpenCode** runs inside a rootless Podman container with no internet access. Its only route out is a small gateway that forwards a few LLM API paths to Cortecs and holds the API key.
- **Kilo Code** runs in VS Code on the host for direct prompting.
- **One shared skills folder** (`~/.agents/skills`) is read by both tools. A script fills it from a pinned upstream repo plus your own skills.

The full explanation, every design decision and the troubleshooting table are in [GUIDE.md](GUIDE.md). This file is the short version.

## How the sandbox works

```
agent container ──(internal network, no DNS, no gateway)──> llm-gateway (nginx) ──> api.cortecs.ai
        └── optional: egress-squid (domain allowlist) for docs lookups, started with -Docs
```

- The agent container is on an internal Podman network. It cannot resolve names or reach the internet.
- The gateway adds the API key from a Podman secret. The key never enters the agent container.
- The gateway allows only `GET` and `POST` on `/v1/responses`, `/v1/chat/completions`, `/v1/models` and `/v1/messages`.
- The agent runs as a non-root user with a read-only root filesystem and all capabilities dropped. Skills and config are mounted read-only, and so are `.git/hooks`, `.git/config` and `.vscode` in your project.
- Build output and the compiler cache live in named volumes, not in your project.

## Requirements

| | Windows 11 | Linux |
| --- | --- | --- |
| Podman | rootless Podman machine (WSL2) | Podman 4.x or newer, rootless, netavark and aardvark-dns |
| Scripts | PowerShell 7 or newer (`pwsh`), the `*.ps1` files | bash 4 or newer, the `*.sh` files (no PowerShell needed) |
| Other | Git | Git |

Details and the exact commands are in section 3 (Windows) and section 3L (Linux) of the guide.

## Quick start

Every script exists twice with the same name and behaviour: `.ps1` for Windows, `.sh` for Linux.

**Windows (PowerShell 7)**

```powershell
# 1. Skills: clone the upstream skills repo, then copy the selected ones into ~/.agents/skills
git clone https://github.com/mattpocock/skills <somewhere>
pwsh scripts/sync-skills.ps1 -Upstream <somewhere> -DryRun
pwsh scripts/sync-skills.ps1 -Upstream <somewhere>

# 2. Store the Cortecs key as a Podman secret (prompts for it)
pwsh scripts/set-key.ps1

# 3. Build the agent image (pick an OpenCode version, see guide section 6.1)
podman build -t localhost/ai-agent:latest --build-arg OPENCODE_VERSION=<version> images/agent

# 4. Check that the sandbox really blocks what it should (every line must say PASS)
pwsh scripts/verify-sandbox.ps1 <path-to-your-project>
pwsh scripts/verify-sandbox.ps1 <path-to-your-project> -Docs   # also tests the docs proxy

# 5. Work
pwsh scripts/agent.ps1 <path-to-your-project>
```

**Linux (bash)**

```bash
chmod +x scripts/*.sh        # once; or run them as: bash scripts/<name>.sh

git clone https://github.com/mattpocock/skills <somewhere>
scripts/sync-skills.sh --upstream <somewhere> --dry-run
scripts/sync-skills.sh --upstream <somewhere>

scripts/set-key.sh           # asks for the key; or: pass show cortecs | scripts/set-key.sh --stdin

podman build -t localhost/ai-agent:latest --build-arg OPENCODE_VERSION=<version> images/agent

scripts/verify-sandbox.sh <path-to-your-project>
scripts/verify-sandbox.sh --docs <path-to-your-project>

scripts/agent.sh <path-to-your-project>
```

Before the last step, put your Cortecs model IDs into `config/opencode/opencode.json` (guide sections 5.3 and 8). The Kilo settings are in guide section 10; they are not stored in this repo because they sit in your user config folder.

## Daily use

```powershell
# Windows
pwsh scripts/agent.ps1 <project>                 # interactive OpenCode
pwsh scripts/agent.ps1 <project> -Docs           # also start the docs proxy (domain allowlist)
pwsh scripts/agent.ps1 <project> -Shell          # bash in the same sandbox
pwsh scripts/agent.ps1 <project> -RestartGateway # after changing the key or the gateway template
pwsh scripts/agent.ps1 <project> run "fix the failing ctest"
```

```bash
# Linux
scripts/agent.sh <project>
scripts/agent.sh --docs <project>
scripts/agent.sh --shell <project>
scripts/agent.sh --restart-gateway <project>
scripts/agent.sh <project> run "fix the failing ctest"
```

Allow a website for docs mode (host only, the agent cannot do this):

```powershell
pwsh scripts/allow-site.ps1 doc.qt.io
pwsh scripts/allow-site.ps1 https://docs.example.org/a -Minutes 60
pwsh scripts/allow-site.ps1 -List
pwsh scripts/allow-site.ps1 docs.example.org -Remove
```

```bash
scripts/allow-site.sh doc.qt.io
scripts/allow-site.sh https://docs.example.org/a --minutes 60
scripts/allow-site.sh --list
scripts/allow-site.sh docs.example.org --remove
```

Domains where data could also be uploaded (code hosts, paste sites, cloud storage and so on) are refused unless you pass `-Force` (`--force` on Linux). See guide section 7.5.

## Repository layout

```
scripts/        launcher and helpers: agent, lib, set-key, sync-skills, allow-site, verify-sandbox
                  *.ps1 = Windows (PowerShell 7), *.sh = Linux (bash), same names and behaviour
                  verify-inside.sh is shared: it runs inside the container during verification
images/         agent/Containerfile, gateway nginx template, squid config and allowlist
config/         opencode config, global rules and agents (mounted read-only into the container)
skills/         your own skills (skills/my-skills/<name>/SKILL.md)
skills-manifest.txt   which upstream skills to install
GUIDE.md        the full guide
```

## Adding skills

- **Upstream skill:** add its path to `skills-manifest.txt`, run `sync-skills` (`.ps1` or `.sh`), then `/reload` in Kilo and restart OpenCode. Install a skill's dependencies together with it.
- **Your own skill:** create `skills/my-skills/<name>/SKILL.md` (the frontmatter `name` must equal the folder name) and run the sync script.

The sync script lists every embedded shell command and bundled script in the installed skills. Read that list. Pin the upstream clone to a commit you have reviewed.

## What this does not protect against

- Kilo Code in VS Code is not sandboxed. Keep its shell permission on `ask`.
- The gateway still sends your code to Cortecs. That is the product. Where it is processed is controlled by your Cortecs project settings (allowed providers, region, data retention), not by this setup.
- Allowing a domain with `allow-site` lets the agent reach it. Approve documentation sites only.
- The agent can create folders such as `.vscode` in your project if they don't exist yet. Keep VS Code Workspace Trust on and review new files before opening the project.
- Malicious code you build and run yourself, or skills you install on purpose.

## Status

- **Windows:** run end to end; the verification script passes 23/23, or 26/26 with `-Docs`.
- **Linux:** the bash scripts were tested inside the Podman machine's Linux (bash 5.3, rootless Podman) with the same results, but not yet on a standalone distribution or with SELinux enforcing. Guide section 14 lists what to confirm.

## Never commit

The Cortecs key and the Kilo key. The key lives only in a Podman secret and in your own secret store. Do not put it in `kilo.jsonc` or `opencode.json`.
