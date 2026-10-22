# AI Workstation Guide (Windows and Linux): sandboxed OpenCode + Kilo Code + shared skills

Audience: one C++/Qt developer (photogrammetry desktop software) on Windows 11 or Linux, with a Cortecs subscription.
Status: Windows was run end to end (the verification script passes 23/23, or 26/26 with `-Docs`). The Linux bash scripts were tested inside the Podman machine's Linux but not yet on a standalone distribution; section 3L and section 14 list what to check there.

**Source of truth:** the files in this repository (`scripts/`, `images/`, `config/`). The listings in this guide explain them and may lag behind. If a listing and a file differ, trust the file.

**Two script sets, one design.** Windows uses PowerShell 7 scripts (`scripts/*.ps1`, run with `pwsh`). Linux uses bash scripts (`scripts/*.sh`, run with `bash`) and needs no PowerShell. They do the same job with the same names:

| Job                          | Windows (`pwsh scripts/...`)         | Linux (`bash scripts/...`)         |
| ---------------------------- | ------------------------------------ | ---------------------------------- |
| Shared helpers               | `lib.ps1`                            | `lib.sh`                           |
| Start the agent              | `agent.ps1 <project> [-Docs] [-Shell] [-RestartGateway]` | `agent.sh [--docs] [--shell] [--restart-gateway] <project>` |
| Store the Cortecs key        | `set-key.ps1`                        | `set-key.sh`                       |
| Install skills               | `sync-skills.ps1 [-DryRun] [-Upstream]` | `sync-skills.sh [--dry-run] [--upstream]` |
| Allow a website              | `allow-site.ps1`                     | `allow-site.sh`                    |
| Verify the sandbox           | `verify-sandbox.ps1 <project> [-Docs]` | `verify-sandbox.sh [--docs] <project>` |

`verify-inside.sh`, the images, and `config/` are shared. If you change behaviour in one script set, change the other. The `.ps1` files still contain a few Linux branches from an earlier attempt; on Linux use the `.sh` set, which is the one that is tested there.

**Paths in this guide.** Windows paths are shown as `C:\git\ai-workstation\...`. On Linux use the same layout under your home, for example `~/git/ai-workstation/...`. Examples show the PowerShell form; for Linux use the `.sh` equivalent from the table. The bash scripts are in the repository and are not listed in this guide.

---

## 0. What you will end up with

| Piece              | Where it runs                                                    | What it can reach                                   | Purpose                                         |
| ------------------ | ---------------------------------------------------------------- | --------------------------------------------------- | ----------------------------------------------- |
| OpenCode agent     | Podman container (rootless; WSL2 on Windows, native on Linux), tuned for Linux C++/Qt builds | Only the `llm-gateway` sidecar; no internet, no DNS | Autonomous / agentic work                       |
| `llm-gateway`      | Podman container (nginx)                                         | Only `api.cortecs.ai` (allowlisted paths)           | Holds the API key and forwards allowed requests |
| `squid` (optional) | Podman container                                                 | A short HTTPS domain allowlist                      | Opt-in docs lookup (`-Docs` switch)             |
| Kilo Code          | VS Code on the host (not sandboxed on Windows; see section 10)   | Cortecs directly                                    | Direct prompting, interactive work              |
| Shared skills      | `~/.agents/skills` (`C:\Users\Nejc\.agents\skills` on Windows)   | n/a                                                 | One skills folder read by both tools            |

Two deviations from the earlier proposal, made after more research:

1. **No `compose.yaml`.** `podman compose` on Windows needs an extra provider (docker-compose or podman-compose) and its Windows path and network-flag handling is fragile. A PowerShell 7 launcher on Windows (and a bash launcher on Linux) using plain `podman run` has fewer moving parts and gives exact control over the network flags that matter (`--internal`, `--disable-dns`, `--dns=none`, static IPs).
2. **Skills are copied, not junctioned.** A script mirrors the curated skills into `~\.agents\skills`. Real folders work for both tools and for the container bind mount. Junctions on `C:\` seen through WSL2 are a possible source of silent failures.

---

## 1. Threat model: what each layer does and does not do

Risks you named: an agent (or a hallucinating model) sends your code to an unknown server.

| Layer                                                                            | Stops                                                                                                                                        | Does not stop                                                |
| -------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| Internal Podman network (no gateway, no DNS)                                     | Any outbound connection from agent processes: `curl`, `git push`, `pip install`, DNS tunnelling, a model writing a script that uploads files | Nothing leaves except through the gateway                    |
| `llm-gateway` path allowlist                                                     | The agent using the gateway as a general proxy (only `/v1/responses`, `/chat/completions`, `/models`, `/messages`)                           | The agent sending your code to Cortecs. That is the product. |
| Key held by gateway                                                              | The agent reading or leaking your API key                                                                                                    | A compromised gateway container                              |
| Cortecs project settings (`allowed_providers`, `eu_native`, zero data retention) | Requests being routed to inference providers you did not approve                                                                             | Anything not configured in your Cortecs project              |
| Read-only overlays on `.git/hooks`, `.git/config`, `.vscode`                     | The agent planting something that runs later on your Windows host                                                                            | Malicious source code you later build and run yourself       |
| Read-only skills mount                                                           | The agent editing its own skills                                                                                                             | Malicious skills you install on purpose (see section 4.5)    |
| Dropped capabilities, read-only rootfs, non-root                                 | Container breakout via common routes                                                                                                         | Kernel zero-days (the VM boundary is WSL2)                   |

Important limits:

- **Kilo Code in VS Code is not sandboxed.** Kilo's own sandbox is not supported on Windows; on Linux you can enable it (check Kilo's docs for your version, it is not part of this setup). Treat it as a trusted-but-reviewed tool: keep `bash` on `ask`, deny `webfetch`/`websearch`, and use OpenCode for autonomous runs.
- **Protected folders only exist if they already exist.** The read-only overlays cover `.vscode`, `.devcontainer`, `.husky` and `.githooks` only when the folder is already in your project. If it does not exist, the agent can create it (for example `.vscode/tasks.json` that runs on folder open). Keep VS Code **Workspace Trust** on, and check `git status` for new files in those folders before opening a project the agent has worked on. Alternatively create the empty folders yourself, since the overlay will then protect them.
- **The model choice and the network are different controls.** The sandbox protects against what the agent's tools do. Cortecs routing settings protect against where inference runs.
- **Permission rules inside OpenCode are a speed bump.** The container network is the real enforcement.

---

## 2. Final folder layout

Create this repo. It holds everything except the Cortecs key.

```
C:\git\ai-workstation\
  GUIDE.md                        (this file)
  .editorconfig
  .gitattributes
  .vscode\settings.json
  skills-manifest.txt
  images\
    agent\Containerfile             (exactly this capitalisation: Linux file names are case-sensitive)
    gateway\default.conf.template
    squid\squid.conf
    squid\allowlist.txt
    squid\allowlist.expiry[.json]   (created by allow-site; git-ignored)
  config\
    opencode\opencode.json
    opencode\AGENTS.md
    opencode\agents\review.md
    kilo\kilo.jsonc
  scripts\
    lib.ps1
    agent.ps1
    set-key.ps1
    sync-skills.ps1
    allow-site.ps1
    verify-sandbox.ps1
    lib.sh                          (Linux counterparts of the .ps1 files)
    agent.sh
    set-key.sh
    sync-skills.sh
    allow-site.sh
    verify-sandbox.sh
    verify-inside.sh                (shared: runs inside the container)
  .gitignore
  skills\my-skills\...            (your own skills)

C:\git\mattpocock-ai-skills\      (git clone of mattpocock/skills, pinned; any path works, see section 4.4)
C:\Users\Nejc\.agents\skills\     (generated; the one folder both tools read)
C:\Users\Nejc\.config\kilo\kilo.jsonc   (copied from config\kilo)
```

On Linux the same things live at `~/git/ai-workstation/`, `~/git/mattpocock-ai-skills/`, `~/.agents/skills/` and `~/.config/kilo/kilo.jsonc`.

---

## 3. Prerequisites and setup

Windows: follow 3.1 to 3.5. Linux: skip to 3L (then do 3.5, which applies to both).

### 3.1 Install tools

```powershell
winget install --id Microsoft.PowerShell -e
winget install --id Git.Git -e
winget install --id RedHat.Podman -e
winget install --id RedHat.Podman-Desktop -e
winget install --id OpenJS.NodeJS.LTS -e      # only needed for optional "npx skills" use
```

Open a new **PowerShell 7** window (`pwsh`). All scripts require PowerShell 7, not Windows PowerShell 5.1, because of how native-command stderr is handled.

### 3.2 Limit WSL2 resources (shared by all WSL distros)

Create `C:\Users\Nejc\.wslconfig`. Adjust to your hardware. Qt/C++ builds want RAM.

```ini
[wsl2]
memory=20GB
processors=8
swap=8GB
```

### 3.3 Create the Podman machine (rootless)

```powershell
wsl --update
podman machine init --disk-size 150
podman machine start
podman info --format '{{.Host.Security.Rootless}}'
```

Expected output of the last command: `true`. If it prints `false`, you created a rootful machine; run `podman machine rm` and re-init without `--rootful`.

Notes:

- `podman machine init --cpus/--memory` is ignored on the WSL provider. `.wslconfig` is what limits the whole VM.
- Per-container limits (`--memory`, `--pids-limit`, `--cpus`) only work if the cgroup controllers are delegated to the rootless user, which is not the default. The scripts skip any limit whose controller is missing. See the troubleshooting table to enable them.
- `--disk-size` is only the maximum size of the virtual disk.

### 3.4 Smoke tests (do these before anything else)

```powershell
# 1) Normal containers have internet (needed later for image builds)
podman run --rm docker.io/library/alpine:3.20 wget -qO- https://example.com | Select-Object -First 3

# 2) Windows folders can be bind-mounted
mkdir C:\temp\mnt-test -Force; "hello" | Set-Content C:\temp\mnt-test\a.txt
podman run --rm -v C:\temp\mnt-test:/w:ro docker.io/library/alpine:3.20 cat /w/a.txt
```

If (1) fails, see section 13 (WSL2 networking). Do not continue until both work.

### 3.5 Repository hygiene files

Create these first so every file you copy later is saved with Linux line endings. Containerfile, `.sh` and nginx templates break with CRLF.

`C:\git\ai-workstation\.editorconfig`

```ini
root = true

[*]
end_of_line = lf
insert_final_newline = true
charset = utf-8
```

All files, including `.ps1`, use LF. PowerShell 7 reads LF on Windows without problems, and one convention works on both systems.

`C:\git\ai-workstation\.gitattributes`

```
* text=auto
*.sh text eol=lf
*.template text eol=lf
Containerfile text eol=lf
*.conf text eol=lf
*.ps1 text eol=lf
*.json text eol=lf
*.md text eol=lf
```

Also create `C:\git\ai-workstation\.gitignore`:

```
# Host-only state of scripts/allow-site.ps1 (temporary allowlist entries)
images/squid/allowlist.expiry.json

*.log
```

`C:\git\ai-workstation\.vscode\settings.json`

```json
{
  "files.eol": "\n"
}
```

Initialize the repo:

```powershell
cd C:\git\ai-workstation
git init
```

Commit messages in your repos follow your rule: the text only completes "This commit will ...". Do not write those three words; append `[task-number]` if you have one.

---

## 3L. Linux setup (replaces 3.1 to 3.4)

Not run by the author yet. The containers, networks and scripts are the same as on Windows; only the host preparation differs. There is no Podman machine, no WSL2 and no `.wslconfig`: Podman runs directly on your kernel.

### 3L.1 Install tools

Debian or Ubuntu:

```bash
sudo apt install podman uidmap passt netavark aardvark-dns git
```

Fedora or RHEL:

```bash
sudo dnf install podman netavark aardvark-dns git
```

No PowerShell is needed on Linux: the scripts are bash (bash 4 or newer, which every current distribution has). Netavark and aardvark-dns are required: `--internal` together with `--disable-dns` is implemented by the netavark network backend.

Clone this repo, then make the scripts executable once (or just run them as `bash scripts/<name>.sh`):

```bash
chmod +x scripts/*.sh
```

### 3L.2 Check rootless Podman

```bash
podman info --format 'rootless={{.Host.Security.Rootless}} network={{.Host.NetworkBackend}} cgroups={{.Host.CgroupVersion}} controllers={{.Host.CgroupControllers}}'
grep "$USER" /etc/subuid /etc/subgid
```

Expected: `rootless=true`, `network=netavark`, `cgroups=v2`. If `network=cni`, install netavark and aardvark-dns, then run `podman system reset` (this deletes all containers and images). If the `grep` prints nothing, add subordinate IDs and migrate:

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate
```

### 3L.3 Resource limits (optional)

`controllers=` should list `cpu memory pids`. Most systemd distributions delegate `memory` and `pids` to users but not always `cpu`. The scripts skip any limit whose controller is missing and print a warning. To delegate all of them:

```bash
sudo mkdir -p /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
sudo systemctl daemon-reload
```

Then log out and back in (or reboot) and check `controllers=` again. Unlike on Windows, `.wslconfig` is not involved: nothing else caps the memory the agent can use, so the limits matter more here.

### 3L.4 SELinux (Fedora, RHEL)

If `getenforce` prints `Enforcing`, bind mounts need an SELinux label or the container gets "permission denied". The scripts detect this and add `,z` to every bind mount. That relabels the mounted host paths (the workspace, `~/.agents/skills`, and the files in this repo) so containers can read them. It is harmless for those paths, but never mount a whole home directory this way.

### 3L.5 Smoke tests

```bash
podman run --rm docker.io/library/alpine:3.20 wget -qO- https://example.com | head -3
mkdir -p /tmp/mnt-test && echo hello > /tmp/mnt-test/a.txt
podman run --rm -v /tmp/mnt-test:/w:ro,z docker.io/library/alpine:3.20 cat /w/a.txt
```

Both must work before you continue.

### 3L.6 Differences to be aware of

- **User ID.** The scripts use `--userns=keep-id:uid=1000,gid=1000`. Your host user, whatever its UID, appears as uid 1000 inside the container, so files in your workspace stay owned by you. Nothing to configure.
- **Commands.** Use the `.sh` scripts from the table at the top. Example: `bash scripts/agent.sh --docs ~/git/myproject`. Where this guide shows `pwsh scripts/x.ps1 -Switch`, the Linux form is `bash scripts/x.sh --switch`.
- **Build speed.** Bind mounts are native, so builds are much faster than from `C:\` through WSL2.
- **Line endings and file names.** Linux file names are case-sensitive. The image file must be called `Containerfile`.
- **Kilo Code.** On Linux, Kilo's own sandbox can be used (section 10).

---

## 4. Shared global skills (OpenCode and Kilo from one folder)

### 4.1 How the sharing works

Both tools scan `~/.agents/skills/<skill-name>/SKILL.md` by default, with no configuration. On your machine this is `C:\Users\Nejc\.agents\skills`.

- OpenCode: reads `~/.agents/skills` (documented under "Global agent-compatible").
- Kilo: reads `~/.agents/skills` ("loaded by default").
- Rules shared by both: `SKILL.md` must have `name` (matches the directory name, lowercase letters, digits and hyphens) and `description` (at most 1024 characters).
- Skill metadata (name and description) goes into the prompt every session. Fewer, sharper skills means fewer tokens.

The container gets the same folder mounted read-only at `/home/agent/.agents/skills`.

### 4.2 Pin the upstream skills repo

```powershell
git clone https://github.com/mattpocock/skills C:\git\mattpocock-ai-skills   # Linux: ~/git/mattpocock-ai-skills
cd C:\git\mattpocock-ai-skills
git rev-parse HEAD        # write this commit hash into your notes; you update it deliberately  
5beb35b040e3de97e54fa9e386d7e42d15c295c2
```

Layout of upstream (as of research): `skills/engineering/*`, `skills/productivity/*`, plus `skills/misc`, `skills/in-progress`, `skills/deprecated` which you will not install.

Facts found during research that shape the selection:

- Many skills are thin wrappers that tell the agent to "Call the Skill tool" for another skill. `grill-me` needs `grilling`. `grill-with-docs` needs `grilling` and `domain-modeling`. **Install dependencies together**, otherwise the wrapper points at nothing.
- User-invoked skills carry `disable-model-invocation: true` in frontmatter. That is a Claude Code field. OpenCode and Kilo document a different mechanism (`metadata: opencode/autoinvoke: "false"`). Expect these skills may also be auto-suggested to the model in your tools. That costs a few tokens, not safety. Test in section 4.6.
- Skills like `code-review` expect an "issue tracker" doc created by `/setup-matt-pocock-skills`. In a no-network sandbox choose **local files** as the tracker.
- Skills that need web access or GitHub (`research`, `triage`, `pr`, `wayfinder`) are excluded from the starter set because they cannot work in the sandbox.

### 4.3 The manifest (the only file you edit to add or remove upstream skills)

`C:\git\ai-workstation\skills-manifest.txt`

```
# Path under skills/ in mattpocock/skills, one per line.

# --- Core (phase 1) ---
productivity/grilling
productivity/grill-me
productivity/handoff
productivity/writing-for-agents
productivity/wait-what
engineering/domain-modeling
engineering/grill-with-docs
engineering/tdd
engineering/diagnosing-bugs
engineering/code-review
engineering/codebase-design
engineering/improve-codebase-architecture
engineering/retro
engineering/setup-matt-pocock-skills

# --- Phase 2: enable after you set the tracker to "local files" ---
# engineering/to-spec
# engineering/to-tickets
# engineering/implement
# engineering/implement-spec
```

### 4.4 The sync script

`C:\git\ai-workstation\scripts\sync-skills.ps1`

```powershell
#requires -Version 7
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Upstream   # clone of mattpocock/skills; default: $env:AI_SKILLS_UPSTREAM, else a per-OS path below
)

$ErrorActionPreference = 'Stop'
$Repo      = Split-Path -Parent $PSScriptRoot
if (-not $Upstream) {
    $Upstream = if ($env:AI_SKILLS_UPSTREAM) { $env:AI_SKILLS_UPSTREAM }
                elseif ($IsWindows)          { 'C:\git\mattpocock-ai-skills' }
                else                         { Join-Path $HOME 'git/mattpocock-ai-skills' }
}
$Target    = Join-Path $HOME '.agents/skills'
$Manifest  = Join-Path $Repo 'skills-manifest.txt'
$Mine      = Join-Path $Repo 'skills/my-skills'
$Marker    = '.managed-by-ai-workstation'

function Get-SkillName([string]$dir) {
    $m = Get-Content (Join-Path $dir 'SKILL.md') -TotalCount 20 |
         Select-String -Pattern '^name:\s*(.+)$' | Select-Object -First 1
    if (-not $m) { throw "No 'name:' in frontmatter of $(Join-Path $dir 'SKILL.md')" }
    return $m.Matches[0].Groups[1].Value.Trim().Trim('"', "'")
}

# 1. Desired set: leaf-name -> source dir
$want = [ordered]@{}
Get-Content $Manifest |
    ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
    Where-Object { $_ } |
    ForEach-Object {
        $src = Join-Path (Join-Path $Upstream 'skills') $_
        if (-not (Test-Path (Join-Path $src 'SKILL.md'))) { throw "Missing upstream skill: $_" }
        $want[(Split-Path -Leaf $src)] = $src
    }

if (Test-Path $Mine) {
    Get-ChildItem $Mine -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } |
        ForEach-Object { $want[$_.Name] = $_.FullName }
}

# 2. Validate: frontmatter name must equal directory name (Kilo requires it)
foreach ($k in $want.Keys) {
    $n = Get-SkillName $want[$k]
    if ($n -ne $k) { throw "Skill '$k': frontmatter name is '$n' (must match folder)" }
}

Write-Host "Upstream commit: $(git -C $Upstream rev-parse --short HEAD)"
Write-Host "Skills to install ($($want.Count)): $($want.Keys -join ', ')"
if ($DryRun) { return }

# 3. Mirror each wanted skill (works the same on Windows and Linux)
function Copy-Skill([string]$From, [string]$To) {   # skips folders named 'agents' or '.git' at any depth
    if (Test-Path -LiteralPath $To) { Remove-Item -LiteralPath $To -Recurse -Force }
    New-Item -ItemType Directory -Force $To | Out-Null
    $root = (Resolve-Path -LiteralPath $From).Path
    Get-ChildItem -LiteralPath $root -Recurse -Force -File | ForEach-Object {
        $rel = [IO.Path]::GetRelativePath($root, $_.FullName)
        if ($rel -split '[\\/]' | Select-Object -SkipLast 1 | Where-Object { $_ -in 'agents', '.git' }) { return }
        $dest = Join-Path $To $rel
        New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
    }
}

New-Item -ItemType Directory -Force $Target | Out-Null
foreach ($k in $want.Keys) {
    $dst = Join-Path $Target $k
    Copy-Skill $want[$k] $dst
    New-Item -ItemType File -Force (Join-Path $dst $Marker) | Out-Null
}

# 4. Remove stale skills that this script installed earlier (never touches skills you added by hand)
Get-ChildItem $Target -Directory | Where-Object {
    (Test-Path (Join-Path $_.FullName $Marker)) -and -not $want.Contains($_.Name)
} | ForEach-Object { Write-Host "Removing stale: $($_.Name)"; Remove-Item $_.FullName -Recurse -Force }

# 5. Security report: anything executable inside the installed skills
Write-Host "`n--- Embedded shell commands in SKILL.md (Kilo runs these for trusted global skills) ---"
Get-ChildItem $Target -Recurse -Filter SKILL.md |
    Select-String -Pattern '!`' | ForEach-Object { "{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim() }
Write-Host "`n--- Script files bundled with skills ---"
Get-ChildItem $Target -Recurse -Include *.sh, *.ps1, *.py, *.js, *.mjs, *.cjs, *.bat, *.cmd |
    ForEach-Object { $_.FullName }
Write-Host "`nDone. Review anything listed above before trusting it."
```

Run it:

```powershell
cd C:\git\ai-workstation          # Linux: cd ~/git/ai-workstation
pwsh ./scripts/sync-skills.ps1 -DryRun
pwsh ./scripts/sync-skills.ps1
```

On Linux:

```bash
cd ~/git/ai-workstation
bash scripts/sync-skills.sh --dry-run
bash scripts/sync-skills.sh
```

The upstream clone is found in this order: the `-Upstream <path>` / `--upstream <path>` option, the `AI_SKILLS_UPSTREAM` environment variable, then the per-OS default (`C:\git\mattpocock-ai-skills` on Windows, `~/git/mattpocock-ai-skills` on Linux). Both scripts do the same: copy each skill folder (skipping any `agents` and `.git` subfolders) into `~/.agents/skills`, mark it as managed, remove stale managed skills, and list embedded commands and bundled scripts.

### 4.5 Supply-chain rules for skills

Skills are instructions that agents follow, and some can contain shell commands.

1. Update upstream deliberately: `git -C <upstream-clone> pull`, then read `git diff <old-hash>..HEAD -- skills` before running `sync-skills.ps1`.
2. The sync script prints every `` !`command` `` line and every bundled script. Read them. Upstream currently ships `skills/engineering/wizard/template.sh` and `skills/engineering/diagnosing-bugs/scripts/hitl-loop.template.sh`; only the second is in your starter set.
3. Kilo only: to disable embedded command execution globally, set a user environment variable and restart VS Code:
   ```powershell
   # Windows
   [Environment]::SetEnvironmentVariable('KILO_DISABLE_SKILL_SHELL', '1', 'User')
   ```
   ```bash
   # Linux: add to ~/.profile, then log out and in
   export KILO_DISABLE_SKILL_SHELL=1
   ```
4. In the container the skills folder is mounted read-only, so an agent cannot modify skills.
5. Pin by commit. Never auto-update (`npx skills@latest update` and plugin auto-update are not used here).

### 4.6 Verify both tools see the skills

- OpenCode: in the container (section 9), ask: `List the skills you have available.` Then try `use the tdd skill`.
- Kilo: in VS Code open a chat and ask: `What skills do you have available?` If you added skills after Kilo started, run `/reload`.
- If a skill is missing in one tool, the usual causes are: frontmatter `name` does not match the folder, `SKILL.md` is not directly under the skill folder, or the tool rejects an unknown frontmatter field. Compare with a skill that loads.

### 4.7 Your own skills (the repo you will extend)

Put them in `C:\git\ai-workstation\skills\my-skills\<name>\SKILL.md`. They are synced automatically. Template for a C++/Qt example:

`skills\my-skills\qt-cmake-build\SKILL.md`

```markdown
---
name: qt-cmake-build
description: Configure, build and test this Qt/CMake project inside the Linux container. Use when asked to build, run tests, fix compile errors or check that a change compiles.
---

# Build and test (Linux container)

1. Build directory is always `/cache/build/$PROJECT_NAME`. Never create build output in `/workspace`.
2. Configure once:
   cmake -S /workspace -B /cache/build/$PROJECT_NAME -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
3. Build: `cmake --build /cache/build/$PROJECT_NAME -j`
4. Test: `ctest --test-dir /cache/build/$PROJECT_NAME --output-on-failure -j`
   Qt GUI tests run headless (`QT_QPA_PLATFORM=offscreen` is preset).
5. When output is long, show only the first error and its context; do not paste whole logs.
6. Windows-only code (MSVC, WinAPI) does not build here. Report that instead of changing it.
```

Skill-authoring checklist: one job per skill; the description says when to use it in the words you would type; the body is short and links to reference files for detail; no secrets; no network commands.

---

## 5. Cortecs setup

### 5.1 Keys

- Create **one key for OpenCode** and **one key for Kilo** in the Cortecs console, with separate budgets. A leak or a runaway loop in one tool then does not affect the other.
- Base URL for everything: `https://api.cortecs.ai/v1`.
- Cortecs supports `/responses` (preferred for agents), `/chat/completions` (broad compatibility) and `/messages`. The gateway allows all three.

### 5.2 Project-level privacy and routing settings

Cortecs applies the settings of the project that owns the API key. In the console, for the project used by the OpenCode key (and ideally the Kilo key), review and set:

- Allowed providers: only the inference providers you accept.
- EU-native / region restriction, if you need it.
- Zero data retention, if you need it.
- Monthly budget.

These settings decide where your code is processed. The container network only controls what the agent's tools can reach.

### 5.3 Choose models (and list the exact IDs)

Use the exact IDs returned by the Models API. Use any shell with your key available once:

```powershell
$k = Read-Host "Cortecs key" -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($k))
Invoke-RestMethod https://api.cortecs.ai/v1/models -Headers @{ Authorization = "Bearer $plain" } |
    Select-Object -ExpandProperty data | Select-Object id | Format-Table -AutoSize
Remove-Variable plain, k
```

Requirements for a coding agent: tool/function calling support, enough context (at least 128k preferred), and acceptable provider list. Pick one main model and one cheaper small model (used for titles and summaries). Write the IDs down; you need them in sections 8 and 10 where the placeholders `<MODEL_ID>` and `<SMALL_MODEL_ID>` appear.

### 5.4 Store the OpenCode key in Podman (not in a file, not in the agent)

`C:\git\ai-workstation\scripts\set-key.ps1`

```powershell
#requires -Version 7
[CmdletBinding()]
param([switch]$Prompt)   # always ask for the key instead of reading it from SecretStore
$ErrorActionPreference = 'Stop'

# Key source: SecretStore (secret name CortecsKey) when available, otherwise a hidden prompt.
$secure = $null
if (-not $Prompt -and (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
    try { $secure = Get-Secret -Name CortecsKey -ErrorAction Stop }
    catch { Write-Warning "No SecretStore entry 'CortecsKey' ($($_.Exception.Message)). Asking instead." }
}
if ($null -eq $secure) { $secure = Read-Host 'Cortecs API key for OpenCode' -AsSecureString }

$plain = if ($secure -is [securestring]) { (ConvertFrom-SecureString $secure -AsPlainText).Trim() } else { "$secure".Trim() }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ck-' + [guid]::NewGuid().ToString('N'))
try {
    # Create the file first and restrict it (Linux/macOS) before the key is written.
    New-Item -ItemType File -Path $tmp | Out-Null
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($tmp, [IO.UnixFileMode]'UserRead, UserWrite') }
    # No trailing newline: it would end up inside the Authorization header.
    [IO.File]::WriteAllText($tmp, $plain)
    podman secret create --replace cortecs_key $tmp
    if ($LASTEXITCODE -ne 0) { throw 'podman secret create failed' }
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    Remove-Variable plain, secure -ErrorAction SilentlyContinue
}
Write-Host 'Secret cortecs_key stored in Podman.'
```

On Linux use `bash scripts/set-key.sh` instead. It asks for the key with hidden input, or reads it from standard input with `--stdin` (for example `pass show cortecs | bash scripts/set-key.sh --stdin`). It passes the key to Podman through a pipe, so no temporary file is written.

Without the optional SecretStore module (Windows script) it just prompts. With `Microsoft.PowerShell.SecretManagement` and `SecretStore` installed and a secret named `CortecsKey`, it reads from there; `-Prompt` forces the prompt.

```powershell
pwsh C:\git\ai-workstation\scripts\set-key.ps1
podman secret ls
```

The key is stored unencrypted in Podman's own storage (a file driver; inside the Podman machine on Windows, under `~/.local/share/containers` on Linux). That is the same trust level as your user profile. The agent container never receives it: only the gateway container does.

Kilo's key is entered in the Kilo UI or environment (section 10).

---

## 6. Container images

### 6.1 Choose versions first

```powershell
npm view opencode-ai version          # the version you will pin below
```

Cortecs' own docs reference an `opencode.ai/v2` installer, and v2 has some config differences (for example, the `openTelemetry` option is gone). Read the release notes of the version you pin, and use that version's docs for config keys. The guide assumes the npm package `opencode-ai`.

Also decide your **Qt version**. Ubuntu 24.04 apt gives Qt 6.4.x. If your product needs a different Qt (Qt 5, or Qt 6.5+), use the aqtinstall block in the Containerfile.

### 6.2 Agent image

`C:\git\ai-workstation\images\agent\Containerfile`

```dockerfile
# syntax=docker/dockerfile:1
ARG UBUNTU_TAG=24.04
ARG NODE_TAG=22-bookworm-slim

# ---- stage 1: fetch a pinned OpenCode (build time has internet; runtime will not) ----
FROM docker.io/library/node:${NODE_TAG} AS opencode
ARG OPENCODE_VERSION
RUN test -n "$OPENCODE_VERSION" \
 && npm install -g --prefix /opt/opencode "@opencode/cli@${OPENCODE_VERSION}"

# ---- stage 2: the runtime image ----
FROM docker.io/library/ubuntu:${UBUNTU_TAG}
ENV DEBIAN_FRONTEND=noninteractive

# Adapt the last line to your project's dependencies (examples for openMVG-style projects).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git ripgrep jq less file procps unzip zip python3 python3-venv \
      build-essential clang clangd clang-format clang-tidy cmake ninja-build ccache gdb pkg-config \
      xvfb xauth libgl1-mesa-dev libglu1-mesa-dev libxkbcommon-dev libxkbcommon-x11-0 \
      libeigen3-dev libceres-dev libopencv-dev libboost-dev libpng-dev libjpeg-dev libtiff-dev \
 && rm -rf /var/lib/apt/lists/*

# Qt is not taken from apt (noble ships Qt6 only); install the exact version at build time.
ARG QT_VERSION=5.15.2
RUN python3 -m venv /opt/aqt && /opt/aqt/bin/pip install aqtinstall \
 && /opt/aqt/bin/aqt install-qt linux desktop ${QT_VERSION} linux_gcc_64 -O /opt/Qt
ENV CMAKE_PREFIX_PATH=/opt/Qt/${QT_VERSION}/gcc_64

COPY --from=opencode /opt/opencode /opt/opencode
COPY --from=opencode /usr/local/bin/node /usr/local/bin/node
ENV PATH=/opt/opencode/bin:${PATH}

# Non-root user with uid 1000 (--userns=keep-id in lib.ps1 maps the host user to this uid)
RUN userdel -r ubuntu 2>/dev/null || true \
 && useradd -m -u 1000 -s /bin/bash agent \
 && mkdir -p /workspace /cache /etc/opencode \
 && chown agent:agent /workspace /cache

# Git behaves well on bind-mounted Windows folders and cannot run repo hooks.
RUN git config --system --add safe.directory '*' \
 && git config --system core.filemode false \
 && git config --system core.hooksPath /nonexistent \
 && git config --system user.name "ai-agent" \
 && git config --system user.email "ai-agent@localhost"

# IMPORTANT: do NOT set OPENCODE_DISABLE_CLAUDE_CODE. In current OpenCode flags it also disables
# "external skills", which includes ~/.agents/skills.
ENV HOME=/home/agent \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_MODELS_FETCH=1 \
    OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
    OPENCODE_DISABLE_DEFAULT_PLUGINS=1 \
    OPENCODE_CONFIG=/etc/opencode/opencode.json \
    CCACHE_DIR=/cache/ccache \
    CMAKE_GENERATOR=Ninja \
    CMAKE_C_COMPILER_LAUNCHER=ccache \
    CMAKE_CXX_COMPILER_LAUNCHER=ccache \
    QT_QPA_PLATFORM=offscreen

USER agent
WORKDIR /workspace
CMD ["opencode"]
```

Build (replace the version):

```powershell
cd C:\git\ai-workstation
podman build -t localhost/ai-agent:latest --build-arg OPENCODE_VERSION=1.2.3 images\agent
podman run --rm localhost/ai-agent:latest opencode --version
```

Build runs with normal internet access. That is intentional: all downloads happen at build time.

### 6.3 Gateway image (nginx template)

The gateway is the only thing that can talk to Cortecs. Create `images\gateway\default.conf.template`:

```nginx
# envsubst substitutes ONLY ${CORTECS_*} (see NGINX_ENVSUBST_FILTER in lib.ps1).
log_format gw '$time_iso8601 $request_method $uri $status req=$request_length resp=$bytes_sent t=$request_time';

server {
    listen 8080;
    server_name _;
    access_log /dev/stdout gw;
    error_log  /dev/stderr warn;

    # DNS of the egress network (aardvark-dns, gateway IP of agent-egress). Re-resolves api.cortecs.ai.
    resolver 10.89.78.1 valid=30s ipv6=off;
    client_max_body_size 64m;

    location = /healthz { return 200 "ok\n"; }

    # Only the Cortecs API paths an agent needs. Only GET and POST.
    location ~ ^/v1/(responses|chat/completions|models|messages)(/.*)?$ {
        limit_except GET POST { deny all; }

        set $upstream https://api.cortecs.ai;
        proxy_pass $upstream;

        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host api.cortecs.ai;
        proxy_set_header Authorization "Bearer ${CORTECS_API_KEY}";

        proxy_ssl_server_name on;
        proxy_ssl_name api.cortecs.ai;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 5;       # default is 1, too shallow for chains with 2+ intermediates
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;

        proxy_buffering off;            # streaming (SSE) responses
        proxy_request_buffering off;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }

    location / { return 403; }
}
```

The gateway logs only method, path, status and sizes (no bodies). View with `podman logs llm-gateway`. That log is your audit trail of what the agent sent to the LLM endpoint.

### 6.4 Optional Squid image config (only for `-Docs` mode)

`images\squid\allowlist.txt`: one domain per line; a leading dot also matches subdomains. Keep it tiny. Do not add `github.com` (it allows pushing).

```
.doc.qt.io
.cppreference.com
raw.githubusercontent.com
```

`images\squid\squid.conf`:

```
http_port 3128
acl allowed_domains dstdomain "/etc/squid/allowlist.txt"
acl Safe_ports port 443
acl SSL_ports port 443
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow CONNECT allowed_domains
http_access deny all

cache deny all
pinger_enable off
via off
forwarded_for delete
access_log stdio:/dev/stdout
cache_log /dev/stderr
pid_filename /tmp/squid.pid
```

Squid permits HTTPS tunnels only to allowlisted hosts, and only on port 443. It does not inspect traffic. An agent can still send arbitrary data to an allowlisted host over a tunnel. That is why the list must be tiny and read-only in nature, and why this mode is off by default.

---

## 7. Network design and the launcher

### 7.1 Networks

| Network                          | Created with               | Role                                                   |
| -------------------------------- | -------------------------- | ------------------------------------------------------ |
| `agent-internal` (10.89.77.0/24) | `--internal --disable-dns` | The agent lives here. No gateway, no route, no DNS.    |
| `agent-egress` (10.89.78.0/24)   | normal bridge              | Only the gateway and optional squid are attached here. |

The gateway is attached to both networks (static IP `10.89.77.10` on the internal one), so it is the only bridge. The agent addresses it as `llm-gateway` through an `--add-host` entry, so name resolution needs no DNS server at all.

### 7.2 Shared library

`C:\git\ai-workstation\scripts\lib.ps1`

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot    = Split-Path -Parent $PSScriptRoot
$script:AgentImage  = 'localhost/ai-agent:latest'
$script:GatewayImg  = 'docker.io/nginxinc/nginx-unprivileged:1.27-alpine'   # pin to a digest once verified
$script:SquidImg    = 'docker.io/ubuntu/squid:latest'                       # pin to a digest once verified
$script:NetInternal = 'agent-internal'
$script:NetEgress   = 'agent-egress'
$script:GatewayIp   = '10.89.77.10'
$script:SquidIp     = '10.89.77.11'
$script:Controllers = $null   # cgroup controllers delegated to rootless Podman (filled lazily)
$script:SeLinux     = $null   # $true when SELinux is enforcing (Linux only; filled lazily)

function Resolve-RepoPath([string]$Relative) {   # Relative uses '/' on every OS; the result uses the native separator
    return [IO.Path]::GetFullPath((Join-Path $script:RepoRoot $Relative))
}

function Get-BindArg([string]$Source, [string]$Target, [string]$Mode = 'ro') {   # value for podman -v
    if ($null -eq $script:SeLinux) {
        $script:SeLinux = $false
        if ($IsLinux -and (Get-Command getenforce -ErrorAction SilentlyContinue)) {
            $script:SeLinux = ((& getenforce) -eq 'Enforcing')
        }
    }
    $opts = if ($script:SeLinux) { "$Mode,z" } else { $Mode }   # ',z' relabels the host path for containers
    return "${Source}:${Target}:${opts}"
}

function Invoke-Podman {
    $global:LASTEXITCODE = 0
    & podman @args
    if ($LASTEXITCODE -ne 0) { throw "podman $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

function Test-Podman {   # true when the command succeeds; output is discarded
    & podman @args *> $null
    return ($LASTEXITCODE -eq 0)
}

function Assert-Machine {
    if (Test-Podman info) { return }
    if ($IsWindows -or $IsMacOS) {   # Podman runs inside a VM here
        Write-Host 'Starting Podman machine...'
        Invoke-Podman machine start
    } else {
        throw 'Podman is not usable. Run "podman info" to see why (see GUIDE.md section 3L).'
    }
}

function Get-LimitArgs {   # emits --pids-limit/--memory/--cpus only for cgroup controllers the machine delegates
    param([int]$PidsLimit, [string]$Memory, [double]$Cpus)
    if ($null -eq $script:Controllers) {
        $raw = (& podman info --format '{{range .Host.CgroupControllers}}{{.}} {{end}}') -join ' '
        $script:Controllers = @($raw -split '\s+' | Where-Object { $_ })
        $missing = @('pids', 'memory', 'cpu') | Where-Object { $_ -notin $script:Controllers }
        if ($missing) {
            Write-Warning "Cgroup controllers not delegated to rootless Podman: $($missing -join ', '). Those limits are skipped (see GUIDE.md, Troubleshooting)."
        }
    }
    $l = @()
    if ($PidsLimit -and 'pids'   -in $script:Controllers) { $l += @('--pids-limit', "$PidsLimit") }
    if ($Memory    -and 'memory' -in $script:Controllers) { $l += @('--memory', $Memory) }
    if ($Cpus      -and 'cpu'    -in $script:Controllers) { $l += @('--cpus', "$Cpus") }
    return $l
}

function Initialize-Networks {
    if (-not (Test-Podman network exists $script:NetInternal)) {
        Invoke-Podman network create --internal --disable-dns --subnet 10.89.77.0/24 $script:NetInternal | Out-Null
    }
    if (-not (Test-Podman network exists $script:NetEgress)) {
        Invoke-Podman network create --subnet 10.89.78.0/24 $script:NetEgress | Out-Null
    }
}

function Start-Gateway {
    param([switch]$Restart)
    if ($Restart) { Test-Podman rm -f llm-gateway | Out-Null }
    $running = & podman ps --filter 'name=^llm-gateway$' --format '{{.Names}}'
    if ($running) { return }
    Test-Podman rm -f llm-gateway | Out-Null

    if (-not (Test-Podman secret exists cortecs_key)) { throw 'Secret cortecs_key missing. Run scripts/set-key.ps1' }
    $tpl = Resolve-RepoPath 'images/gateway/default.conf.template'

    $limits = Get-LimitArgs -PidsLimit 256 -Memory '256m'
    Invoke-Podman run -d --name llm-gateway `
        --network "$($script:NetInternal):ip=$($script:GatewayIp)" --network $script:NetEgress `
        --read-only --tmpfs /tmp --tmpfs '/etc/nginx/conf.d:rw,mode=1777' `
        --cap-drop=all --security-opt no-new-privileges @limits `
        --secret 'cortecs_key,type=env,target=CORTECS_API_KEY' `
        -e 'NGINX_ENVSUBST_FILTER=^CORTECS_' `
        -v (Get-BindArg $tpl '/etc/nginx/templates/default.conf.template') `
        $script:GatewayImg | Out-Null

    for ($i = 0; $i -lt 20; $i++) {
        if (Test-Podman exec llm-gateway wget -q -O- http://127.0.0.1:8080/healthz) { return }
        Start-Sleep -Milliseconds 500
    }
    Invoke-Podman logs llm-gateway
    throw 'Gateway did not become healthy.'
}

function Start-Squid {
    $running = & podman ps --filter 'name=^egress-squid$' --format '{{.Names}}'
    if ($running) { return }
    Test-Podman rm -f egress-squid | Out-Null
    $conf  = Resolve-RepoPath 'images/squid/squid.conf'
    $allow = Resolve-RepoPath 'images/squid/allowlist.txt'
    $limits = Get-LimitArgs -PidsLimit 256 -Memory '512m'
    Invoke-Podman run -d --name egress-squid `
        --network "$($script:NetInternal):ip=$($script:SquidIp)" --network $script:NetEgress `
        --security-opt no-new-privileges @limits `
        -v (Get-BindArg $conf '/etc/squid/squid.conf') -v (Get-BindArg $allow '/etc/squid/allowlist.txt') `
        $script:SquidImg | Out-Null
}

function Get-AgentRunArgs {
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [switch]$Docs,
        [switch]$Interactive,
        [string]$Name
    )
    $proj = Split-Path -Leaf $Workspace
    $safe = $proj -replace '[^a-zA-Z0-9_.-]', '_'
    if (-not $Name) { $Name = "agent-$safe-$(Get-Random -Maximum 9999)" }

    $a = @('run', '--rm', '--init')
    if ($Interactive) { $a += '-it' }
    $a += @('--name', $Name, '--hostname', 'agent')

    # Identity and hardening
    $a += @('--userns=keep-id:uid=1000,gid=1000', '--user', '1000:1000',
            '--read-only', '--cap-drop=all', '--security-opt', 'no-new-privileges',
            '--tmpfs', '/tmp:rw,exec,size=2g')
    $a += Get-LimitArgs -PidsLimit 4096 -Memory '12g' -Cpus 6

    # Network: internal only, no DNS, gateway by static IP
    $a += @('--network', $script:NetInternal,
            '--add-host', "llm-gateway:$($script:GatewayIp)", '--dns=none')

    # Workspace (read-write) with protected sub-paths (read-only overlays)
    $a += @('-v', (Get-BindArg $Workspace '/workspace' 'rw'), '-w', '/workspace', '-e', "PROJECT_NAME=$safe")
    $git = Join-Path $Workspace '.git'
    if (Test-Path -LiteralPath $git -PathType Container) {
        foreach ($p in 'hooks', 'config') {
            $src = Join-Path $git $p
            if (Test-Path -LiteralPath $src) { $a += @('-v', (Get-BindArg $src "/workspace/.git/$p")) }
        }
    } else {
        Write-Warning '.git is not a directory (worktree or submodule?). Hooks and config are NOT protected.'
    }
    foreach ($d in '.vscode', '.devcontainer', '.husky', '.githooks') {
        $src = Join-Path $Workspace $d
        if (Test-Path -LiteralPath $src -PathType Container) { $a += @('-v', (Get-BindArg $src "/workspace/$d")) }
    }

    # Shared skills (read-only), config (read-only), state and build cache (named volumes)
    $skills = [IO.Path]::GetFullPath((Join-Path $HOME '.agents/skills'))
    if (-not (Test-Path -LiteralPath $skills)) { New-Item -ItemType Directory -Force $skills | Out-Null }
    $cfg    = Resolve-RepoPath 'config/opencode'
    $a += @('-v', (Get-BindArg $skills '/home/agent/.agents/skills'),
            '-v', (Get-BindArg $cfg '/etc/opencode'),
            '-v', 'agent-home:/home/agent',
            '-v', 'agent-cache:/cache')
    $agentsDir = Join-Path $cfg 'agents'
    if (Test-Path -LiteralPath $agentsDir -PathType Container) {
        $a += @('-v', (Get-BindArg $agentsDir '/home/agent/.config/opencode/agents'))
    }

    if ($Docs) {
        $px = "http://$($script:SquidIp):3128"
        $no = "llm-gateway,$($script:GatewayIp)"
        $a += @('-e', "HTTPS_PROXY=$px", '-e', "https_proxy=$px", '-e', "NO_PROXY=$no", '-e', "no_proxy=$no")
    }
    return $a
}
```

### 7.3 Daily launcher

`C:\git\ai-workstation\scripts\agent.ps1`

```powershell
#requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Workspace,
    [switch]$Docs,              # tier 1: also start squid with the docs allowlist
    [switch]$RestartGateway,    # re-resolve api.cortecs.ai / reload template
    [switch]$Shell,             # open bash instead of opencode
    [Parameter(ValueFromRemainingArguments)][string[]]$AgentArgs
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$ws = (Resolve-Path -LiteralPath $Workspace).Path
Assert-Machine
Initialize-Networks
Start-Gateway -Restart:$RestartGateway
if ($Docs) { Start-Squid }

$run = Get-AgentRunArgs -Workspace $ws -Docs:$Docs -Interactive
$cmd = if ($Shell) { @('bash') } else { @('opencode') + $AgentArgs }
& podman @run $script:AgentImage @cmd
```

Usage:

```powershell
pwsh C:\git\ai-workstation\scripts\agent.ps1 C:\git\myproject                 # interactive OpenCode (tier 0)
pwsh C:\git\ai-workstation\scripts\agent.ps1 C:\git\myproject -Docs           # allow the docs allowlist
pwsh C:\git\ai-workstation\scripts\agent.ps1 C:\git\myproject -Shell          # bash in the same sandbox
pwsh C:\git\ai-workstation\scripts\agent.ps1 C:\git\myproject run "fix the failing ctest"   # one-shot
```

Add a convenience alias in your PowerShell profile if you like:

```powershell
function agent { pwsh C:\git\ai-workstation\scripts\agent.ps1 @args }
```

On Linux, the same in `~/.bashrc`:

```bash
agent() { bash ~/git/ai-workstation/scripts/agent.sh "$@"; }   # usage: agent --docs ~/git/myproject
```

### 7.5 Allowing a website on the fly (`allow-site.ps1`)

In `-Docs` mode the agent reaches the web only through the Squid proxy, which allows just the domains in `images/squid/allowlist.txt`. Squid sees the file read-only, and so does the agent: only you can change it, on the host. `scripts/allow-site.ps1` edits the list and reloads Squid (`squid -k reconfigure`) without a restart or dropped connections.

```powershell
pwsh scripts/allow-site.ps1 doc.qt.io                              # permanent, includes subdomains
pwsh scripts/allow-site.ps1 https://docs.example.org/a -Minutes 60 # accepts a URL; expires in 60 minutes
pwsh scripts/allow-site.ps1 www.example.org -Exact                 # that exact host only
pwsh scripts/allow-site.ps1 docs.example.org -Remove
pwsh scripts/allow-site.ps1 -List
pwsh scripts/allow-site.ps1 -Prune                                 # drop expired entries
pwsh scripts/allow-site.ps1 a.org,b.org                            # several at once, comma separated
```

Linux (`allow-site.sh`, same behaviour, options in the usual style):

```bash
bash scripts/allow-site.sh doc.qt.io
bash scripts/allow-site.sh https://docs.example.org/a --minutes 60
bash scripts/allow-site.sh www.example.org --exact
bash scripts/allow-site.sh docs.example.org --remove
bash scripts/allow-site.sh --list
bash scripts/allow-site.sh --prune
bash scripts/allow-site.sh a.org,b.org --force      # --force overrides the upload-host refusal
```

Typical flow:

1. The model tries a site; Squid answers 403. The model should tell you the domain (the rule is in `config/opencode/AGENTS.md`).
2. You decide. If yes, run `allow-site.ps1` with the domain, preferably with `-Minutes`.
3. Tell the model to retry.

Behaviour and limits:

- It accepts only valid host names and reduces a URL to its host. Wildcards, IP addresses, ports and paths are rejected.
- It **refuses domains where the agent could also upload data**: code hosts (`github.com`, `gitlab.com`), paste sites, file and cloud-storage hosts, chat webhooks, tunnels and user-hosting platforms. `-Force` overrides this. Squid cannot see inside HTTPS, so it filters by domain only, not by method or path. If you allow such a host, the model can send data to it.
- A leading dot (the default) allows every subdomain; `-Exact` allows only the host you named.
- Temporary entries are stored in `images/squid/allowlist.expiry.json` (host only, never mounted into a container). Expiry is enforced **when the script runs**, not by a timer: an expired entry stays until you next run any `allow-site.ps1` command, including `-Prune`.
- After editing it checks that Squid sees the same list as the file on disk and warns if not. Always use the script or an editor that overwrites in place; an editor that replaces the file can leave the container with a stale copy. `podman rm -f egress-squid` fixes that (`agent.ps1 -Docs` recreates it).
- Run it on the host only, never inside the agent container.
- A fetched web page can contain instructions telling the model to request an attacker's domain (prompt injection). Read each domain before approving it.

The agent's own `webfetch` tool is set to `deny` in `config/opencode/opencode.json`. For docs lookups, change it to `ask` so you have two checkpoints (OpenCode's prompt, then the domain allowlist), and confirm in a test that OpenCode's web tool actually uses the proxy (section 13).

---

## 8. OpenCode configuration (read-only inside the container)

Everything in `config\opencode` is mounted read-only at `/etc/opencode` and selected through `OPENCODE_CONFIG`.

Do not set `OPENCODE_CONFIG_DIR` to this folder. OpenCode treats that directory as writable and stores its background-server state there (`service.json`). With a read-only mount it crashes with `EROFS ... /etc/opencode/service.json.tmp`. Extra agent definitions are mounted separately (section 8.4).

### 8.1 `config\opencode\opencode.json`

First create it with the built-in Cortecs provider and a changed base URL. This keeps OpenCode's bundled model metadata (tool support, limits). Replace the two `<...>` placeholders with exact IDs from section 5.3.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false,
  "share": "disabled",
  "enabled_providers": ["cortecs"],
  "model": "cortecs/<MODEL_ID>",
  "small_model": "cortecs/<SMALL_MODEL_ID>",
  "instructions": ["/etc/opencode/AGENTS.md"],

  "provider": {
    "cortecs": {
      "options": {
        "baseURL": "http://llm-gateway:8080/v1",
        "apiKey": "placeholder-the-gateway-injects-the-real-key"
      }
    }
  },

  "permission": {
    "*": "ask",
    "read": {
      "*": "allow",
      "*.env": "deny",
      "*.env.*": "deny",
      "*.pem": "deny",
      "*.key": "deny"
    },
    "edit": "allow",
    "glob": "allow",
    "grep": "allow",
    "skill": "allow",
    "task": "allow",
    "webfetch": "deny",
    "websearch": "deny",
    "external_directory": "deny",
    "doom_loop": "ask",
    "shell": {
      "*": "allow",
      "git push*": "deny",
      "git remote*": "deny",
      "git config*": "deny",
      "curl*": "deny",
      "wget*": "deny",
      "ssh*": "deny",
      "scp*": "deny",
      "nc*": "deny",
      "ncat*": "deny",
      "sudo*": "deny",
      "rm -rf /*": "deny",
      "rm -rf ~*": "deny"
    }
  }
}
```

Why this design:

- `enabled_providers: ["cortecs"]` means no other provider can be loaded even if credentials appear.
- `apiKey` is a placeholder only so the provider is considered configured. The real key is added by nginx.
- `shell: "*": "allow"` is acceptable here because the container has no network and a read-only config. Change it to `"ask"` if you prefer to approve every command. The explicit denies are a second line of defence.
- `external_directory: deny` keeps the agent inside `/workspace`.
- **The shell permission key name depends on the OpenCode version.** Current docs call it `shell`; older versions and Kilo call it `bash`. A wrong key is silently ineffective. The verification in section 11 tests that a denied command is really denied. Adjust the key if that test fails.

### 8.2 Fallback if the built-in `cortecs` provider id is not recognised

If `opencode models` (section 11) does not list Cortecs models, define the provider yourself and use `cortecs-gw/<MODEL_ID>` as the model:

```json
"provider": {
  "cortecs-gw": {
    "npm": "@ai-sdk/openai-compatible",
    "name": "Cortecs via gateway",
    "options": {
      "baseURL": "http://llm-gateway:8080/v1",
      "apiKey": "placeholder"
    },
    "models": {
      "<MODEL_ID>": {
        "name": "Main model",
        "tool_call": true,
        "limit": { "context": 128000, "output": 16384 }
      },
      "<SMALL_MODEL_ID>": { "name": "Small model", "tool_call": true }
    }
  }
}
```

Also set `"enabled_providers": ["cortecs-gw"]` and the `model`/`small_model` values to `cortecs-gw/...`.

**Offline gotcha:** OpenCode normally downloads provider adapters (`@ai-sdk/*` npm packages) on first use. The sandbox has no internet. The OpenAI-compatible adapter is expected to be bundled. If the first run in the sandbox hangs or shows an npm install error, pre-warm the cache during the image build or once from an online container into the `agent-home` volume. See section 13.

### 8.3 `config\opencode\AGENTS.md` (global rules, loaded for every project)

Keep it short. Every line costs tokens in every session. Project-specific facts go in the project's own `AGENTS.md`.

```markdown
# Global rules (Qt / C++ photogrammetry, Linux build container)

## Environment
- You run in a Linux container without internet. Do not try to download anything.
- If a request fails because a site is blocked (for example a 403 from the proxy), do not look for a workaround. Tell the user the exact domain and ask them to allow it.
- Source is in /workspace. Build output goes ONLY to /cache/build/$PROJECT_NAME.
- Build and test: see the `qt-cmake-build` skill if available.
- Windows-only code (MSVC, WinAPI) cannot build here: report it, do not "fix" it.

## Code
- C++17 or newer as the project dictates. Follow the project's .clang-format; run clang-format on files you edit.
- Prefer RAII and value types. No raw owning pointers. Use Qt parent/child ownership for QObjects.
- Do not reformat unrelated code. Do not change line endings of existing files.
- Numerics (Ceres, Eigen, bundle adjustment): do not change tolerances, solver options or parameterisations unless asked; explain reasoning for any numeric change.

## Workflow
- Make small, reviewable changes. Run the relevant tests before saying you are done.
- Show only the first error and its context when a build fails; never paste full logs.
- Do not commit unless asked. If you do commit: the message states what the commit does, in the imperative, without a "This commit will" prefix, and ends with `[task-number]` when a task number was given.
- Do not edit files under .git, .vscode, or the skills folder (they are read-only anyway).
```

### 8.4 `config\opencode\agents\review.md` (optional read-only reviewer)

If the `config\opencode\agents` folder exists, `lib.ps1` mounts it read-only at `/home/agent/.config/opencode/agents`, which is where OpenCode looks for global agents. The file must be in the `agents` subfolder, not directly in `config\opencode`.

```markdown
---
description: Read-only code review of the current diff
mode: subagent
permission:
  edit: deny
  shell: ask
  webfetch: deny
---

You review changes. You never modify files. Report correctness problems, risky numerics,
Qt ownership or threading issues, and missing tests. Be concise and cite file and line.
```

---

## 9. Run it for the first time

```powershell
# Once
pwsh C:\git\ai-workstation\scripts\set-key.ps1
pwsh C:\git\ai-workstation\scripts\sync-skills.ps1

# Every time
cd C:\git\myproject
git switch -c agent/some-task      # work on a branch so results are easy to review or discard
pwsh C:\git\ai-workstation\scripts\agent.ps1 C:\git\myproject
```

Inside OpenCode: `/models` to confirm the Cortecs model, then ask `List the skills you have available.`

On Linux the same sequence is:

```bash
bash scripts/set-key.sh
bash scripts/sync-skills.sh
cd ~/git/myproject
git switch -c agent/some-task
bash ~/git/ai-workstation/scripts/agent.sh ~/git/myproject
```

Review workflow on the host side after a run: `git status`, `git diff`, run your normal MSVC/Qt build, then commit yourself.

---

## 10. Kilo Code (VS Code) configuration

### 10.1 What costs tokens, and what does not

- **Snapshots do not send code to the model.** They are git-tree snapshots kept outside your repo (under `~/.local/share/kilo/snapshot`). They cost disk and time, especially on repos with many untracked files. They respect `.gitignore`.
- **Indexing** is opt-in. In the new extension it is disabled by default and temporarily unavailable; set it off explicitly anyway.
- **What actually costs tokens:** file reads, long tool output, open or attached files, long chat history, a large always-loaded instruction file, and many skill descriptions.

If your concern is token usage, do the items in 10.4. If your concern is snapshot time or disk size, do 10.3.

### 10.2 Global config

Copy this to `C:\Users\Nejc\.config\kilo\kilo.jsonc` (Linux: `~/.config/kilo/kilo.jsonc`). Create the folder if needed. Global config is trusted, so `{env:...}` resolves there. Project configs checked into repositories cannot resolve `{env:...}`.

`config\kilo\kilo.jsonc`:

```jsonc
{
  "$schema": "https://app.kilo.ai/config.json",

  // Cost / privacy
  "indexing": { "enabled": false },
  "snapshot": true,
  "hide_prompt_training_models": true,
  "experimental": { "openTelemetry": false },

  // Only Cortecs
  "enabled_providers": ["openai-compatible"],
  "model": "openai-compatible/<MODEL_ID>",
  "provider": {
    "openai-compatible": {
      "options": {
        "baseURL": "https://api.cortecs.ai/v1",
        "apiKey": "{env:CORTECS_KILO_API_KEY}",
        "timeout": 300000
      },
      "models": {
        "<MODEL_ID>": {
          "name": "Cortecs main",
          "tool_call": true,
          "limit": { "context": 128000, "output": 16384 }
        }
      }
    }
  },

  // Permissions: Kilo is NOT sandboxed on Windows (and not unless you enable its sandbox on Linux). Default to asking.
  "permission": {
    "read": { "*": "allow", "*.env": "deny", "*.env.*": "deny", "*.pem": "deny", "*.key": "deny" },
    "edit": "ask",
    "bash": {
      "*": "ask",
      "git status*": "allow",
      "git diff*": "allow",
      "git log*": "allow",
      "git push*": "deny",
      "curl*": "deny",
      "wget*": "deny",
      "Invoke-WebRequest*": "deny",
      "iwr *": "deny"
    },
    "webfetch": "deny",
    "websearch": "deny",
    "external_directory": "ask",
    "skill": "allow"
  }
}
```

API key options for Kilo (choose one):

- Environment variable, set before starting VS Code:
  ```powershell
  # Windows
  [Environment]::SetEnvironmentVariable('CORTECS_KILO_API_KEY', '<kilo-key>', 'User')
  ```
  ```bash
  # Linux: add to ~/.profile (read by the desktop session at login)
  export CORTECS_KILO_API_KEY='<kilo-key>'
  ```
  Log out and in on Linux, or restart VS Code on Windows. Downside: every program you run as your user can read it.
- Enter the key in Kilo's Settings > Providers UI instead and remove the `apiKey` line from the file. Kilo stores it in its own auth storage on disk.

Do not check `kilo.jsonc` with a literal key into any repository.

If Kilo lists a built-in Cortecs provider, you may use it instead of `openai-compatible`; the documented generic form above works either way.

### 10.3 Snapshot tuning for large trees

Pick one of:

1. **Keep snapshots, but exclude generated trees locally** (not committed). Add to `<repo>\.git\info\exclude`, for example:
   ```
   build/
   build-*/
   install*/
   out/
   *.obj
   *.pdb
   *.ilk
   ```
   Snapshots honour `.gitignore`. Using `.git/info/exclude` (the same git ignore engine) is expected to behave the same. Verify by checking the snapshot repo size after a task.
2. **Disable for a single huge repo:** create `<repo>\.kilo\kilo.jsonc` with `{ "snapshot": false }`.
3. Initial snapshot on very large repos can stall a turn. Kilo times it out after 10 seconds and offers to disable it. The timeout can be raised with the `KILO_SNAPSHOT_TRACK_TIMEOUT_MS` environment variable.

### 10.4 Token reduction checklist

- Keep `AGENTS.md` (project and global) under about 60 lines.
- Install only skills you actually use (section 4.3). Each adds name and description to every session.
- Close large files and tabs before prompting; attach only what is needed.
- Tell the agent to limit tool output (`| Select-Object -First 80`, `ctest --output-on-failure`, show the first error only).
- Set a cheaper compaction model (optional), then use `/compact` on long chats:
  ```jsonc
  "agent": { "compaction": { "model": "openai-compatible/<SMALL_MODEL_ID>" } }
  ```
  (add the small model under `models` as well).
- Start a new session per task. Use the `handoff` skill to carry context over instead of scrolling history.
- Deny reads of build and third-party trees through `permission.read` patterns, for example `"build/*": "deny"`, `"third_party/*": "deny"`. Adjust to your layout.

### 10.5 Skills in Kilo

Nothing to configure: `~/.agents/skills` is loaded by default. Run `/reload` after syncing. Optional hardening is `KILO_DISABLE_SKILL_SHELL=1` (section 4.5).

---

## 11. Verification

### 11.1 Inside-container test script

`C:\git\ai-workstation\scripts\verify-inside.sh`

```bash
#!/usr/bin/env bash
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; fail=$((fail+1)); }
expect_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }
expect_ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

echo "== Network isolation =="
expect_fail "https://example.com is unreachable"          curl -sS -m 6 https://example.com
expect_fail "http://1.1.1.1 (direct IP) is unreachable"   curl -sS -m 6 http://1.1.1.1
expect_fail "https://1.1.1.1 is unreachable"              curl -sS -m 6 -k https://1.1.1.1
expect_fail "IPv6 is unreachable"                         curl -6 -sS -m 6 -k "https://[2606:4700:4700::1111]"
expect_fail "DNS lookup fails"                            getent hosts example.com
expect_fail "raw TCP to 8.8.8.8:53 fails"                 timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53'
expect_fail "no resolv.conf nameserver"                   grep -q '^nameserver' /etc/resolv.conf

echo "== Gateway =="
expect_ok   "gateway /healthz"                            curl -fsS -m 6 http://llm-gateway:8080/healthz
expect_fail "gateway refuses unknown path"                curl -fsS -m 6 http://llm-gateway:8080/admin
expect_fail "gateway refuses DELETE"                      curl -fsS -m 6 -X DELETE http://llm-gateway:8080/v1/models
code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 http://llm-gateway:8080/v1/models)
if [ "$code" = "200" ]; then ok "gateway -> Cortecs /v1/models returns 200"; else bad "gateway -> Cortecs /v1/models returned $code (401 = bad key, 502/504 = egress or DNS problem)"; fi

if [ -n "${HTTPS_PROXY:-}" ]; then
  echo "== Docs proxy (verify-sandbox -Docs) =="
  expect_fail "proxy refuses a domain that is not allowlisted"   curl -sS -m 15 https://example.net
  expect_fail "proxy refuses a non-443 port"                     curl -sS -m 10 https://doc.qt.io:8443
  allowed="${VERIFY_ALLOWED_HOST:-doc.qt.io}"
  expect_ok   "proxy allows an allowlisted domain ($allowed)"    curl -fsS -m 20 -o /dev/null "https://$allowed"
fi

echo "== Secrets and identity =="
if env | grep -qiE 'cortecs|api_key|token|secret'; then bad "no secrets in agent environment"; else ok "no secrets in agent environment"; fi
[ "$(id -u)" != "0" ] && ok "not running as root (uid $(id -u))" || bad "running as root"
grep -q '^CapEff:\s*0000000000000000' /proc/self/status && ok "no effective capabilities" || bad "capabilities present"
grep -q '^NoNewPrivs:\s*1' /proc/self/status && ok "no-new-privileges set" || bad "no-new-privileges missing"

echo "== Filesystem protections =="
expect_fail "root filesystem is read-only"                touch /usr/.write-test
expect_fail "skills folder is read-only"                  touch /home/agent/.agents/skills/.write-test
expect_fail "opencode config is read-only"                touch /etc/opencode/.write-test
expect_ok   "workspace is writable"                       bash -c 'touch /workspace/.write-test && rm /workspace/.write-test'
if [ -d /workspace/.git/hooks ]; then
  expect_fail ".git/hooks is read-only"                   touch /workspace/.git/hooks/.write-test
  expect_fail ".git/config is read-only"                  bash -c 'echo >> /workspace/.git/config'
else
  echo "SKIP  .git protections (workspace has no .git directory)"
fi
expect_ok   "skills visible"                              bash -c 'ls /home/agent/.agents/skills | grep -q .'
expect_ok   "toolchain present (cmake, ninja, clang-format)" bash -c 'cmake --version && ninja --version && clang-format --version'

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

### 11.2 Runner

`C:\git\ai-workstation\scripts\verify-sandbox.ps1`

```powershell
#requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Workspace,
    [switch]$Docs   # also test the Squid docs proxy (starts it)
)
. (Join-Path $PSScriptRoot 'lib.ps1')

$ws = (Resolve-Path -LiteralPath $Workspace).Path
Assert-Machine
Initialize-Networks
Start-Gateway
if ($Docs) { Start-Squid }

$run    = Get-AgentRunArgs -Workspace $ws -Docs:$Docs
$inside = Join-Path $PSScriptRoot 'verify-inside.sh'
& podman @run -v (Get-BindArg $inside '/verify.sh') $script:AgentImage bash /verify.sh
exit $LASTEXITCODE
```

```powershell
pwsh C:\git\ai-workstation\scripts\verify-sandbox.ps1 C:\git\myproject
```

Everything must say PASS. If anything FAILs, do not use the sandbox for real work until it is fixed.

Run it a second time with `-Docs` to also test the Squid proxy (a non-allowlisted domain and a non-443 port must be refused; an allowlisted domain, `doc.qt.io` by default or `$env:VERIFY_ALLOWED_HOST`, must work). Expected: 26 PASS (23 without `-Docs`).

On Linux:

```bash
bash scripts/verify-sandbox.sh ~/git/myproject
bash scripts/verify-sandbox.sh --docs ~/git/myproject
```

`skills visible` fails if `~/.agents/skills` is empty. Run `sync-skills` first.

### 11.3 Application-level checks (manual, in OpenCode)

1. Ask: `Run: curl https://example.com`. It must be denied by permission or fail on the network.
2. Ask: `Run: git push` (denied) and `git remote add x https://example.com/a.git` (denied).
3. Ask it to read `.env` (denied). Make a test `.env` first.
4. Ask it to build your project using `/cache/build/...`; check that ccache works and that output is not in `/workspace`.
5. Check for a permission-key mistake: if the denied commands in 1 and 2 were not blocked by permissions (only by the network), your shell key name is wrong for your OpenCode version (section 8.1).
6. `podman logs llm-gateway` shows only LLM API paths. Anything else means the agent found another route.

### 11.4 Optional: packet capture proof

Capture while the agent works and confirm the only outbound HTTPS goes to Cortecs IPs. On Windows, capture inside the Podman machine; on Linux, run the same `tcpdump` directly on the host (it needs root):

```powershell
podman machine ssh        # Windows only; on Linux skip this line
# then, in the machine (or on the Linux host):
sudo tcpdump -ni any 'tcp[tcpflags] & tcp-syn != 0 and not port 22' -c 200
```

Expected: SYNs to Cortecs addresses from the gateway container, and nothing from the agent's IP range 10.89.77.x to anywhere except `10.89.77.10`.

---

## 12. Maintenance

| Task                                           | How                                                                                                                                         |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Add or remove an upstream skill                | Edit `skills-manifest.txt`, run `sync-skills.ps1`, `/reload` in Kilo, restart OpenCode                                                      |
| Update upstream skills                         | `git -C <upstream-clone> fetch`; review `git diff HEAD..origin/main -- skills`; `git pull`; run `sync-skills.ps1`; note the new commit |
| Add your own skill                             | Create `skills\my-skills\<name>\SKILL.md`; run `sync-skills.ps1`                                                                            |
| Rotate the OpenCode key                        | New key in Cortecs; `scripts\set-key.ps1`; `agent.ps1 ... -RestartGateway`                                                                  |
| Update OpenCode                                | Change `--build-arg OPENCODE_VERSION`, rebuild, re-run `verify-sandbox.ps1`, read release notes first                                       |
| Update base images                             | `podman pull` for nginx/squid/ubuntu; rebuild; then pin the new digest in `lib.ps1`                                                         |
| Gateway cannot reach Cortecs after a long idle | `agent.ps1 ... -RestartGateway`                                                                                                             |
| Clean cache                                    | `podman volume rm agent-cache` (build cache); `podman volume rm agent-home` (OpenCode sessions and state)                                   |
| Review what was sent                           | `podman logs llm-gateway` (paths and sizes only)                                                                                            |

Pin image digests once you have checked them:

```powershell
podman image inspect docker.io/nginxinc/nginx-unprivileged:1.27-alpine --format '{{.Digest}}'
```

Then use `image@sha256:...` in `lib.ps1`.

---

## 13. Troubleshooting (Windows and Linux)

| Symptom                                                    | Likely cause and fix                                                                                                                                                                                                                                                                                                                                                                                                 |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Normal containers have no internet (section 3.4 test 1)    | WSL2 networking issue. Try `podman machine rm`, then `podman machine init --user-mode-networking`. If a corporate policy blocks WSL traffic, use mirrored networking in `.wslconfig` (`[wsl2]` then `networkingMode=mirrored`).                                                                                                                                                                                      |
| `podman network create --internal --disable-dns` rejected  | Update Podman (`winget upgrade RedHat.Podman`) and recreate the machine. Network flags require a reasonably recent Podman (5.x).                                                                                                                                                                                                                                                                                     |
| Gateway shows 502/504                                      | Gateway cannot resolve or reach Cortecs. Check `podman logs llm-gateway`. Check the `resolver 10.89.78.1` line: it must be the gateway address of `agent-egress` (`podman network inspect agent-egress`). Test `podman run --rm --network agent-egress alpine nslookup api.cortecs.ai 10.89.78.1`.                                                                                                                   |
| Gateway fails to start with `--read-only`                  | Remove `--read-only` and the two `--tmpfs` lines from `Start-Gateway` temporarily, confirm it works, then re-add them one by one.                                                                                                                                                                                                                                                                                    |
| `crun: open memory.max for writing: No such file or directory` | Rootless Podman has no `memory` (or `pids`/`cpu`) cgroup controller delegated, which is the default in the WSL machine. `lib.ps1` now skips limits for missing controllers and prints a warning, so the containers start. To get the limits for real, delegate the controllers. Run `podman machine ssh`, then `sudo mkdir -p /etc/systemd/system/user@.service.d`, then `printf '[Service]\nDelegate=cpu cpuset io memory pids\n' \| sudo tee /etc/systemd/system/user@.service.d/delegate.conf`, then `exit`. Then run `podman machine stop` and `podman machine start`. Verify with `podman info --format '{{.Host.CgroupControllers}}'`, which should list `memory` and `pids`. |
| Gateway 502, log says `upstream SSL certificate verify error: (20:unable to get local issuer certificate)` | The CA bundle is present, but nginx's `proxy_ssl_verify_depth` defaults to 1. Set `proxy_ssl_verify_depth 5;` next to `proxy_ssl_verify on;` in `default.conf.template`, then run `podman rm -f llm-gateway` and re-run the script. If it persists, the server may not send its full chain. Diagnose with `podman run --rm docker.io/library/alpine:3.20 sh -c "apk add -q openssl && openssl s_client -connect api.cortecs.ai:443 -servername api.cortecs.ai -showcerts </dev/null"`. |
| Gateway returns 401                                        | Wrong key, or trailing whitespace or newline in the secret. Re-run `set-key.ps1`.                                                                                                                                                                                                                                                                                                                                    |
| Permission denied on `/workspace` or `/cache`              | The container user is always uid 1000, mapped to your host user by `--userns=keep-id`. On Linux check SELinux first (see the SELinux rows). On Windows check `podman machine ssh id -u`. Otherwise adjust `uid=1000,gid=1000` in `lib.ps1`/`Containerfile`. As a last resort, run with `--user 0:0` (root in the rootless user namespace; capabilities are still dropped).                                                                                                                                                                       |
| `git status` shows every file modified                     | Line endings or file-mode noise. `core.filemode=false` is preset in the image. Check `git ls-files --eol`; do not let the agent normalize line endings.                                                                                                                                                                                                                                                              |
| Builds are slow                                            | `/mnt/c` bind mounts are slow for many small files. Mitigations: build outputs and ccache already live in a volume; use `ccache`; later consider cloning the repo into the Podman machine's Linux filesystem for agent work only and pulling results with git.                                                                                                                                                       |
| OpenCode hangs at startup, mentions npm or models.dev      | It is trying a download. Pre-warm the provider adapter cache in the `agent-home` volume with one online run: `podman run --rm -it -v agent-home:/home/agent -v ...config:/etc/opencode:ro localhost/ai-agent:latest opencode`, run one prompt, quit, then use the sandbox normally. Alternatively define the provider with `npm: "@ai-sdk/openai-compatible"` and check that it is bundled in your OpenCode version. |
| Skill not listed in OpenCode                               | Frontmatter `name` must equal the folder; `SKILL.md` in capitals; no `OPENCODE_DISABLE_EXTERNAL_SKILLS` or `OPENCODE_DISABLE_CLAUDE_CODE` set; check the container mount with `agent.ps1 ... -Shell` then `ls ~/.agents/skills`.                                                                                                                                                                                     |
| Skill not listed in Kilo                                   | `/reload`; check name/folder match; Kilo needs `SKILL.md` directly under the skill folder.                                                                                                                                                                                                                                                                                                                           |
| `-Docs` web fetch does not use the proxy                   | Some tools ignore `HTTPS_PROXY`. Keep `webfetch` on `ask` with an explicit URL allowlist and test; if it still fails, skip docs mode and put documentation excerpts into the repo instead.                                                                                                                                                                                                                           |
| Linux: `permission denied` on mounted files, `getenforce` prints `Enforcing` | SELinux is blocking the bind mount. `lib.sh` adds `,z` automatically when it sees `Enforcing`; if you still get denials, check `ausearch -m avc -ts recent` and that `getenforce` works in your shell. See section 3L.4. |
| Linux: `Permission denied` when running `scripts/x.sh` | The execute bit is missing. Run `chmod +x scripts/*.sh`, or start them with `bash scripts/x.sh`. |
| Linux: `declare: -A: invalid option` or `bad substitution` in a script | bash older than 4. Check `bash --version`; use a current distribution. |
| Linux: `podman network create --internal --disable-dns` fails or DNS tests pass when they should fail | The network backend is CNI, not netavark. Check `podman info --format '{{.Host.NetworkBackend}}'`, install `netavark` and `aardvark-dns`, and run `podman system reset` (deletes all containers and images). |
| Linux: `podman build` says no `Containerfile` or `Dockerfile` found | The file must be named exactly `Containerfile` (case-sensitive). Rename `ContainerFile` with `git mv`. |
| Linux: `podman: cannot find UID/GID` or `newuidmap` errors | `uidmap` is not installed or `/etc/subuid` has no entry for your user. See section 3L.2. |
| PowerShell scripts show strange errors with `*> $null`     | You are in Windows PowerShell 5.1. Use `pwsh` (PowerShell 7).                                                                                                                                                                                                                                                                                                                                                        |
| CRLF errors (`\r: command not found`, `exec format error`) | A `.sh`, template or Containerfile was saved with CRLF. Re-save as LF (see section 3.5).                                                                                                                                                                                                                                                                                                                             |

---

## 14. What was not verified (check these on your machine)

The core sandbox was run on Windows and passes the verification script (23/23). The items below still need your confirmation. Items 11 to 14 are about the Linux support, which was written but never run.

1. **OpenCode version and config differences (v1 vs v2).** Cortecs documents a `v2` installer. Confirm `opencode --version`, the permission key (`shell` vs `bash`), and that `enabled_providers`, `share`, `autoupdate`, `instructions`, `small_model` are still valid.
2. **Provider adapter offline.** Confirm the first OpenCode run works with no internet (section 13 row on npm).
3. **Built-in `cortecs` provider id** in your OpenCode version, and that overriding `options.baseURL` works for it. Fallback in 8.2.
4. ~~Podman on WSL2 with `--internal --disable-dns`, static IPs and `--dns=none`~~ Verified on Windows: the test script passes.
5. ~~`--secret ...,type=env` through the Windows remote client~~ Verified on Windows (the gateway authenticates to Cortecs).
6. **Docker Hub image tags** (`nginx-unprivileged:1.27-alpine`, `ubuntu/squid:latest`) work, but they are floating tags. Pin digests (section 12).
7. ~~nginx `NGINX_ENVSUBST_FILTER` with `--read-only`~~ Verified on Windows, after the `/etc/nginx/conf.d` tmpfs and `proxy_ssl_verify_depth` fixes.
8. **Kilo:** exact `kilo.jsonc` keys for your extension version (use the `$schema` for validation), whether a built-in Cortecs provider exists, and `.git/info/exclude` being honoured by snapshots.
9. **Skills frontmatter:** upstream skills carry `disable-model-invocation: true`. Confirm neither tool rejects the unknown field and decide whether to add the OpenCode `metadata: opencode/autoinvoke: "false"` key to user-invoked skills (they would then no longer appear in the model-facing skill list).
10. **Qt version and project dependencies** in the Containerfile are examples. Match them to your product.
11. **Linux: the whole flow on your distribution.** The bash scripts were run on Linux inside the Podman machine (Linux with bash 5.3 and rootless Podman, via WSL2): `verify-sandbox.sh --docs` passed everything except `skills visible` until `sync-skills.sh` had run, then the skills and `allow-site.sh` flows worked, `agent.sh --shell` and argument passthrough worked, and `set-key.sh` was checked against a stand-in `podman`. They have **not** been run on a standalone distribution. Run section 3L, then sections 4 to 11, and confirm `verify-sandbox.sh --docs` passes 26/26 there.
12. **Linux: SELinux `,z` relabeling** on Fedora or RHEL for the workspace, skills, config and the nested read-only `.git/hooks` and `.git/config` mounts.
13. **Linux: `--userns=keep-id:uid=1000,gid=1000`** with a host UID other than 1000, and ownership of the `agent-home` and `agent-cache` volumes.
14. **`getenforce` detection in `lib.sh`** (the Podman machine used for testing has no SELinux tools, so the `,z` path never ran).
15. **`allow-site.ps1`:** verified on Windows (add, temporary, extend, remove, expire, refusal of risky domains, live reload, `verify-sandbox.ps1 -Docs` 26/26). Still to check: the same on Linux, and that OpenCode's own web tool uses `HTTPS_PROXY`.

---

## 15. Implementation checklist (the order to do it in)

1. Section 3: Windows: install, `.wslconfig`, Podman machine, both smoke tests. Linux: section 3L. Both: repo hygiene files (3.5).
2. Section 4: clone upstream skills, create `skills-manifest.txt`, run `sync-skills.ps1`, test visibility in Kilo (after step 7).
3. Section 5: create the two Cortecs keys, set project routing/budget, list model IDs, run `set-key.ps1`.
4. Section 6 and 7: create all files, build the agent image, run `agent.ps1` once to start the gateway.
5. Section 8: fill in model IDs in `opencode.json`.
6. Section 11: run `verify-sandbox.ps1` until every line is PASS; do the manual checks.
7. Section 10: copy `kilo.jsonc` to `C:\Users\Nejc\.config\kilo\kilo.jsonc` (Linux: `~/.config/kilo/kilo.jsonc`), set the Kilo key, test the skills question.
8. Commit the `ai-workstation` repo. Commit messages state what the commit does without a "This commit will" prefix, plus `[task-number]` if you have one.
9. Optional: phase-2 skills (local issue tracker), `-Docs` mode with `allow-site.ps1` (section 7.5), and `.git/info/exclude` tuning for large repos.
