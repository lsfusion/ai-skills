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

> **Companion MCP server — `lsfusion-ai`.** This skill is paired with the
> [`ai.lsfusion.org`](https://ai.lsfusion.org/mcp) MCP server (registered under the
> name `lsfusion-ai` by the `lsfusion-ai-skills` plugin). Prefer its tools over
> guessing lsFusion syntax or behaviour:
>
> - **`mcp__lsfusion-ai__lsfusion_get_guidance`** — call this **first**, at the start
>   of any lsFusion task, if its guidance isn't already in context, and then follow
>   every rule it returns.
> - **`mcp__lsfusion-ai__lsfusion_retrieve_docs`** — semantic search over the official
>   docs (`language` / `paradigm` / `how-to` / `brief` / `rules`); use it to confirm
>   syntax, operators, and concepts instead of guessing.
> - **`mcp__lsfusion-ai__lsfusion_report_feedback`** — submit a docs/behaviour feedback
>   signal, but **only after the user explicitly consents**, and never send source
>   code, file paths, or schema/customer names.
>
> If these tools aren't available the server isn't installed — see the
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
  logic, talks to PostgreSQL, exposes RMI on port `7652` and an HTTP Action API
  on port `7651`. Started with `java -cp ".;<jar>" lsfusion.server.logics.BusinessLogicsBootstrap`.
- **Web server** — the `lsfusion-client-<ver>.war` deployed in Apache Tomcat.
  Serves the browser UI on `http://localhost:8080/` and connects to the
  application server over RMI (port `7652`).

A change to any `.lsf` file requires **restarting the application server** (the
web server does not need a restart).

## CRITICAL: writing `.lsf` code

An lsFusion MCP server is connected. For **any** task that involves reading or
writing lsFusion code you **must** use it — this is non-negotiable and the MCP
itself enforces it:

1. Call `lsfusion_get_guidance` once at the start of an lsFusion task (if its
   rules are not already in context) and follow the rules it returns.
2. Use `lsfusion_retrieve_docs` to look up exact syntax and semantics before
   writing or changing code. Query in English for best recall.
3. Reason about elements in order: **modules/classes → properties → actions →
   forms → events/constraints**. Do not jump straight to forms.

Do **not** invent lsFusion syntax from memory. See
[references/workflow.md](references/workflow.md) for the code-writing loop and a
minimal working module.

## The `lsfdev.ps1` CLI

All environment and runtime operations go through one PowerShell script. Invoke
it with a bypassed execution policy so it runs regardless of system settings:

```
powershell -ExecutionPolicy Bypass -File .claude/skills/lsfusion-dev/scripts/lsfdev.ps1 <command> [options]
```

`-ExecutionPolicy Bypass` is **required** on a default Windows install: without
it PowerShell refuses to load unsigned `.ps1` files with
`UnauthorizedAccess: running scripts is disabled on this system`. The flag
bypasses the policy for this one invocation only — it does not change any
system setting. Do **not** drop the flag to make permission prompts go away;
that breaks the script for everyone whose execution policy is not
`RemoteSigned` (the default on personal Windows machines is `Restricted`).

**Heads-up on the auto-mode classifier — prefer accept-edits from the start.**
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

| Command | What it does |
|---|---|
| `check` | Detect Java, PostgreSQL, Chrome; report versions and what is missing. |
| `versions` | List the lsFusion versions on the download server and the alias mappings. |
| `setup` | Fetch the server jar, client war, and Tomcat into `.lsfusion-dev/` (only what's missing / version-changed — see note); write config + `settings.properties`. Safe to re-run anytime. |
| `start-server` | Start the application server, tail the log, and report a verdict (started / failed / inconclusive). |
| `start-web` | Start Tomcat with the web client; wait until the UI responds. |
| `start` | `start-server` then `start-web`. |
| `restart` | Stop everything, then `start`. Use this after editing `.lsf` files. |
| `stop` | Stop the application server and Tomcat. |
| `status` | Show which processes/ports are up. |
| `log` | Print the tail of the server log and flag errors. |
| `verify` | Headless-Chrome screenshot + DOM dump of the web UI into `.lsfusion-dev/`. |
| `open` | Open the web UI in the user's default browser. |
| `api` | Call the HTTP Action API (advanced verification — see workflow.md). |

Key options: `-DbPassword`, `-DbUser`, `-DbServer`, `-DbName`, `-Version`
(`stable` — default; `dev`/`snapshot`; a major-version alias; or an exact
tag — see below), `-TomcatVersion`, `-TopModule`, `-RmiPort`, `-HttpPort`,
`-WebPort`, `-ShutdownPort`, `-FullStart`, `-Url`, `-Script`, `-Timeout`. Run
the script with no command to print full usage.

If port `8080` is taken (e.g. another Tomcat), pass `setup -WebPort <free port>`
— the skill rewrites Tomcat's `server.xml` accordingly, and every later command
reads the port from config. Run `check`/`status` to see port conflicts.

**`setup` downloads are version-driven, not `-Force`-driven.** Re-running
`setup` (with or without `-Force`) only fetches an artifact that is **missing**
or whose **platform version changed**:

- **Server jar** and **client war** are versioned with the platform — refetched
  on a fresh setup or a `-Version` bump, otherwise kept.
- **Tomcat** is the servlet container, independent of the lsFusion version — a
  new client war runs on the existing Tomcat — so it's fetched **only when
  missing**, never on a war update. (To switch Tomcat builds, delete
  `.lsfusion-dev/tomcat` and re-run `setup`.)

`-Force` regenerates config + `settings.properties` but does **not** re-download
binaries (delete the file to force a refetch). Before replacing Tomcat or the
war, `setup` **stops a running Tomcat first**, so an update can't fail on a
locked `bootstrap.jar` / exploded `ROOT`. Net effect: re-running `setup` to
tweak ports, DB, or settings is cheap and won't touch the ~400 MB of binaries.

### Running several servers / configs at once

The application server uses **two** ports beyond the web port: `rmi.port`
(default **7652** — the RMI register the web client connects to) and
`http.port` (default **7651** — the embedded HTTP server / Action API used by
`/eval`, `/exec`, the lsfusion-eval skill). To run multiple instances side by
side, give each project a **disjoint set of all four ports plus its own
database**, then `setup` once with those values and `start`:

```
# instance A — defaults (7652 / 7651 / 8080)
lsfdev.ps1 setup -ProjectDir "C:/Work/projA" -DbName projA -DbPassword <pwd>
lsfdev.ps1 start -ProjectDir "C:/Work/projA"

# instance B — shifted ports + its own DB, runs concurrently with A
lsfdev.ps1 setup -ProjectDir "C:/Work/projB" -DbName projB -DbPassword <pwd> `
                 -RmiPort 7662 -HttpPort 7661 -WebPort 8091 -ShutdownPort 8006
lsfdev.ps1 start -ProjectDir "C:/Work/projB"
```

`-RmiPort` / `-HttpPort` follow the **exact same scheme as the database
settings**: `setup` writes `rmi.port` / `http.port` into the project's
`settings.properties` (right next to `db.*`), and the server reads them
natively at startup. So the ports live in a durable project file — not just
`.lsfusion-dev/config.json` — and survive a wiped `.lsfusion-dev/`, a fresh
clone, or any launch path. You can equally set them by hand-editing
`settings.properties` instead of passing the flags. `start`/`restart`/`stop`/
`api` read them back from `settings.properties` (config.json is only a
cache/fallback). `start-web` writes `conf/Catalina/localhost/ROOT.xml` with a
`port` `<Parameter>` so that project's Tomcat dials its own server's
`rmi.port` instead of the built-in default 7652. When hitting the Action API
for a specific instance, use that instance's `http.port`
(e.g. `http://localhost:7661/eval/action`).

> Default ports (7652 / 7651) are left implicit — `settings.properties` only
> carries them when non-default, exactly like `db.user`/`db.server`. And like
> `db.*`, changing them in an **existing** `settings.properties` needs
> `setup -Force` (or a manual edit); a plain re-`setup` leaves the file alone.

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

**Each instance needs its own `-DbName`** — two servers pointed at the same
database will fight over the schema. Use distinct names (the default name is
derived from the project path, so distinct project dirs already differ).

## Standard workflow

Work through these steps. Stop and tell the user if a step needs their input
(for example a missing program or the PostgreSQL password).

### 1. Check the environment

Run `check`. It reports Java, PostgreSQL, and Python.

- **Java 11+** is required (1.8 works but 11 is the safest target). If Java is
  missing, ask the user to install a JDK — do not try to install it silently.
- **PostgreSQL** must be installed and accepting connections. If it is missing,
  stop and tell the user; the server cannot run without it.
- **Python 3** is needed for the `verify` command — it drives Playwright.
  Playwright itself (plus its bundled Chromium, ~120 MB) is auto-installed on
  the first `verify` run. If Python is absent, `verify` is unavailable but the
  rest of the skill still works.

### 2. Set up

You need the PostgreSQL connection details first. The defaults are server
`localhost` and user `postgres`; the **database name is generated uniquely per
project** (e.g. `lsfusion_<folder>_<hash>`) so separate lsFusion projects never
share or collide on one database — pass `-DbName` only if you need a specific
name. The PostgreSQL **password** is installation-specific — ask the user for
it if `check` could not connect, then:

```
powershell -ExecutionPolicy Bypass -File .claude/skills/lsfusion-dev/scripts/lsfdev.ps1 setup -DbPassword "<password>"
```

`setup` downloads ~410 MB (server jar 146 MB, client war 251 MB, Tomcat ~12 MB),
so it takes a while — run it with a generous timeout and tell the user it is
downloading. The client war is **moved straight into Tomcat as `ROOT.war`** and
the download is not retained, so only the server jar and Tomcat stay on disk.
`setup` also writes `settings.properties` and a starter `.gitignore` entry.

**Which lsFusion version.** **Default to `-Version stable`** — the latest
non-SNAPSHOT release on the download server. This is what you should pick
when the user gives no version cue: stable releases have predictable
behaviour, won't shift under you between sessions, and match what most
production servers run.

When starting a new project, **mention once** to the user that
`-Version dev` (alias `snapshot`) is available if they want the latest
features — but do not switch to it on your own. SNAPSHOT builds can change
daily, sometimes break, and may not be available through the apt installer
used by deploy workflows, so picking one without an explicit reason invites
avoidable trouble.

Switch off the default **only** when the user clearly asks for it — e.g.
"dev branch", "snapshot", "latest", a specific tag (like `7.0-SNAPSHOT`), a
major-version alias, or when the project itself pins a version (its
`pom.xml` parent declares a specific version, or its README requires it).
In that case pass `-Version <alias-or-tag>`. If the cue is ambiguous, **ask**
rather than guessing — major versions differ a lot.

Which exact version each alias resolves to is **not stable** — it depends on
what the download server currently publishes. Always run `lsfdev.ps1 versions`
to see how `stable`, `dev`, major-number aliases, and concrete tags resolve
right now, before locking in a non-default choice. To switch later, re-run
setup with the new alias and `-Force`; the skill removes the stale server
jar and clears the init marker so the next start does a full schema sync.

### 3. Write the `.lsf` code

Follow the MCP rules above and [references/workflow.md](references/workflow.md).

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

**Lightstart: leave ON.** Devmode enables `-Dlsfusion.server.lightstart=true`;
that's the default for every `restart`. Same code loads either way — lightstart
only skips reloading user-side DB-stored UI prefs (table-view layout,
security policy) and is **forced OFF** in two cases only: the very first
launch on a fresh DB, and when the user explicitly passes `-FullStart`.
Don't propose `-FullStart` as a debugging step — it's not a fix for "Property
not found", schema drift, or compile errors. Detail and rationale: see
[references/runtime.md](references/runtime.md#lightstart).

**Polling, not waiting.** A typical lightstart restart is 30 s – 1 min; a
full first-time start can take a few minutes. Either way, poll the log
every 10–20 s — don't `-Timeout 600` and walk away. If a real long sync
is genuinely in progress, the log keeps printing real work and you can
extend the wait deliberately.

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
over the lsfusion-eval endpoint (devmode → no `-u`):

```bash
curl -sS -X POST -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-urlencode "script=analyzeDBAction();" \
  http://localhost:7651/eval/action
```

Calling the action (rather than raw `psql`) works uniformly with no psql
client on PATH and no DB credentials to dig out. Skip it for ordinary
edit→restart cycles; it only matters after the first full schema load or a
sync that touched many tables.

**Restart only for schema changes. For runtime data operations, use
lsfusion-eval — do NOT create a module and restart.** A `restart`
exists to reload the *schema*: new classes, properties, forms,
actions, events, constraints, migration steps. Everything else —
seeding test data, running a one-off fix, ad-hoc count / lookup,
calling an existing action with specific arguments — is **data**, not
schema, and belongs on the running server.

**Web resources (JS / CSS / images) need NO restart in devmode — just
hard-reload the browser.** Files under `src/main/resources/**` that the
browser fetches — `CUSTOM`-component `.js`/`.css` registered via
`onWebClientInit`, icons, web assets — are served live from source: in
devmode the running server re-reads them from `src/main/resources` on each
request (and re-stages them into `target/classes`) at page load. So after
editing such a file, **do not `restart`** — just reload the page, bypassing
the browser cache (Ctrl/Cmd+Shift+R, or a fresh headless context in
Playwright, which has no cache). Verified: a `.css` edit shows up on the
next hard reload with the server untouched. A `restart` is only needed when
you also changed the **`.lsf`** side (e.g. the `CUSTOM 'name'` declaration,
new form properties/actions the JS calls, the `onWebClientInit` registration
itself) — that's schema. Pure JS/CSS iteration is a sub-second reload loop,
not a 30 s restart loop.

The lsfusion-eval skill talks to the live server's HTTP endpoints
(`/exec`, `/eval`, `/eval/action`) and accepts arbitrary
`NEWSESSION { NEW … APPLY; }` scripts. The same script that you'd put
inside an action body runs there directly. No `.lsf` file, no top
REQUIRE entry, no restart cycle — round-trip is sub-second instead of
30+ s.

Signs you are about to make this mistake:

- You catch yourself writing a `TestData.lsf` / `SeedData.lsf` /
  `Migration001.lsf` module purely to call it once and never again.
- You're adding an action to the top REQUIRE that the production
  config will never want to load.
- The work is "create N rows" or "set property X on object Y", not
  "introduce a new property / class / form".

In all three, stop and switch to lsfusion-eval. A permanent module
should exist when the *application* genuinely needs the action
later — admin tools, importers, scheduled jobs. One-shot data
manipulation should never leave a trace in the codebase.

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
   via the **lsfusion-eval** skill — `curl` against `/eval/action`. The
   server resolves names, types, and security exactly as the app would,
   so a clean response proves your new class / property / form really
   exists in the running schema. Cheap, scriptable, exact — and tells
   you semantic truth without rendering.

3. **UI, last.** When log + API agree the build is healthy, run
   `verify`. It drives **Playwright** (headless Chromium) to:
   - screenshot the landing page → `.lsfusion-dev/verify-login.png`,
   - **if a login form is present**, log in as `admin` (empty password by
     default) and screenshot the result → `.lsfusion-dev/verify-app.png`,
   - dump the final DOM → `verify-dom.html` and the browser console →
     `verify-console.txt`.

   In devmode lsFusion auto-authenticates, so there is **no login form**
   and the landing screenshot already shows the navigator + forms. The
   first `verify` ever installs Playwright + Chromium (~120 MB); one-time.
   For multi-step / remote / form-specific verification (clicking through
   to a card to confirm a new field renders), use the lsfusion-eval
   skill's Part 3 — it ships a Python Playwright template that goes
   beyond `verify`'s one-screenshot scope.

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
application and can click through it. Do not stop at "the server is up": the
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
   run `setup -DbPassword <pwd>` exactly as for a new project. When the skill
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
elements that fit in. See [references/workflow.md](references/workflow.md).

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
   and (when light start is on) `-Dlsfusion.server.lightstart=true`. Any
   `-D` you add by hand wins over the file-based layers below.
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
  the repo is shared.
- Ports used: `5432` PostgreSQL, `7652` RMI, `7651` Action API, `8080` web UI,
  `8005` Tomcat shutdown. `status` reports conflicts.
- Deeper runtime details, all config keys, and a troubleshooting table are in
  [references/runtime.md](references/runtime.md) — read it when a command fails
  or the user asks about configuration.
