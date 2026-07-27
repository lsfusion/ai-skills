---
name: lsfusion-dev
description: >-
  Set up, run, and verify lsFusion applications locally on Windows. Use this
  skill whenever the user works with lsFusion in any way — writing or editing
  .lsf modules, scaffolding an lsFusion app, downloading the lsFusion server
  jar or client war, starting the lsFusion application server, diagnosing why
  the server won't start or a form won't open, or checking an lsFusion result
  in the browser. Triggers on "lsFusion", ".lsf", "start the lsFusion server",
  "write lsFusion code", "verify the form", and any request to create, launch,
  debug, or verify an lsFusion project. Use it even when the user only mentions
  lsFusion in passing and expects something runnable.
---

# lsFusion development

> **Companion MCP server — `lsfusion-ai`** ([`ai.lsfusion.org`](https://ai.lsfusion.org/mcp),
> registered by the `lsfusion-ai-skills` plugin). Call
> **`mcp__lsfusion-ai__lsfusion_get_guidance`** **first** in any lsFusion task
> (if its rules aren't already in context) and follow every rule it returns —
> the element order, the coding rules, and the `lsfusion_report_feedback`
> consent policy all live there. Confirm syntax with
> **`mcp__lsfusion-ai__lsfusion_retrieve_docs`** instead of guessing. If these
> tools are missing, the server isn't installed — see the
> [ai-skills README](https://github.com/lsfusion/ai-skills#readme) to add it.

This skill turns the current folder into a runnable lsFusion project: it checks
the environment, downloads the platform binaries, scaffolds the project,
launches the server, monitors startup, and verifies the result in a headless
browser. The current folder is the **project root**; `.lsf` source files live
under `src/main/lsfusion/` (the standard Maven layout — see [step 3](#3-write-the-lsf-code)),
and the platform binaries and runtime state live in a hidden `.lsfusion-dev/`
subfolder of the project root.

## How lsFusion runs (mental model)

lsFusion has **two** processes, plus a database:

- **PostgreSQL** — the database. Required. lsFusion stores all data here.
- **Application server** — the `lsfusion-server-<ver>.jar`. Runs the business
  logic, talks to PostgreSQL, exposes RMI on port `7652`, an HTTP Action API
  on port `7651`, and a WebSocket server on port `8887`. Started with
  `java -cp ".;<jar>" lsfusion.server.logics.BusinessLogicsBootstrap`.
- **Web server** — the `lsfusion-client-<ver>.war` deployed in Apache Tomcat.
  Serves the browser UI at the project's **app-id context path** —
  `http://localhost:8080/<app id>/` (the root `/` just redirects there) — and
  connects to the application server over RMI (port `7652`).

A change to any `.lsf` file requires **restarting the application server** (the
web server does not need a restart).

## CRITICAL: writing `.lsf` code

Do **not** invent lsFusion syntax from memory. For **any** task that reads or
writes lsFusion code, use the MCP server (header note above) — this is
non-negotiable and the MCP itself enforces it: `lsfusion_get_guidance` first,
then `lsfusion_retrieve_docs` (query in English for best recall) for the exact
syntax and semantics of every construct, before writing or changing code.

## The `lsfdev.ps1` CLI

All environment and runtime operations go through one PowerShell script. Invoke
it with a bypassed execution policy so it runs regardless of system settings:

```
powershell -ExecutionPolicy Bypass -File .claude/skills/lsfusion-dev/scripts/lsfdev.ps1 <command> [options]
```

**Resolve the real script path first — it is often not `.claude/skills/…`.**
The path above holds only for a project-local skill copy. When `lsfusion-dev`
is installed as a **plugin** (the usual case), `lsfdev.ps1` lives under the
plugin cache instead, e.g.
`C:\Users\<user>\.claude\plugins\cache\lsfusion\lsfusion-ai-skills\<ver>\skills\lsfusion-dev\scripts\lsfdev.ps1`.
Invoking the relative `.claude/skills/...` path there fails with *"The argument
… does not exist"* (exit 127). This `SKILL.md` file's own directory is the
skill root: take the absolute path of the `scripts/lsfdev.ps1` next to it and
use that (quoted) in every invocation. The examples below keep writing the
short relative form for brevity — substitute your resolved absolute path.

`-ExecutionPolicy Bypass` is **required** on a default Windows install: without
it PowerShell refuses to load unsigned `.ps1` files with
`UnauthorizedAccess: running scripts is disabled on this system`. The flag
bypasses the policy for this one invocation only — it does not change any
system setting. Do **not** drop the flag to make permission prompts go away;
that breaks the script for everyone whose execution policy is not
`RemoteSigned` (the default on personal Windows machines is `Restricted`).

**Got a dedicated PowerShell tool? Call the script in-process — no flag, no
classifier friction.** Some harnesses (Claude Code on Windows among them)
expose a PowerShell tool whose host process already runs with the `Process`
execution-policy scope set to `Bypass` (check with `Get-ExecutionPolicy
-List`). Inside such a tool, invoke the script directly:

```
& "C:\<resolved skill root>\scripts\lsfdev.ps1" setup -DbPassword "<pwd>"
```

The `.ps1` loads under the host's own policy — no `powershell.exe` child
process, no `-ExecutionPolicy Bypass` on any command line, so the auto-mode
classifier (below) has nothing to flag. A full session of lsfdev calls runs
this way without a single prompt (verified). Everything below about the
`powershell -ExecutionPolicy Bypass -File …` form applies when you only have
a generic bash/exec tool to work with.

**Heads-up on the auto-mode classifier — prefer accept-edits from the start
(when spawning `powershell.exe`).**
Claude Code's auto-mode classifier frequently refuses these invocations with
*"Running PowerShell with -ExecutionPolicy Bypass tunnels around the execution
policy safety control"*. The verdict is non-deterministic — the same command
can be allowed on one turn and blocked on the next, and the classifier has
been observed citing `Bypass` even when the flag was absent. Because most
lsFusion sessions need many lsfdev.ps1 calls in a row (check → setup → start →
verify → restart …), getting blocked mid-flow is painful.

**Recommend that the user switch to accept-edits mode (Shift+Tab) up front**,
before you start running lsfdev.ps1 commands. State this in your first reply
when the user kicks off an lsFusion task. One-time toggle, no per-call
prompts, and every subsequent invocation just works.

If the user prefers a persistent fix, an allow entry such as
`Bash(powershell -ExecutionPolicy Bypass -File .claude/skills/lsfusion-dev/scripts/lsfdev.ps1*)`
in `.claude/settings.local.json` also clears the classifier — but **you cannot
add it yourself**. The classifier blocks Claude from editing its own
permission config (including via the `update-config` skill) as
*"Self-Modification of agent permission config"*. So if the user goes this
route, hand them the exact line to paste; do not call `update-config` and hope
it works.

Either way, the underlying PowerShell `-ExecutionPolicy Bypass` flag still
needs to stay — accept-edits / allow rules clear the classifier, not Windows'
script-execution policy.

**Always double-quote Windows paths in lsfdev.ps1 arguments.** Bash strips
unescaped backslashes when it parses a command line, so

```
... lsfdev.ps1 setup -ProjectDir C:\Work\proj -DbPassword postgres
```

is delivered to PowerShell as `-ProjectDir C:Workproj`, and `Resolve-Path`
fails with *"Cannot find path 'C:\<cwd-name>\Workproj'"* (PowerShell also
silently prepends the current working directory to the mangled relative
path, which makes the error message look unrelated to escaping). Quote every
path argument:

```
... lsfdev.ps1 setup -ProjectDir "C:\Work\proj" -DbPassword postgres
```

This applies to `-ProjectDir`, `-DbServer`, `-Url`, `-Script`, and any other
option that takes a path. Quoting forward-slash paths (`"C:/Work/proj"`) is
fine too and avoids the issue entirely — pick whichever style you started
with and stay consistent within the project.

**PowerShell quoting for `-Do` / `-Click` / `-Script` values: single quotes,
always.** When a value carries double quotes, brackets or commas — attribute
selectors (`[data-id="add item"]`), JS for `eval:`, action scripts with
string literals — wrap it in **single quotes**:

```
... verify -Do 'click:[data-id="add item"]','fill:input[name="qty"]=>5'
```

Backslash-escaping the inner quotes (`-Do "click:[data-id=\"add\"]"`) is a
bash habit that PowerShell does not share, and it never degrades gracefully
(all measured): the argument **splits apart** ("A positional parameter cannot
be found that accepts argument 'add\]'"), a `|` in the value becomes a real
**pipe** ("The term '\)' is not recognized"), and a comma in the unquoted
remainder aborts parsing outright ("Missing argument in parameter list").
The backtick form `` "click:[data-id=`"add`"]" `` also works; `\"` never
does. Three more PowerShell-isms: several `-Do` steps are **one array
argument** — `-Do 'step1','step2'` — repeating the flag (`-Do a -Do b`)
fails with *"parameter 'Do' is specified more than once"*; array
parameters arrive as a real array only from an in-process call
(`& .\lsfdev.ps1 ...`) or `powershell -Command` — **`powershell -File`
passes `'a','b'` as one literal string** (`precheck -Files` tolerates
that by splitting on commas; multi-step `-Do` cannot, since steps
legitimately contain commas — use the in-process/`-Command` form); and
for `api` scripts with string literals or non-ASCII text, skip argv
entirely with `-ScriptFile` (same for `-OpenScriptFile`).

**Pass `-ProjectDir` on EVERY call — don't rely on the current directory.**
Without `-ProjectDir` the script uses the shell's cwd, and tool shells reset
their cwd between calls, so a bare `lsfdev.ps1 verify` that worked after a
`cd` earlier can later look at the wrong directory. The symptom is
*"Project is not set up: no .lsfusion-dev\config.json under '\<dir\>'"* on a
project that IS set up (the message names the directory it inspected — check
it first). This is purely path resolution: it is not caused by server state,
a running `verify -Session` browser, or anything else that happened before.

| Command | What it does |
|---|---|
| `check` | Detect Java, PostgreSQL, Python, git, and Maven; report versions and what is missing. |
| `versions` | List the lsFusion versions on the download server and the alias mappings. |
| `setup` | Fetch the server jar, client war, and Tomcat into `.lsfusion-dev/` (only what's missing / version-changed, plus the war on `-RefreshWar` — see note); write config + `settings.properties`. Safe to re-run anytime. |
| `start-server` | Start the application server, tail the log, and report a verdict (started / failed / inconclusive). |
| `start-web` | Start Tomcat with the web client; wait until the UI responds. |
| `start` | `start-server` then `start-web`. |
| `restart` | Stop everything, then `start`. Use this after editing `.lsf` files. |
| `stop` | Stop the application server and Tomcat. |
| `status` | Show which processes/ports are up, plus `Database: <name> (N connections)` — the actually-observed DB binding (flags a mismatch for a running server). |
| `log` | Print the tail of the server log and flag errors. |
| `verify` | Playwright (headless Chromium) screenshot + DOM dump of the web UI into `.lsfusion-dev/`. `-OpenScript "SHOW <form> DOCKED;"` opens a specific form **directly** — no navigator clicking, parameterizable down to one object's edit card, `DOCKED` to render it as in production (→ `verify-open.png`, assert with `-OpenExpect`; see step 5). `-Click "<navigator text>"` (chain with `>`) instead clicks into a form like a user would, and `-DoubleClick "<row text>"` double-clicks a grid row to open its edit card (→ `verify-dblclick.png`). `-Do "<verb:step>",...` runs generic interaction steps after that (click/dblclick/hover/drag/mouse/fill/type/press/eval/wait by any Playwright selector) — the way to drive CUSTOM/React components incl. real drag gestures (→ `verify-do.png`). `-Session` keeps a persistent browser between calls so multi-step scenarios skip re-navigation (`-EndSession` closes it). |
| `open` | Open the web UI in the user's default browser. |
| `api` | Call the HTTP Action API via `-Script "<code>"` or `-ScriptFile "<path>"` (advanced verification / data seeding). **Action code only** — its `/eval/action` endpoint wraps the script in an action body, so declarations produce garbage parse errors; lint declarations with `precheck` instead. Use `-ScriptFile` (UTF-8) for any script with non-ASCII text. |
| `precheck` | Sub-second **syntax + name lint** of `.lsf` files against the running dev server, before paying for a restart. `-Files 'a.lsf','b.lsf'` (project-relative or absolute; default: every `.lsf` under `src/main`). Strips `MODULE`/`REQUIRE` headers (line numbers preserved), posts to `/eval`, and words each verdict by what was proven (a load-only construct → syntax-only; `EXTEND FORM` / `() + { }` → "cannot lint"). See "run `precheck`" below. |

Key options: `-AppId` (the project's short identifier = its `db.name` **and**
its web context path; see step 2), `-DbPassword`, `-DbUser`, `-DbServer`, `-DbName`, `-Version`
(`7` — default; `stable`; `dev`/`snapshot`; a major-version alias; or an exact
tag — see below), `-TomcatVersion`, `-TopModule`, `-RmiPort`, `-HttpPort`,
`-WebSocketPort`, `-WebPort`, `-ShutdownPort`, `-JvmArgs` / `-TomcatOpts`
(extra JVM flags for the app server / Tomcat, persisted at setup — e.g.
`-JvmArgs "-Duser.language=ru -Xmx4g"`), `-FullStart`, `-RefreshWar` (setup:
re-download the client war at the same version — the `-SNAPSHOT`
war↔server build-drift fix, see below), `-Url`, `-OpenScript` /
`-OpenScriptFile` / `-OpenExpect` (verify: direct form open), `-Click`,
`-DoubleClick`, `-ViewportWidth` / `-ViewportHeight` / `-Locale` (verify), `-Script`,
`-Do` (verify: generic click/hover/drag/mouse/fill/type/press/eval/wait steps
by Playwright selector — see step 5), `-Session` / `-Reload` / `-EndSession`
(verify: persistent browser between calls; `-Reload` forces a page reload in
it), `-ScriptFile`, `-Timeout`. Run the script with no command to print full
usage.

If port `8080` is taken (e.g. another Tomcat), pass `setup -WebPort <free port>`
— the skill rewrites Tomcat's `server.xml` accordingly, and every later command
reads the port from config. Run `check`/`status` to see port conflicts.

### Recommended tool-call timeouts

Every command returns as soon as it prints its verdict, so an oversized
timeout costs no wall-clock by itself — but a very long timeout is one of the
signals that gets a command reclassified as a background task (see the
no-pipe note in step 4), so don't inflate it "just in case":

| Command | Tool-call timeout |
|---|---|
| `check` / `status` / `log` / `versions` / `api` / `open` | default (120 s) |
| `setup` — first run (downloads ~400 MB) | 600 s |
| `setup` — re-run (ports, DB, settings tweaks) | default |
| `setup -RefreshWar` (re-downloads the ~250 MB war) | 600 s |
| `start` / `restart` — routine edit→restart cycle (lightstart) | 300 s |
| `start-server` — first start on this DB, or major-version upgrade (raise the inner `-Timeout` to 300 as well) | 600 s |
| `verify` — first ever run (installs Playwright + Chromium, ~120 MB) | 300 s |
| `verify` — later runs | default (300 s when `-OpenScript`/`-Click` hits the *first* open of a heavy form right after a restart — the lazy form build alone can take 40 s) |

Rule of thumb: outer timeout ≈ the script's inner `-Timeout` (default 180 s)
plus ~2 minutes of Maven/Tomcat overhead. Don't copy the 600 s ceiling from a
first-start invocation into routine restarts — recalibrate per call.

**`setup` downloads are version-driven, not `-Force`-driven.** Re-running
`setup` (with or without `-Force`) only fetches an artifact that is **missing**
or whose **platform version changed** — the single exception being the
explicit `-RefreshWar` switch (war only, same version; see below):

- **Server jar** and **client war** are versioned with the platform — refetched
  on a fresh setup or a `-Version` bump, otherwise kept (the war also on
  `-RefreshWar`).
- **Tomcat** is the servlet container, independent of the lsFusion version — a
  new client war runs on the existing Tomcat — so it's fetched **only when
  missing**, never on a war update. (To switch Tomcat builds, delete
  `.lsfusion-dev/tomcat` and re-run `setup`.)

`-Force` regenerates config + `settings.properties` but does **not** re-download
binaries (delete the file to force a refetch). Before replacing Tomcat or the
war, `setup` **stops a running Tomcat first**, so an update can't fail on a
locked `bootstrap.jar` / exploded `ROOT`. Net effect: re-running `setup` to
tweak ports, DB, or settings is cheap and won't touch the ~400 MB of binaries.

The one refetch case that DOES arise on an unchanged version: **`-SNAPSHOT`
build drift in Maven projects**. Maven re-resolves the server jar over time
(pom change, `mvn -U`, snapshot update policy) while the war stays whatever
`setup` downloaded; war and server from different snapshot builds can break
RMI serialization, and **every form open fails with `invalid stream
header`**. `start-web` / `status` / `setup` compare the two build dates
(zip entry stamps) and warn, naming the stale side; **`setup -RefreshWar`**
re-downloads the war at the same version (current snapshot build). Details:
[references/runtime.md](references/runtime.md).

### Running several servers / configs at once

The application server uses **three** ports beyond the web port: `rmi.port`
(default **7652** — the RMI register the web client connects to), `http.port`
(default **7651** — the embedded HTTP server / Action API used by `/eval`,
`/exec`, the lsfusion-eval skill), and `webSocket.port` (default **8887** — a
WebSocket server the platform binds **unconditionally** at startup). To run
multiple instances side by side, give each project a **disjoint set of all
five ports plus its own database**, then `setup` once with those values and
`start`:

```
# instance A — defaults (7652 / 7651 / 8887 / 8080), app id names its DB + context
lsfdev.ps1 setup -ProjectDir "C:/Work/projA" -AppId proja -DbPassword <pwd>
lsfdev.ps1 start -ProjectDir "C:/Work/projA"          # UI: http://localhost:8080/proja/

# instance B — shifted ports + its own app id/DB, runs concurrently with A
lsfdev.ps1 setup -ProjectDir "C:/Work/projB" -AppId projb -DbPassword <pwd> `
                 -RmiPort 7662 -HttpPort 7661 -WebSocketPort 8897 `
                 -WebPort 8091 -ShutdownPort 8006
lsfdev.ps1 start -ProjectDir "C:/Work/projB"          # UI: http://localhost:8091/projb/
```

`webSocket.port` is the one everybody forgets, and the failure is **silent**:
a second instance left on the default still starts fine — but stderr gets a
`java.net.BindException: Address already in use` stack trace from
`WebSocketServer`, and that instance's WebSocket features just don't work. If
that trace shows up after bringing up a second server, shift `webSocket.port`
and restart. (`debugger.port`, default 1299, also exists but is bound only
when debugging — it doesn't collide in normal runs.)

You usually don't have to pick the numbers yourself: when `setup` runs with
no port flags and finds a default port already taken by a foreign process,
it **derives a deterministic per-project port set from the project-path
hash** (the same hash that names the database), probes that the whole set is
free, and persists it. Parallel agent sessions on one box thus land on
disjoint ports instead of all reaching for "default+10" and colliding —
explicit `-RmiPort`/... flags always override.

`-RmiPort` / `-HttpPort` / `-WebSocketPort` follow the **exact same scheme as
the database settings**: `setup` writes `rmi.port` / `http.port` /
`webSocket.port` into the project's `settings.properties` (right next to
`db.*`), and the server reads them natively at startup. So the ports live in a durable project file — not just
`.lsfusion-dev/config.json` — and survive a wiped `.lsfusion-dev/`, a fresh
clone, or any launch path. You can equally set them by hand-editing
`settings.properties` instead of passing the flags. `start`/`restart`/`stop`/
`api` read them back from `settings.properties` (config.json is only a
cache/fallback). `start-web` writes `conf/Catalina/localhost/<app id>.xml`
(the per-context descriptor, named after the deployed `<app id>.war`) with a
`port` `<Parameter>` so that project's Tomcat dials its own server's
`rmi.port` instead of the built-in default 7652. When hitting the Action API
for a specific instance, use that instance's `http.port`
(e.g. `http://localhost:7661/eval/action`).

> Default ports (7652 / 7651 / 8887) are left implicit — `settings.properties`
> only carries them when non-default, exactly like `db.user`/`db.server`. An
> **explicitly passed** flag (`-DbName`, `-RmiPort`, …) is written straight into
> the authoritative `conf/settings.properties` even without `-Force`; a plain
> re-`setup` with no flags preserves whatever the file already holds; `-Force`
> regenerates the whole file. You can also just hand-edit the file.

**Changing `rmi.port` / `http.port` on a *running* instance — `stop` FIRST.**
`stop` (and `restart`'s stop phase) finds the live server by the ports in the
**current** config. If you change the ports *before* stopping, `stop` looks for
the server on the **new** ports, misses the still-running old instance, and you
end up with a stale server holding the old ports (and the database). Always do:

```
lsfdev.ps1 stop                                   # kills the server on the OLD ports
lsfdev.ps1 setup -RmiPort <new> -HttpPort <new>   # rewrites conf/settings.properties
lsfdev.ps1 start                                  # starts on the NEW ports
```

Do **not** use `restart` to change ports — its stop phase already reads the new
config. After the switch, the Action API moves with `http.port` (e.g.
`http://localhost:<new http.port>/eval/action`); the web port is unaffected.

**Each instance needs its own app id** — the id IS `db.name`, and two servers
pointed at the same database will fight over the schema. Distinct ids give
distinct databases (and the no-`-AppId` fallback id is derived from the
project path, so distinct project dirs differ too); `-DbName` sets the name
explicitly when needed.

The file the server actually reads at runtime is **`conf/settings.properties`**
(in *both* Maven and non-Maven projects; in a non-Maven project the project-root
`settings.properties` is a human-readable mirror that `setup` and `start` keep
in sync). It is the **source of truth**: `start` / `restart` / `stop` / `api`
read `db.name` (and the other `db.*`, and the ports) back from it — exactly like
the port handling above — and `config.json` is only a cache. So a hand-edit of
`db.name` in `conf/settings.properties` is honored on the next `start` and is
**never reverted from `config.json`** by `restart`/`start`.

`setup` **always persists `db.name`** and never drops it on a re-run: a later
`setup -Force` (e.g. just to change a JVM flag) reads the current `db.name`
straight from `settings.properties` and writes it back verbatim — it does not
fall back to the per-project auto-name or the shared default DB, even if
`.lsfusion-dev/` was wiped. `setup -DbName <x>` writes the new name into
`settings.properties` **and** `config.json` together (no `-Force` needed); to
repoint at a different database you must say so explicitly with `-DbName`.

**Watch out for a repo-committed `db.name`**: when a cloned project ships
`conf/settings.properties` with a `db.name` line, that committed value wins
over the per-project default — every clone of the repo then points at the
same database. `setup` warns when it first sees this; pass
`setup -DbName <unique> -Force` to give the instance its own DB.

## Standard workflow

Work through these steps. Stop and tell the user if a step needs their input
(for example a missing program or the PostgreSQL password).

### 1. Check the environment

Run `check`. It reports Java, PostgreSQL, Python, git, and Maven.

- **Java 11+** is required (1.8 works but 11 is the safest target). If Java is
  missing, ask the user to install a JDK — do not try to install it silently.
- **PostgreSQL** must be installed and accepting connections. If it is missing,
  stop and tell the user; the server cannot run without it.
- **Python 3** is needed for the `verify` command — it drives Playwright.
  Playwright itself (plus its bundled Chromium, ~120 MB) is auto-installed on
  the first `verify` run. If Python is absent, `verify` is unavailable but the
  rest of the skill still works.
- **git** is needed for the `clone` command — the first step when working with
  an existing project hosted in a Git repository (see [Working with an existing
  project](#working-with-an-existing-project)). Not required if you scaffold a
  new project or run sources already on disk. If git is missing and the user
  wants to clone a repo, ask them to install it.
- **Maven** is needed only for **Maven-based projects** (a `pom.xml` at the
  project root). When Maven is on `PATH` the skill builds with it and pulls
  `lsfusion-server` straight from `pom.xml` (no jar download, exact dependency
  graph). Without Maven the skill still runs such projects by staging the build
  itself against the downloaded server jar — so Maven is **recommended but not
  strictly required**, even for a `pom.xml` project. For a non-Maven project it
  is not needed at all.

### 2. Set up

**Pick a short app id first — always pass `-AppId` on the first setup of a
project.** When creating an application, choose a short identifier for it —
lowercase letter first, then letters/digits/underscores, ≤ 30 chars, e.g.
`clinic` for a clinic-management app — derived from what the app *is* (its
domain or project name), not from the folder path. This one identifier **is
the project's `db.name`** and covers everything downstream:

- it is the **PostgreSQL database name** — `-AppId x` is in effect a
  validated `-DbName x` (pass one or the other, not both), and
- it becomes the **web context path**, derived from `db.name` with no extra
  key to keep in sync: the client war is deployed as `<app id>.war`, so the
  UI lives at `http://localhost:<web port>/<app id>/` (the root `/` serves a
  redirect there).

Tell the user which id you picked. If `setup` runs without `-AppId`, the skill
derives a fallback id from the folder name plus a 4-hex path hash (e.g.
`clinic_3f9a`), so two same-named checkouts still get distinct databases — but
a deliberately chosen id is shorter and nicer, so don't rely on the fallback
for a new app. The id is persisted as `db.name` in `settings.properties` (the
usual source of truth) and survives re-setups. **Changing it later
(`setup -AppId <new>`) repoints BOTH the database and the web context**: the
deployed war is renamed in place, but the data stays in the old database —
setup warns about this; if you only want to move the web context while keeping
the data, don't change the id. A `db.name` set via `-DbName` that is not a
valid context name (uppercase, dots, a stock Tomcat webapp name) is accepted
as the database name, and the web client then simply deploys at the context
root `/` as before.

You also need the PostgreSQL connection details. The defaults are server
`localhost` and user `postgres`. The PostgreSQL **password** is
installation-specific — ask the user for it if `check` could not connect, then:

```
powershell -ExecutionPolicy Bypass -File .claude/skills/lsfusion-dev/scripts/lsfdev.ps1 setup -AppId <short id> -DbPassword "<password>"
```

`setup` downloads ~410 MB (server jar 146 MB, client war 251 MB, Tomcat ~12 MB),
so it takes a while — run it with a generous timeout and tell the user it is
downloading. The client war is **moved straight into Tomcat as `<app id>.war`**
(that war name is what makes the web context path `/<app id>`) and the download
is not retained, so only the server jar and Tomcat stay on disk. `setup` also
writes `settings.properties` and a starter `.gitignore` entry. Changing the app
id later renames the deployed war in place (no re-download) — and, since the id
is `db.name`, repoints the database as well.

**Which lsFusion version.** **Default to `-Version 7`** — the latest 7.x
build on the download server. The `7` alias tracks the highest 7.x available
(currently `7.0-SNAPSHOT`) and rolls forward to the 7.0 stable release once
it ships. Pick it when the user gives no version cue: 7.x carries the newest
platform behaviour the skill is tuned for (for instance, headless `verify`
relies on 7.0's automatic tooltip suppression instead of a workaround).

Because the latest 7.x is a SNAPSHOT today, **mention once** to the user that
SNAPSHOT builds can change daily, sometimes break, and may not be available
through the apt installer used by deploy workflows — and that `-Version
stable` (the latest non-SNAPSHOT release, currently 6.2) is there when they
want a fixed, production-matching build. Don't switch tracks on your own.

Switch off the default **only** when the user clearly asks for it — e.g.
"stable", a specific tag (like `6.2`), a major-version alias, or when the
project itself pins a version (its `pom.xml` parent declares a specific
version, or its README requires it). In that case pass `-Version
<alias-or-tag>`. If the cue is ambiguous, **ask** rather than guessing —
major versions differ a lot.

Which exact version each alias resolves to is **not stable** — it depends on
what the download server currently publishes. Always run `lsfdev.ps1 versions`
to see how `7`, `stable`, `dev`, major-number aliases, and concrete tags
resolve right now, before locking in a non-default choice. To switch later,
re-run setup with the new alias and `-Force`; the skill removes the stale
server jar and clears the init marker so the next start is a full one (fresh
stats and Reflection sync for the new platform's module set).

### 3. Write the `.lsf` code

Follow the MCP rules above (guidance first, then a docs lookup per construct).

**Default scaffold for a new from-scratch project.** Use the standard
**Maven-style directory layout** that every existing lsFusion solution
ships with. The skill's runtime auto-detects this layout (with or without
Maven on `PATH`) and the deploy skill expects it too, so this is the path
of least surprise for everything downstream.

Create the following tree at the project root (where you run `lsfdev.ps1`):

```
<project-root>/
├── src/
│   └── main/
│       ├── lsfusion/
│       │   ├── <Project>.lsf          # top module — only REQUIRE, no own code
│       │   └── main/
│       │       └── Main.lsf           # first feature module — real logic lives here
│       ├── resources/
│       │   └── lsfusion.properties    # logics.topModule = <Project>
│       └── java/                      # (optional) Java action classes; create
│                                      # on demand when an .lsf needs INTERNAL
```

A bigger project just adds more sibling feature dirs under
`src/main/lsfusion/` (`accounting/`, `crm/`, `inventory/`, …) and more
resources under `src/main/resources/` (`<Project>ResourceBundle.properties`
for i18n, `<Project>Icons.properties`, `images/`, `sql/`, `web/`).
Browse any existing lsFusion solution repository to see a fully populated
example.

**Why two `.lsf` files, not one.** The top module's *only* job is to pull
everything else in via `REQUIRE`. It contains no classes, properties,
actions, or forms of its own. Adding a new feature later is then "create
`feature/Feature.lsf` → append `, Feature` to the `REQUIRE` list in
`<Project>.lsf`" — `logics.topModule` never changes, neither does the
deploy jar's `lsfusion.properties`, no `-Force` re-setup is needed, and
the user's modules stay organized as siblings instead of piling into one
growing file.

**Default REQUIRE list for the top module.** Always pull in these
platform modules — they're small, broadly useful, and projects almost
always need them later anyway:

- **`Icon`** — icon vocabulary for forms / navigator entries
- **`Eval`** — evaluating lsFusion expressions at runtime (used by the `/eval` HTTP API, various dev/admin tools)
- **`ProcessMonitor`** — built-in dashboard for running threads/queries; invaluable when debugging stuck operations
- **`Backup`** — built-in DB backup/restore actions

Minimal contents:

```lsf
// src/main/lsfusion/<Project>.lsf — the top module. Wiring only.
MODULE Project;

REQUIRE Icon, Eval, ProcessMonitor, Backup,
        Main;
```

```lsf
// src/main/lsfusion/main/Main.lsf — the first feature module.
MODULE Main;

REQUIRE System;

// classes, properties, forms, navigator entries go here...
```

```properties
# src/main/resources/lsfusion.properties
logics.topModule = Project
```

After creating the tree, just run `setup` (or `start` if setup is already
done). The project's own `lsfusion.properties` sets the top module; you
don't need to pass `-TopModule` separately. If Maven is on `PATH`, the
skill switches to Maven mode automatically once you add a `pom.xml`; if
not, `start-server` stages the project itself — it copies
`src/main/resources/**` and `src/main/lsfusion/**` into `target/classes/`
(and `javac`-compiles `src/main/java/**` if present), then launches the
JVM with classpath `target\classes;<server jar>`. Both modes work
without any extra flags. Putting source roots **and** the project root
on the classpath together is deliberately avoided — lsFusion would
discover the same `.lsf` file through two paths and fail at startup with
*"module 'X' has already been added"*.

**If the user has existing `.lsf` files in the directory** (cloned repo,
copied snippet, hand-written single file), use the project's own
structure as-is — don't restructure on top of an existing layout.

### 4. Run and monitor

Run `start` (or `restart` after later edits). `start-server` tails the log and
returns one of three verdicts:

- **started** — the log shows `Server has successfully started`. Good.
- **failed** — the process exited. The script prints the error tail; read it,
  fix the cause (see [references/runtime.md](references/runtime.md) for common
  failures: DB connection, schema, `.lsf` syntax, Java module access), and
  `restart`.
- **inconclusive** — still starting after the timeout. Run `log` to see more.
  Don't bump the timeout to 10 minutes on principle — poll the log
  frequently (every 10–20 s) instead; you'll catch a started/failed signal
  earlier and you won't sit around when the startup actually takes 40 s.
  Default `-Timeout` is fine; raise it only if you're explicitly working
  around a long first-time schema sync (see the lightstart policy below).

`.lsf` syntax errors surface here, in the server log. Read them carefully and
correct the code with help from `lsfusion_retrieve_docs`.

**Dev-mode startup.** For local development the server always starts with
`-Dlsfusion.server.devmode=true` plus the three dev-only drop flags
`-Ddb.denyDrop{Modules,Tables,Properties}=false`. The drop flags let the
schema sync remove modules/tables/columns that disappear from the
`REQUIRE` graph (or shrink when a platform upgrade ships a different
module set), instead of aborting startup with *"Dropping modules /
tables / properties is restricted by settings"*. Production deployments
override these in their own `settings.properties`. One side effect worth
remembering: **in devmode lsFusion auto-authenticates as `admin`, so the
web client opens directly on the navigator and the login form never
appears** — both for the user's browser tab and for the headless `verify`
run. (The default credentials matter only outside devmode.)

**Database binding is pinned and then verified — read the verdict.** The
launch line also carries `-Ddb.name` (plus `-Ddb.server`/`-Ddb.user`/
`-Ddb.password` when set), mirroring the values resolved from
`settings.properties`; `-D` is the strongest resolution layer, so the server
provably lands on the reported database even if a settings-file layer is
mis-parsed (a BOM-damaged file, a platform regression — a real incident put
a project's data into the shared default DB `lsfusion` this way, where a
neighbour server's schema sync then wiped it, while ports from the same file
applied fine). After `Server has successfully started`, `start-server` checks
the **actual** connection through `pg_stat_activity` and prints
`Database binding verified: … connected to '<name>'` — or a loud
`DATABASE MISMATCH`. Treat a mismatch as stop-the-line: stop the server and
investigate before writing any data (runtime.md, *"silently ignores
db.name"*). `status` shows the same at a glance as `Database: <name>
(N connections)`; 0 connections under a running server is the same red flag.

**UI language.** On a host with a non-English locale the system UI
(navigator, captions, validation messages) comes up in the **host
language** — the server JVM inherits the OS locale **silently** (verified
on a pl-PL host: Polish web UI, Polish log dates, Polish system captions;
the script-compiler `[error]` texts stay English, so errors give no hint).
`setup`, `check` and every server start now print a warning with the fix
when the host locale is non-English and the JVMs don't pin one. The
resolution chain, strongest first:

1. **Server JVM locale** — this is what actually governs the system
   captions. Force it with `setup -JvmArgs "-Duser.language=ru
   -Duser.country=RU"` (then `restart`).
2. **Web-client JVM** — same flags via `setup -TomcatOpts "..."` for
   client-side strings (the connect/error pages come from this JVM, so
   pin BOTH or the two halves speak different languages).
3. **Per-user `Authentication.language`** — user-level localization;
   setting `language(u) <- 'ru'` alone does **not** re-localize the system
   captions, so don't stop there.
4. **Browser locale** — browser-side negotiation only (`verify -Locale
   ru-RU` for matching screenshots).

One thing the flags do **not** heal after the fact: system captions are
also **persisted into the database** (Reflection tables) during the
instance's first real use, and they keep that first language — restarts
never rewrite them (measured: a server switched to `-Duser.language=en`
shows an English navigator while `caption(NavigatorElement)` still answers
Polish; even a later `-FullStart` did not rewrite). The live UI is what
mostly matters, but if reflection-driven forms must match too, pin the
locale **before** the first start of a fresh database.

**Lightstart: leave ON.** Devmode enables `-Dlsfusion.server.lightstart=true`;
that's the default for every `restart`. Same code loads either way — lightstart
skips reloading user-side DB-stored UI prefs (table-view layout, security
policy) **and the Reflection metadata sync**: `Reflection.Action` /
`Reflection.Property` rows are not synchronized under lightstart, so anything
that references logic **by canonical name** (scheduler tasks — the platform
resolves the picked action via `actionCanonicalName()` — or reflection-driven
admin forms) **silently gets NULL** for actions/properties added since the
last full start; a scheduler task then saves with an empty action instead of
erroring. That is the one debugging case where `-FullStart` IS the fix: after
adding actions referenced by canonical name, run **one** `restart -FullStart`,
then return to lightstart. Otherwise don't propose `-FullStart` as a debugging
step — it's not a fix for "Property not found", schema drift, or compile
errors. Lightstart is **forced OFF** when the init marker is absent or was
auto-invalidated (first launch, platform version switch, the configured DB
had to be re-created, `db.name` repointed) and when `-FullStart` is passed.
Detail and rationale: see
[references/runtime.md](references/runtime.md#lightstart).

**Polling, not waiting.** A typical lightstart restart is 30 s – 1 min; a
full first-time start can take a few minutes. Either way, poll the log
every 10–20 s — don't `-Timeout 600` and walk away. If a real long sync
is genuinely in progress, the log keeps printing real work and you can
extend the wait deliberately.

**Run `start`/`restart` in the foreground — never pipe it through a filter.**
`start-server` already polls the log itself and returns the moment it prints a
verdict (started / failed / inconclusive) — usually 10–40 s on a lightstart
restart — so the command's own stdout is your signal; it does **not** block for
the full `-Timeout`. Wrapping the invocation in a pipe or attaching a very long
timeout can make the agent's shell tool classify the command as long-running
and **run it in the background**. You then sit waiting for a task-completion
notification and polling `status` in a loop — pure dead time the command never
needed. **Any pipe counts** — `| tail`, `| head`, `| grep`, `| Select-String`,
`| ForEach-Object` — the filter you pick doesn't matter, the pipe itself does;
an observed failure mode is exactly `restart | Select-String '==='` going to
the background on a one-minute lightstart restart. There is nothing to filter
anyway: the output is already a compact verdict (the full java command line is
written to `.lsfusion-dev/launch-cmd.txt`, not echoed). Let it run in the
foreground and read the verdict it prints. If you really do want to background
a long first-time sync, do it deliberately (the shell tool's
`run_in_background`), not as an accidental side effect of a pipe.

**Refresh PostgreSQL statistics after a first start or a big schema change —
call `analyzeDBAction()`.** lsFusion emits large, join-heavy SQL. On a
freshly-loaded dev DB — or after a sync that created/changed many tables —
PostgreSQL has **no planner statistics** for those tables, so the first form
opens and counts can crawl until autovacuum eventually catches up. The
platform ships a built-in maintenance action for exactly this:
**`analyzeDBAction()`** (from the system `Service` module — also callable as
`Service.analyzeDBAction()`), which runs PostgreSQL `ANALYZE` on the
server's own connection. This is *not* the same as lsFusion's
`Recalculating stats and materializations at the first start` log line —
that fills the platform's **internal optimizer** stat tables, which is
separate. Once the log shows `Server has successfully started`, call it once
through the skill's `api` command (devmode auto-authenticates):

```
lsfdev.ps1 api -Script "analyzeDBAction();"
```

Calling the action (rather than raw `psql`) works uniformly with no psql
client on PATH and no DB credentials to dig out. Skip it for ordinary
edit→restart cycles; it only matters after the first full schema load or a
sync that touched many tables.

> **UTF-8 / non-ASCII pitfall.** Put any non-ASCII script text (Cyrillic
> names, localized strings) in a UTF-8 file and pass `-ScriptFile` — never
> inline via `-Script` (the Windows argv boundary mangles it to `?` before
> anything is sent) — and judge responses by the bytes of a saved file, not
> console output (console pipes fabricate mojibake that is not in the data).
> The transport itself is fine; mechanics and verified details are in the
> **lsfusion-eval** skill:
>
> ```
> lsfdev.ps1 api -ScriptFile "C:/Work/proj/.lsfusion-dev/seed.lsf"
> ```

**Restart only for schema changes. For runtime data operations, use
lsfusion-eval — do NOT create a module and restart.** A `restart`
exists to reload the *schema*: new classes, properties, forms,
actions, events, constraints, migration steps. Everything else —
seeding test data, running a one-off fix, ad-hoc count / lookup,
calling an existing action with specific arguments — is **data**, not
schema, and belongs on the running server.

**Before a schema restart, run `precheck` — a sub-second linter for the
whole `.lsf` surface.** A restart is the only way to *load* new schema,
but it's a slow way to discover a typo: a failed restart costs 26–41 s
and reports **one name error per cycle** (parse errors do come batched).
`precheck` feeds each file to the running server's `/eval` endpoint
(headers stripped, line numbers preserved), which compiles it in a fixed
order (parse → EVAL-restriction → name resolution) in ~30 ms:

```
lsfdev.ps1 precheck -ProjectDir "C:/Work/proj"                # all .lsf under src/main
lsfdev.ps1 precheck -ProjectDir "C:/Work/proj" -Files 'src\main\lsfusion\Invoice.lsf'
```

A parse error means bad syntax; `... is not found` means a missing
element / `REQUIRE`. One blind spot the other way: eval's throwaway
module depends on **every** loaded module, so a name your file uses
without the matching `REQUIRE` still resolves — an incomplete `REQUIRE`
list surfaces only at restart. When a file carries a load-only construct (`CLASS` /
`DATA … NONULL` / `WHEN` / `CONSTRAINT`), eval answers `... cannot be
used in EVAL module` — precheck reports that as **syntax OK, names NOT
checked** (measured: the restriction preempts name resolution for the
whole script, wherever the construct sits). Two constructs crash eval's
compiler outright — `EXTEND FORM` and `() + { }` overrides of existing
actions — such files come back as "cannot lint: only a restart checks
this file". Do **not** use `api` for any of this: its `/eval/action`
endpoint wraps the script as an action body and any declaration dies
with misleading wrapped-brace parse errors. The lsfusion-eval skill's
"Syntax-checking `.lsf` without a restart" has the phase table and the
raw-curl form for remote servers.

**Web resources (JS / CSS / images) need NO restart in devmode — any page
load picks them up; browser cache is NOT a factor.** Files under
`src/main/resources/**` that the browser fetches — `CUSTOM`-component
`.js`/`.css` registered via `onWebClientInit`, icons, web assets — are served
live from source: on every page load the devmode server re-reads them from
`src/main/resources` and emits them under a content-hash URL
(`/file/dev/...?version=<hash of the bytes>`) with `Cache-Control: no-store`,
so the browser cannot hold a stale copy (verified: after a `.css` edit an
ordinary reload — no hard-reload, no cache bypass — served the new bytes
under a new `?version=`, server untouched). So after editing such a file,
**do not `restart` — reload the page**: a default `verify` starts a fresh
browser (always a reload); a `verify -Session` deliberately does NOT reload
the live page — pass `-Reload`, or re-run your `-OpenScript` (it re-navigates
anyway; see step 5). If an edit "doesn't apply", the page was not reloaded —
don't chase cache theories and don't restart the server. A `restart` is only
needed when you also changed the **`.lsf`** side (e.g. the `CUSTOM 'name'`
declaration, new form properties/actions the JS calls, the `onWebClientInit`
registration itself) — that's schema. Pure JS/CSS iteration is a sub-second
reload loop, not a 30 s restart loop.

**Report templates (`.jrxml`) — NO restart in devmode; iterate via
`target/classes`.** Like JS/CSS web resources, JasperReports templates are
read from the classpath at print time, so in devmode they are re-read live —
no server restart needed. The catch: `start-server` stages
`src/main/resources/**` into `target/classes/` only at startup, so editing
`src/main/resources/<name>.jrxml` alone does not take effect until the next
restart. To iterate without restarting, edit the staged copy
`target/classes/<name>.jrxml` directly and re-print; once the layout is
right, mirror it back to `src/main/resources/<name>.jrxml` (the source of
truth) so a later restart doesn't overwrite your work.

The lsfusion-eval skill talks to the live server's HTTP endpoints
(`/exec`, `/eval`, `/eval/action`) and accepts arbitrary
`NEWSESSION { NEW … APPLY; }` scripts. The same script that you'd put
inside an action body runs there directly. No `.lsf` file, no top
REQUIRE entry, no restart cycle — round-trip is sub-second instead of
30+ s.

Signs you are about to make this mistake: a `TestData.lsf` / `SeedData.lsf`
/ `Migration001.lsf` module written to be called once; a top-`REQUIRE`
entry the production config will never want; work shaped like "create N
rows / set property X", not "introduce a class / property / form". In all
three, stop and switch to lsfusion-eval — one-shot data manipulation
should never leave a trace in the codebase (a permanent module is for
actions the application genuinely needs later: admin tools, importers,
scheduled jobs).

### 5. Verify the result

Once `status` shows both processes up, **always verify in this fixed order
— cheapest, most diagnostic check first, expensive end-user check last.**
Don't lead with the UI; that's like running an integration test before
checking the unit-test output.

1. **Server log — first, always.** `lsfdev.ps1 log` (or read the tail
   already printed by `start-server` / `restart` directly). It tells you
   whether schema sync ran, whether modules/tables were dropped, which
   platform version actually loaded, and surfaces any silent
   `WARN`/`ERROR` lines. Both API and UI depend on these — if the log
   shows a failure, nothing further will work, and you'll waste time
   debugging the wrong layer if you start with screenshots.

2. **HTTP Action API.** Once the log is clean, run an lsFusion expression
   over `/eval/action` — via `lsfdev.ps1 api` (or the **lsfusion-eval**
   skill). The server resolves names, types, and security exactly as the
   app would, so a clean response proves your new class / property / form
   really exists in the running schema. Cheap, scriptable, exact — and
   tells you semantic truth without rendering. If the response or the
   script carries non-ASCII text, see the **UTF-8 / non-ASCII pitfall**
   note in step 4 (use the `api` command / `-ScriptFile`, not a raw `curl`
   POST body).

   **Reading values back and confirming mutations has sharp edges — the
   canonical recipes are in the lsfusion-eval skill** ("Getting values
   back", "Chaining and verifying"). In short: `RETURN <expr>;` is 7.0+
   only (a parse error on 6.x — use `EXPORT FROM res = <expr>;` there), a
   plain `MESSAGE` is visible **nowhere** over HTTP (not in the response
   and not in the server log — only `MESSAGE ... NOWAIT` leaves a
   `Server message:` log line), and a constraint-canceled `APPLY`
   returns the **same empty 200 as success** — so end every mutation script
   with a top-level self-check (no `NEWSESSION` wrapper), e.g.
   `APPLY; EXPORT FROM res = (OVERRIDE 'CANCELED: ' + applyMessage(), 'OK');`.
   The `api` command adds two safety nets of its own: it prints a
   version-appropriate hint whenever the body comes back empty, and it
   tails the server log for `Server message:` lines after every call —
   which surfaces `MESSAGE ... NOWAIT` output and the constraint text a
   canceled `APPLY` logs, but **cannot rescue a plain `MESSAGE`** (no
   `NOWAIT` → no log line → nothing to tail; use `RETURN`/`EXPORT` for
   anything you need to read back).

3. **UI, last.** When log + API agree the build is healthy, check the
   UI. The workhorse is `verify` — it exists in every harness, and the
   rest of this step documents it. **If the session exposes an in-app
   browser** (Claude Desktop's Browser pane — `mcp__Claude_Browser__*`
   tools — or a similar browser-automation surface), do the
   *interactive, content-level* part there instead; the split is
   specified in **"In-app browser vs `verify`"** at the end of this
   step. Either way the log → API → UI order stays.

   `verify` drives **Playwright** (headless Chromium) to:
   - screenshot the landing page → `.lsfusion-dev/verify-login.png`,
   - **if a login form is present**, log in as `admin` (empty password by
     default) and screenshot the result → `.lsfusion-dev/verify-app.png`,
   - dump the final DOM → `verify-dom.html` and the browser console →
     `verify-console.txt`.

   In devmode lsFusion auto-authenticates, so there is **no login form**
   and the landing screenshot already shows the navigator + forms. The
   first `verify` ever installs Playwright + Chromium (~120 MB); one-time.

   **To verify a specific form, open it directly with `-OpenScript` — the
   default; don't click through the navigator.** `verify` navigates the
   headless browser to `<web>/eval/action?script=<your code>`; the platform
   detects the interactive action in a browser navigation and routes it back
   into the web client (302 → `/push-notification` → service worker →
   `/main`), where the form opens exactly as if a user had opened it —
   screenshot → `verify-open.png`. Because the payload is an ordinary action
   script it is fully parameterizable — a named form, a form with bound
   objects, or the edit card of one specific object:

   ```
   # a navigator form by name
   lsfdev.ps1 verify -OpenScript "SHOW Shop.items DOCKED;" -OpenExpect "Items"

   # the edit card of one object, looked up by business key
   lsfdev.ps1 verify -OpenScript "FOR Shop.name(Shop.Item i) = 'Coffee beans' DO SHOW EDIT Shop.Item = i DOCKED;" -OpenExpect "Coffee beans"

   # ...or by internal id (grab it beforehand with api: EXPORT FROM id = Shop.Item i, ...)
   lsfdev.ps1 verify -OpenScript "FOR LONG(Shop.Item i AS Shop.Item) = 32178 DO SHOW EDIT Shop.Item = i DOCKED;"
   ```

   - **Open the form in the window mode it will have in production — for
     navigator forms and edit cards that means `DOCKED`, as in every example
     above.** In this call context a bare `SHOW` defaults to a *floating*
     window (synchronous → `FLOAT`), which is **not** how the user will see
     the form: everything reachable from the navigator, and edit cards,
     open as `DOCKED` tabs filling the forms panel. A float renders the
     form in a small centered window, so the layout you screenshot (column
     widths, flex fills, collapsed containers) differs from the real thing
     — append `DOCKED` to judge the actual `DESIGN`. Use `FLOAT` (or
     `EMBEDDED`/`POPUP`) only when the form genuinely opens that way in
     prod — e.g. it is shown via `DIALOG` or `SHOW … FLOAT` in the code.
     Best of all, when prod opens the form through a project action, call
     *that action* in `-OpenScript` — the window mode (and filters,
     session) come along for free.
   - **Qualify every name with its namespace** (`Shop.items`, not `items`).
     The script compiles against *all* loaded modules — a bare name that is
     unique in your module (`name`, `date`, …) is routinely ambiguous here.
     Same rule as `api` scripts.
   - `-OpenExpect "<text>"` waits for that visible text on the opened form
     (caption, field label, a known cell value) and reports found /
     not-found — that's your assertion; without it you just get the
     screenshot.
   - Non-ASCII script text (Cyrillic keys, localized captions) → UTF-8 file
     + `-OpenScriptFile`, exactly like `api -ScriptFile` (see the UTF-8
     pitfall in step 4).
   - A script error (unknown form, missing namespace, typo) surfaces as the
     server's error text in the verify output — fix and re-run; nothing to
     screenshot-guess.
   - `SHOW EDIT <Class> = <obj>` opens the class edit form (the one declared
     with `EDIT <Class> OBJECT <o>`, or the auto-generated one); `SHOW
     <form> OBJECTS <o> = <expr>` opens any form with objects bound.
   - Verified on 6.2 and 7.0-SNAPSHOT. Needs the web client up; in devmode
     it rides the auto-auth admin session (on a non-devmode install the
     call is gated by `enableUI`/`enableAPI` — admin or `@@api` actions).

   **To test the user's path, use `-Click` / `-DoubleClick`** — reach for
   them when the *navigation itself* is what you're verifying (the navigator
   entry exists, is reachable, opens the right form), or to compose with a
   direct open (`-OpenScript` to open a list form, then `-DoubleClick` a row
   to open its card like a user would):

   ```
   lsfdev.ps1 verify -Click "Master data > Items"
   lsfdev.ps1 verify -Click "Master data > Items" -DoubleClick "Coffee beans"
   ```

   `-Click` clicks navigator entries by their visible text (chain with `>`
   for tab-then-entry) → `verify-click.png`; `-DoubleClick` then
   double-clicks the grid row containing that text and screenshots its edit
   card → `verify-dblclick.png`.

   **To drive elements `-Click` cannot reach — buttons/inputs inside `CUSTOM`
   (React) components, filters, dialogs — pass `-Do`**: an ordered list of
   generic interaction steps, run after the `-OpenScript` open /
   `-Click`/`-DoubleClick` navigation, each `verb:rest` with **any Playwright
   selector** (css, `text=...`, `button:has-text(...)`):

   - `click:<selector>` / `dblclick:<selector>` — e.g. `click:text=Поставить`
     hits a React button by its caption;
   - `hover:<selector>` — real mouse-over (tooltips, hover-revealed handles);
   - `drag:<selector>=><selector>` — a **real gesture**: `mousedown` on the
     source, intermediate `mousemove`s, `mouseup` on the target — what
     drag-to-draw UIs (Gantt dependency links, resize handles, sliders)
     actually listen for. `click`/`dblclick`/`hover`/`drag` selectors accept
     an `@x,y` offset from the element's top-left corner
     (`drag:.task-a@120,8=>.task-b@4,8` starts from a bar's edge connector);
   - `mouse:down[@x,y]` / `mouse:up[@x,y]` / `mouse:move@x,y[,steps]` — raw
     viewport-coordinate primitives when even `drag:` isn't enough (multi-leg
     gestures, precise paths). `move` glides in 12 interpolated steps by
     default — each waypoint is dispatched with a small settle, because rapid
     CDP moves get coalesced into 1–2 DOM events on a busy page and drag-draw
     handlers never see the path;
   - `fill:<selector>=><value>` — set an input's value (`=>` separates
     selector from value; a plain last `=` also works);
   - `type:<selector>=><value>` — same but pressing real keys, for React
     inputs that ignore programmatic fills;
   - `press:<key>` (e.g. `Enter`), `eval:<js>` (result lands in the report),
     `wait:<ms>`.

   ```
   lsfdev.ps1 verify -Click "Расписание" -Do "fill:input.comment=>Иванов", "drag:.gantt-task-a=>.gantt-task-b", "click:button:has-text('Поставить')"
   ```

   The chain stops at the first failed step; each step's ok/error (and every
   `eval` result) is printed, and the post-chain state goes to
   `verify-do.png`. Non-ASCII values in `-Do` cross the same argv boundary as
   `api -Script` — when calling through bash + `powershell.exe`, put Cyrillic
   text in an `eval:` step or run the command via an in-process PowerShell
   tool instead (see the UTF-8 pitfall in step 4).

   **Iterating on a multi-step scenario? Add `-Session`.** By default every
   `verify` run starts a fresh browser and pays the navigation (and the slow
   first form open) again. With `-Session` the skill keeps one persistent
   headless browser per project (detached Chromium on a derived CDP port) and
   **continues the same live page on the next call** — navigation state, the
   open form, even your `eval:` JS globals survive. While the page is anywhere
   on the app (the base URL or `/main`, where `-OpenScript` lands) a session
   call **never reloads or re-navigates it implicitly**. So: navigate once
   (`verify -Session -OpenScript "SHOW ...;"` or `-Click "Расписание"`), then
   iterate cheaply (`verify -Session -Do "drag:..."`, look at `verify-do.png`,
   adjust, run again). Two consequences of "the page lives on":
   - **Edited JS/CSS are not picked up** until the page reloads (they are
     fresh on *every* load — see the web-resources note in step 4 — but an
     un-reloaded page keeps the code it already runs). Pass `-Reload` to
     force a fresh page, or simply re-run the `-OpenScript` call — it
     re-navigates, so one call both reloads the code and reopens the form.
   - Any reload/navigation **resets the app to its default state** (the web
     client boots a new server-side navigator, closing open forms) — that is
     why `-Reload` is explicit and never implied.
   The session ends with `verify -EndSession`, and `stop`/`restart` close it
   too (a page from before a schema restart would be stale). `-Locale` has no
   effect on an already-running session.

   **When a `-Click` misses, the output tells you why — read it before
   theorizing.** A failed click is classified from Playwright's own log and
   reported as one of: **not found** (no element with that visible text — the
   output then prints the actual clickable captions harvested from the
   failure-time page: `Clickable navigator captions: ...`, so pick from that
   list instead of guessing); **intercepted** (element found and visible, but
   an overlay — loading glass, sliding panel, hover popup — swallowed every
   click; a forced click is attempted automatically and reported); or **not
   visible** (the text exists in the DOM but is CSS-hidden, e.g. icon-only
   navbar entries — text-based `-Click` cannot hit those, use `-Do
   'click:<css>'` with a selector from `verify-dom.html`). Captions and row
   text are locale/data-dependent — trust the printed caption list and
   `verify-app.png` / `verify-click.png` over any assumption about what the
   captions "should" be. `-Click`/`-DoubleClick`/`-Do` cover "did it render"
   checks and single-form interactions; for anything bigger — multi-form
   flows, assertions between steps, remote hosts — **don't fight `verify`**:
   drive the flow in the in-app browser when the session has one (see the
   split below), or **write a real Playwright script.** The lsfusion-eval
   skill's Part 3 ships a ready Python template (login, waits, and
   lsFusion-specific selectors already handled) — start from it, not from
   scratch (the direct-open URL mechanism above is documented there for
   hand-written scripts too).

   The viewport defaults to **1920×1080** — judge layout at a realistic
   size before calling it broken: on a narrow viewport dense forms
   (calendars, wide grids) legitimately collapse into `+N more`
   placeholders and the screenshot *looks* buggy while the app is fine.
   Override with `-ViewportWidth/-ViewportHeight`, and pass `-Locale`
   (e.g. `ru-RU`) when the browser-side language matters for the shot.

   **First form open after a `restart` is slow — use generous Playwright
   timeouts.** Opening a non-trivial form the first time after a restart
   takes ~10–40 s (the server lazily builds the form, and a Maven project
   may still be finishing compile). A naive `wait_for_selector(..., timeout=15000)`
   or short fixed wait will time out and look like a failure when the page
   is merely still building. For the *first* navigation after a restart,
   wait **40–60 s** for your target selector (and a few seconds' settle
   after the navigator click before clicking into a form). Subsequent
   opens in the same server lifetime are fast. A lone timeout here is
   almost always cold-start latency — re-run with a longer wait before
   concluding the UI is broken.

   **Put the budget in selector timeouts, never in fixed sleeps.** A
   selector wait (`wait_for(..., timeout=60000)`) returns the instant the
   element renders — an oversized budget costs nothing on a fast run. A
   fixed sleep (`wait_for_timeout(15000)` "to be safe") burns its full
   duration on *every* run: three such sleeps in a screenshot script is
   ~20 s of guaranteed dead time per invocation. Reserve fixed waits for
   sub-3-second UI settles (animation, focus) where no selector exists.

   **In-app browser vs `verify` — the split.** Some sessions expose an
   in-app browser as tools (Claude Desktop's Browser pane:
   `mcp__Claude_Browser__*` — `navigate`, `computer`, `read_page`,
   `get_page_text`, `find`, `form_input`, `read_console_messages`,
   `read_network_requests`). When present, prefer it for **interactive,
   content-level** checks and keep `verify` for the cases below; when
   absent (terminal CLI, headless runs, subagents, CI), `verify` is the
   only path. In one line: **the pane for content and behaviour,
   `verify` for layout, gestures, and artifacts.**

   What works in the pane (measured against 7.0-SNAPSHOT):
   - **Direct form open is the same URL mechanism.** Load the app base
     URL first (that registers the service worker), then navigate to
     `<base>/eval/action?script=<SHOW ... DOCKED;>` (URL-encoded) — the
     302 → `/push-notification` → service-worker → `/main` dance works
     in the pane and the form opens exactly as with `-OpenScript`. All
     the `-OpenScript` rules above (DOCKED, namespace-qualified names,
     script errors returned as text) apply verbatim.
   - **Assert by reading, not by pre-declared matchers.**
     `get_page_text` / `read_page` return the rendered text — check the
     caption / cell values off that instead of betting an `-OpenExpect`
     string. This kills locale and lookalike-character misses (real
     case: Latin `-OpenExpect "KH0001"` reported not-found while the
     grid showed Cyrillic «КН0001»).
   - Clicks, fills, and key presses (`computer` + `find` +
     `form_input`) cover `-Click`/`-DoubleClick` and most `-Do` steps —
     with JSON parameters, so none of the PowerShell argv/UTF-8
     pitfalls.
   - `read_console_messages` shows the same errors `verify-console.txt`
     counts; `read_network_requests` adds the HTTP layer `verify` never
     captures. The page also persists across your tool calls —
     `-Session` semantics for free, with the same caveats (JS/CSS edits
     appear only after a reload; any reload boots a new server-side
     navigator and closes open forms).

   Where the pane is NOT sufficient — use `verify` (measured):
   - **Layout at production viewport.** Pane screenshots come back
     ~800 px wide regardless of viewport (1920×1080 → 800×450; dense
     grids illegible), and region zoom is unsupported. To judge
     `DESIGN` at 1920×1080 (the "+N more" collapse problem above), use
     `verify`'s full-resolution PNGs and Read them from disk. Shrinking
     the pane to ≤800 px is no workaround — that changes the layout
     under test.
   - **Real drag gestures.** The pane's drag delivers ~2 intermediate
     mousemoves (349 px jumps measured on a 700 px path), and multi-leg
     gestures are inexpressible — drag-to-draw UIs (Gantt links,
     sliders, resize handles) won't track it. Use `verify -Do
     "drag:..."` / `mouse:` steps, which interpolate the path.
   - **Evidence.** The pane leaves nothing on disk — no PNGs to attach,
     no JSON verdict, nothing re-runnable. When the user needs proof or
     a repeatable check, run `verify` even after eyeballing the pane.
   - **Capture flake.** Right after the pane opens, screenshots can
     time out (~30 s each) while `navigate`/`read_page`/JS run fine —
     and interaction actions are gated on one prior successful
     screenshot. Verify via `read_page`/`get_page_text` meanwhile, or
     fall back to `verify`; don't fight the capture loop.
   - **No password entry.** Typing credentials in the pane is
     off-limits for the agent. Irrelevant in devmode (auto-auth, no
     login form), blocking on a non-devmode target — there `verify` / a
     Playwright script does its own login.

**Verify print forms headless via PDF — don't assume.** There's no
browser/IDE preview here, so render server-side and read the result:

```
lsfdev.ps1 api -Script "LOCAL f = FILE (); PRINT myForm OBJECTS o = <expr> PDF TO f; WRITE f() TO 'C:/proj/.lsfusion-dev/out';"
```

`PRINT … PDF TO <fileProp>` renders on the server with no client interaction;
`WRITE f() TO '<path>'` dumps it to disk (extension auto-appended →
`out.pdf`). Open the PDF with your file-reading tool and actually eyeball it —
a wrong field name/type or band height only shows in the rendered output.
For template / field-mapping rules, retrieve the `Report_design` docs — the
guidance's report rules mandate that before touching any `.jrxml` anyway.

**Do not query PostgreSQL directly to inspect data.** lsFusion owns the
schema — table names are mangled (`<class>_<namespace>`, `_x_yz` columns),
property values live in normalized layouts that don't match the `.lsf`
declaration shape, and the physical layout can shift between platform
versions or after any `restart -FullStart`. A `SELECT` against the lsFusion
DB looks authoritative and is almost always wrong, misleading, or both.
Direct `psql` is a **last resort** — DBA-level recovery, debugging schema
corruption, or comparing physical layout between two installs. Before
running any `psql` / `pg_dump` / direct-SQL command against the project's
database, **ask the user first** and explain why the three lsFusion-layer
checks above (log → API → UI) aren't enough for the situation at hand. Do
not run direct DB queries silently just because you have the password —
even read-only ones can lead you to false conclusions you then act on.

### 6. Open the app for the user

**Every task that started or restarted the server ends here — non-optional.**
After `start` / `restart` succeeds — whether you scaffolded a new module,
edited existing code, fixed a server failure, or just brought the project up
for inspection — **always run `open`** so the user lands in the running
application and can click through it. `open` already targets the app's
context path (`http://localhost:<web port>/<app id>/`); quote that full URL,
context path included, whenever you tell the user where the app runs. Do not stop at "the server is up": the
user expects to actually use the UI and try out what you built. This step
applies even when `verify` already produced a screenshot for your own check —
the screenshot is for you, `open` is for the user.

In **devmode** (the skill's default) lsFusion auto-authenticates as `admin`,
so the browser lands straight on the navigator — no login screen, no
credentials needed. Mention this in your reply when you surface the URL,
especially if the user was expecting a sign-in page. If devmode is ever
disabled (or the user points the skill at a production server), the default
account is **`admin`** with **no password** (blank password field) — state
this explicitly so the user can sign in. After the first login the user can
change the password and add other users.

## Working with an existing project

The skill also runs lsFusion code that ships in a Git repository — typically a
Maven layout with `pom.xml` at the root, `.lsf` modules under
`src/main/lsfusion/<namespace>/`, and a `lsfusion.properties` under
`src/main/resources/`. The flow is the standard workflow with a clone step in
front of step 2:

1. **Clone** — `lsfdev.ps1 clone -GitUrl <repo URL> [-Target <dir>] [-Branch <name>]`.
   Drops the repo into a subfolder named from the URL (or the explicit
   `-Target`) and reports whether the layout looks like an lsFusion project.
   Requires `git` on `PATH`.
2. **`cd` into the clone**, or pass `-ProjectDir <path>` to every command, then
   run `setup -AppId <short id> -DbPassword <pwd>` exactly as for a new project
   (the app id names the database and the web context path). When the skill
   detects an existing project (any of `pom.xml`, `src/main/lsfusion/`, or a
   `lsfusion.properties`), it writes a **minimal** `settings.properties`
   containing only install-specific overrides — DB credentials, and other
   fields only if you passed them. The project's own `lsfusion.properties`
   keeps control of `logics.topModule`, namespaces, and the rest, so the skill
   does not silently change how the project loads.
3. **`start`, `verify`, `restart`** all behave the same. When the project has
   `pom.xml` **and Maven is on `PATH`**, the skill switches to Maven mode:
   - `setup` does **not** download `lsfusion-server-<ver>.jar` — Maven will
     pull it (and every other dependency) from `pom.xml`. Saves ~150 MB and
     guarantees the exact version the project expects.
   - `start-server` runs `mvn -q -DskipTests compile`, then
     `mvn dependency:build-classpath` (cached, refreshed only when `pom.xml`
     changes), and launches Java with the Maven-resolved classpath plus
     `target/classes` and the source roots. So the JVM runs with **exactly
     the dependency graph the project's `pom.xml` defines**.
   - First run is slow (Maven downloads deps); subsequent restarts are quick
     because both the compiled classes and the classpath are cached.
   If Maven is not on `PATH`, the skill still works — it falls back to the
   downloaded `lsfusion-server-<ver>.jar` and stages a Maven-style build
   itself: each `start-server` wipes `target/classes/`, copies
   `src/main/resources/**` and `src/main/lsfusion/**` into it, compiles
   any `src/main/java/**` Java sources via `javac -d target/classes`, and
   launches the JVM with classpath `target\classes;<server jar>`. The
   classpath stays exactly two entries — staging dir plus jar — which
   avoids the duplicate-module trap.

Pass `-TopModule <Name>` only if the project's own config does not set one
(rare). For everything else — code edits, dev-mode behaviour, light start,
verification — the workflow is identical to a scaffolded project.

When extending an existing project, **explore before adding**: use
`lsfusion_retrieve_docs` and any project-element search the MCP exposes to
understand the existing modules, namespaces, and conventions, then add new
elements that fit in.

## Where lsFusion reads its working parameters from

This is the platform-level resolution chain (lowest priority first, each
later layer overrides the previous one). Know it before you set `db.name`,
`db.password`, a drop guard, or any other tunable — guessing which file
"wins" is a recurring waste of debugging time.

1. **Hard defaults** baked into the platform code (`lsfusion.server.physics.admin.Settings.java`).
2. **`lsfusion.properties`** — the project's own config, loaded **from the
   classpath**. In a Maven layout this lives at
   `src/main/resources/lsfusion.properties` (gets staged into `target/classes/`
   at build time). Project authors put `logics.topModule`, namespace
   declarations, and other application-wide settings here.
3. **`conf/settings.properties`** — install-specific overrides, loaded **by
   relative path from the JVM's working directory**. lsfdev launches the JVM
   with cwd = `<project-root>`, so this resolves to
   `<project-root>/conf/settings.properties`. **This is the canonical place
   for `db.server`, `db.name`, `db.user`, `db.password`, `rmi.port`, and any
   override you want to apply at runtime without recompiling the project.**
4. **JVM `-D...=value` arguments.** lsfdev injects a few unconditionally:
   `-Dlsfusion.server.devmode=true`, `-Ddb.denyDrop{Modules,Tables,Properties}=false`,
   (when light start is on) `-Dlsfusion.server.lightstart=true`, and the
   **`-Ddb.*` mirror of the resolved `settings.properties` values** — a
   same-value duplicate that guarantees the database binding even if a file
   layer is mis-parsed (the file remains the source of truth between runs;
   lsfdev re-reads it and re-asserts `db.name` into `conf/settings.properties`
   before every launch). Any `-D` you add by hand wins over the file-based
   layers below (and, coming later on the command line, over lsfdev's own
   `-Ddb.*`).
5. **DB-stored settings** — `Administration → System → Settings → Parameters`
   in the UI. Useful for tunables that should survive a redeploy and that
   admins should be able to edit without filesystem access.
6. **Runtime overrides** via `Service.pushSetting[STRING, STRING]` /
   `Service.popSetting[STRING]` — temporary, scoped to one action / session.

**Do NOT put runtime overrides in `.lsfusion-dev/settings.properties`.**
That directory is lsfdev's own internal state (cached classpath,
`config.json`, generated logs, the downloaded server jar). The JVM never
reads anything from there. If you put a `db.name = ...` line there
expecting it to take effect, it is silently ignored and the server keeps
using whatever the resolution chain above produces.

**lsfdev's setup flow:**
- `-DbPassword`, `-DbUser`, `-DbServer`, `-DbName` flags passed to
  `lsfdev.ps1 setup` are written into the right files for you — you don't
  need to touch `conf/settings.properties` by hand unless you want to.
- For ad-hoc overrides between sessions, edit `<project-root>/conf/settings.properties`
  directly (layer 3 above) or pass `-Dkey=value` in `FUSION_OPTS` (layer 4).

## Notes

- All downloads and runtime state stay in `.lsfusion-dev/`. `setup` adds it to
  `.gitignore`. Generated settings files at the project root and
  `<project-root>/conf/settings.properties` contain the DB password in
  plain text (this is how lsFusion works) — mention this to the user if
  the repo is shared. The same password also appears on the server's java
  command line (`-Ddb.password`, the binding belt) and thus in
  `.lsfusion-dev/launch-cmd.txt` and the local process list — equivalent
  exposure on a single-user dev box, but worth knowing.
- Deeper runtime details, all config keys, and a troubleshooting table are in
  [references/runtime.md](references/runtime.md) — read it when a command fails
  or the user asks about configuration.
