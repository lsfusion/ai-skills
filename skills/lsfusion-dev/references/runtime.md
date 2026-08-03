# lsFusion runtime reference

Read this when a `lsfdev.ps1` command fails, when the user asks about
configuration, or when you need to change ports/versions.

## Project layout

```
<project>/                  current folder = the lsFusion project
├── *.lsf                   your modules (loaded recursively from here)
├── settings.properties     application-server settings (DB, top module)
└── .lsfusion-dev/          created by the skill; in .gitignore
    ├── config.json         skill config (versions, ports, credentials)
    ├── lsfusion-server-<ver>.jar
    ├── tomcat/             Apache Tomcat 9; the client war lives here as
    │                       webapps/<app id>.war -> web context /<app id>
    │                       (app id = db.name; the download itself is not
    │                       kept; webapps/ROOT holds only a redirect page
    │                       to /<app id>/)
    ├── server.out.log / server.err.log
    ├── tomcat.out.log
    ├── server.pid / tomcat.pid
    ├── server-initialized.flag   marker (content: the db.name it certifies);
    │                             light start is used once it exists. Cleared
    │                             on version switch, when the DB had to be
    │                             (re)created, or when db.name is repointed
    ├── verify_playwright.py      helper re-copied from the skill on each verify
    │                             (plugin skill dirs aren't visible to python.exe)
    ├── verify-login.png          Playwright screenshot of the login page
    ├── verify-app.png            Playwright screenshot after the login attempt
    ├── verify-click.png / verify-dblclick.png   -Click / -DoubleClick results
    ├── verify-do.png             state after the -Do interaction steps
    ├── pw-session.pid / pw-session-profile/     persistent verify -Session
    │                             browser (killed by verify -EndSession / stop)
    └── verify-dom.html / verify-console.txt
```

The application server runs with the **project folder as its working
directory**. The classpath is built one of three ways, picked
automatically; in every case it contains a single staged classpath root
plus the server-side dependencies — never both `.` and `src/main/lsfusion`
together, because that would make lsFusion discover the same `.lsf` file
through two paths and bail out with *"module 'X' has already been added"*.

- **Maven project (`pom.xml` present) + Maven on `PATH`** — the skill
  uses Maven for the whole dependency story. `setup` skips the
  `lsfusion-server-<ver>.jar` download entirely; on `start-server` the
  skill runs `mvn -q -DskipTests compile` (incremental, fast after the
  first run) and then
  `mvn -q dependency:build-classpath -Dmdep.outputFile=.lsfusion-dev/maven-classpath.txt -Dmdep.includeScope=runtime`,
  caches the classpath, and launches Java with:
  ```
  -cp "target\classes;src\main\resources;src\main\lsfusion;<every dep from Maven>"
  ```
  The cache is refreshed only when `pom.xml` is modified, so iterating
  on `.lsf` files is quick (just `mvn compile`). The JVM ends up running
  with **exactly the dependency graph the project's `pom.xml` defines**,
  including the precise lsfusion-server version pinned by the project.
  (The source roots are kept on the classpath here because Maven's
  default `<resources>` block does **not** copy `.lsf` files into
  `target/classes`; projects that explicitly map `src/main/lsfusion` as
  a resource directory should drop those entries from their pom to keep
  the classpath single-rooted.)

  One drift trap is built into this split: with a **`-SNAPSHOT`** platform
  version Maven re-resolves the server jar over time (a pom change, `mvn -U`,
  the snapshot update policy, a local platform build), while the client war
  — downloaded by the skill, not Maven — stays whatever `setup` fetched. The
  web client talks RMI to the server with plain Java serialization, so a war
  and a server from **different snapshot builds** of the same version can
  fail on **every** form open with `invalid stream header`. Neither artifact
  stamps its manifest, but zip entry dates carry the build time —
  `start-web`, `status`, and `setup` compare the two and **warn when they
  are >24 h apart**, naming which side is stale. Fix: `setup -RefreshWar`
  re-downloads the war at the same version (current snapshot build) when
  the server is newer; `mvn -U -DskipTests compile` + `restart` updates the
  server when the war is newer. See the troubleshooting row below.

- **Maven project but Maven not on `PATH`**, or **bare Maven layout with
  no `pom.xml`** — the skill stages the build itself. On every
  `start-server` it wipes `target/classes/`, copies
  `src/main/resources/**` and `src/main/lsfusion/**` into it (and
  `settings.properties` from the project root), compiles any
  `src/main/java/**` Java sources with `javac -d target/classes`, and
  launches Java with classpath `target\classes;<server jar>`. The
  `lsfusion-server-<ver>.jar` downloaded by `setup` provides the
  built-in `System` modules.

- **Flat project (no `src/main/*`)** — the non-Maven branch still stages
  to `target/classes`: it picks up loose `*.lsf` files and any
  `*.properties` other than `settings.properties` from the project root
  and copies them in. The same `target\classes;<server jar>` classpath
  is used. This is the path for ad-hoc single-file experiments.

The `clone` command does not change this — it just places the repo under the
project folder; the Maven-vs-fallback choice happens at `setup` / `start-server`
time, based on `Find-Maven`.

## How the processes are launched

**Application server** (`start-server`):

```
java <--add-opens flags> -Dlsfusion.server.devmode=true \
     -Ddb.denyDropModules=false -Ddb.denyDropTables=false \
     -Ddb.denyDropProperties=false \
     [-Dlsfusion.server.lightstart=true] \
     -Ddb.name=<name> [-Ddb.server=… -Ddb.user=… -Ddb.password=…] \
     -Xmx2g -Dfile.encoding=UTF-8 \
     -cp "target\classes;.lsfusion-dev\lsfusion-server-<ver>.jar" \
     lsfusion.server.logics.BusinessLogicsBootstrap
```

Success is the log line `Server has successfully started`. Listens on RMI
`7652`, HTTP Action API `7651`, and WebSocket `8887` (all shiftable via
`rmi.port` / `http.port` / `webSocket.port`).

The `-Ddb.*` args duplicate the values just resolved from
`settings.properties` (which stays the source of truth between runs — the
skill re-reads it and re-asserts `db.name` into `conf/settings.properties`
before every launch). `-D` is the strongest resolution layer, so the server
provably runs against the reported database even if a settings-file layer is
unreadable or mis-parsed — the incident that motivated this had `db.name`
silently ignored (BOM'd first key) while ports from the same file applied.
After a successful start the skill additionally **verifies the actual
binding** through `pg_stat_activity` (JVM TCP connections are matched to
backends by `client_port`; psql is searched on PATH, then next to the
PostgreSQL **service's** binary — `Win32_Service.PathName` points into the
install's `bin\` for any install location — then under
`%ProgramFiles%\PostgreSQL\<ver>\bin`) and prints either
`Database binding verified` or a loud `DATABASE MISMATCH`. `status` shows the
same as `Database: <name> (N connections)` and flags a mismatch for a running
server. Values with whitespace can't survive argument joining and stay
file-only; ports are deliberately file-only (safe defaults, no silent-fallback
history).

**Development JVM options.** `-Dlsfusion.server.devmode=true` is always set for
local development. Beyond turning on dev-friendly behaviour, **devmode also
auto-authenticates the user as `admin`** — the web client opens straight on
the navigator with no login form, both in the user's browser and in headless
`verify` runs. Outside devmode the default credentials (`admin` / empty
password) apply and the login form is rendered as usual.

Devmode auth has one trap: auto-auth applies **only to a request that
carries no `Authorization` header at all** — a request with a header gets a
real credential check (a wrong password is **HTTP 401** even in devmode).
That is why the `api` command sends **no** header unless a non-empty admin
password is configured (`-AdminPassword` at setup, or stored in
`config.json`). Full rule table and build history: the **lsfusion-eval**
skill's auth section.

The three `-Ddb.denyDrop{Modules,Tables,Properties}=false` flags let the
schema sync remove modules, tables, and columns that disappear between
runs (REQUIRE-graph changes, platform upgrades that ship a different
module set, property-type edits). Without them lsFusion aborts startup
with *"Dropping … is restricted by settings"*. They are dev-only — a
production deploy keeps the defaults (`true`) so destructive schema
changes need an explicit override in its own `settings.properties`.

`-Dlsfusion.server.lightstart=true` skips parts of startup for a much faster
restart. Schema sync and business logic are **not** among the skipped parts —
a light start still syncs the database structure; what it skips is the
Reflection metadata sync and user-side prefs reload (see
[Lightstart](#lightstart)). The skill enables light start by default and
drops it only:

- on the **first launch** — detected via the `.lsfusion-dev/server-initialized.flag`
  marker, which is created after the first successful start (a fresh DB gets
  its initial schema, stats and Reflection rows in one full pass). The marker
  certifies a specific database: it is cleared automatically on a platform
  version switch, when the configured database was found **missing** and had
  to be (re)created, or when `db.name` is repointed at a different database —
  each of those makes the next start a full one. (A database dropped and
  re-created *externally* between runs — never observed missing by the
  skill — is the one case the marker can't see: run `restart -FullStart`
  after restoring a DB by hand.) And
- when **`-FullStart`** is passed: `lsfdev.ps1 restart -FullStart`.

One `-FullStart` is **required** after adding actions/properties that are
referenced **by canonical name** (scheduler tasks, `actionCanonicalName()`) —
lightstart skips the Reflection sync those lookups read from; see
[Lightstart](#lightstart).

**Web server** (`start-web`): Tomcat is started by invoking its
`org.apache.catalina.startup.Bootstrap` directly (so the skill owns the PID).
The war is deployed as `webapps/<app id>.war` — the app id being `db.name` —
so the UI is at `http://localhost:8080/<app id>/`; the root `/` serves a
one-line redirect there (projects set up by pre-app-id skill versions keep
`ROOT.war` at `/` until the next `setup`, which renames the war in place — no
re-download; a `db.name` that is not context-safe also stays at `/`). The
web client connects to the application server over RMI on `localhost:7652` by
default — no extra configuration is needed when everything runs locally with
default ports.

## settings.properties keys

The file the server reads at runtime is `conf/settings.properties` (relative to
the JVM working directory; in a non-Maven project the project-root
`settings.properties` is a mirror that `setup`/`start` keep in sync). It is the
source of truth — `start`/`restart`/`stop`/`api` read `db.*` and the ports back
from it, with `.lsfusion-dev/config.json` only a cache. Keys the skill writes:

| Key | Meaning | Default |
|---|---|---|
| `db.server` | PostgreSQL host (add `:port` if not 5432) | `localhost` |
| `db.name` | database name = **the app id** (`setup -AppId`): the web context path is derived from this same value, no separate key. When the value is not a valid context name (an expert `-DbName`), only the DB uses it and the web client deploys at `/` | `<folder>_<hash4>` |
| `db.user` | PostgreSQL user | `postgres` |
| `db.password` | PostgreSQL password | (empty) |
| `logics.topModule` | top module to load; blank = load all found | (blank) |

Other useful keys (add by hand if needed): `rmi.port` (default `7652`),
`http.port` (default `7651`), `webSocket.port` (default `8887` — bound
unconditionally; shift it per instance when running several servers),
`logics.includePaths` / `logics.excludePaths`,
`user.language` / `user.country` (locale).

Extra **JVM flags** are not settings.properties keys — pass them once via
`setup -JvmArgs "-Duser.language=ru -Xmx4g"` (app server) and/or
`-TomcatOpts "..."` (web client); they persist in `.lsfusion-dev/config.json`
and are appended after the built-in defaults on every start, so a user
`-Xmx` overrides the default `-Xmx2g`.

To change ports: `stop` first, then re-run `setup` with the port flags
(`-RmiPort` / `-HttpPort` / `-WebSocketPort` / `-WebPort` / `-ShutdownPort`)
— setup rewrites `settings.properties` **and** Tomcat's `server.xml`
together. The app-server ports (`rmi.port` / `http.port` / `webSocket.port`)
can alternatively be hand-edited in `conf/settings.properties` (the server
reads that file natively; `config.json` is only a cache) — but the web and
shutdown ports live in Tomcat's `server.xml`, which only `setup` rewrites,
so hand-editing settings alone cannot move them.

## Java versions

Java 11+ is recommended; the skill adds `--add-opens` flags on Java 11+ so
frameworks can reflectively access JDK internals. Java 8 also works (no flags).
If only a very new JDK is available and the server still fails on module
access, installing JDK 11 or 17 is the most reliable fix.

## Troubleshooting

| Symptom in the log / behaviour | Cause & fix |
|---|---|
| `Connection refused` / `could not connect` to the DB | PostgreSQL is down. Start the PostgreSQL service, re-run `start-server`. |
| `password authentication failed` | Wrong `db.password`. Re-run `setup -DbPassword <correct> -Force`, or edit `settings.properties`. |
| `database "..." does not exist` and it is not auto-created | Create the database named by `db.name` in `settings.properties`: `createdb -U postgres <db.name>` (or via pgAdmin), then `restart`. |
| Server silently ignores `db.name` (or another first-line key) and uses the shared default DB `lsfusion`, although `settings.properties` names another | A **UTF-8 BOM** at the start of `conf/settings.properties` — Java's properties loader does not strip it, so the first key reads as `﻿db.name`. Written by BOM-adding editors and by pre-2026-07 skill versions (PowerShell `Set-Content -Encoding UTF8`); lsfdev's own readers strip the BOM, so old `setup`/`status` still reported the intended name. Current skill versions triple-guard this: properties are written BOM-less (re-running `setup` — or any `start` — heals the file), `-Ddb.name` on the launch line outranks the file anyway, and after start the skill verifies the real binding via `pg_stat_activity` (`DATABASE MISMATCH` if not). If you hit this on an old install: the server may have been creating its schema in `lsfusion` all along — decide consciously whether to keep pointing there (`setup -DbName lsfusion`) or re-sync into the intended DB. |
| `pg_hba.conf` / authentication method rejected | PostgreSQL must allow `md5`/`scram`/`trust` for the user. Edit `pg_hba.conf` and reload PostgreSQL. |
| `error parsing`, `syntax error`, `expecting ...` | An `.lsf` syntax error. Read the file/line in the message, fix it with `lsfusion_retrieve_docs`, then `restart`. |
| `module ... not found` | A `REQUIRE`d module name is wrong or missing. Check module names. |
| `InaccessibleObjectException` / `module does not "opens"` | JDK module access. The skill already adds common `--add-opens`; add the exact failing one to the `Add-Opens` function in `lsfdev.ps1`, or use JDK 11. |
| `Address already in use` / port `7652`/`8080` busy | Another process holds the port. `lsfdev.ps1 stop`; if the port is held by a foreign process, `setup -RmiPort <free>` / `-WebPort <free>` (setup rewrites `settings.properties` and Tomcat's `server.xml` together), then `start`. |
| `BindException` from `WebSocketServer` in stderr, server otherwise starts | Another instance holds `webSocket.port` (default `8887`). Non-fatal but WebSocket features silently break — set a per-instance `webSocket.port` (`setup -WebSocketPort <free> -Force`) and restart. |
| Web UI loads but shows a connection error | The application server is not running or not on `7652`. Check `lsfdev.ps1 status` and the server log. |
| **Every** form open fails with `invalid stream header` (or `StreamCorruptedException` / `InvalidClassException`), web UI otherwise loads | The client war and the server jar come from **different builds** of the same `-SNAPSHOT` version — RMI serialization mismatch. Typical in Maven projects: Maven updated the server snapshot, the war stayed from an older `setup`. `status` / `start-web` print both build dates and the remedy for the stale side: server newer → `setup -RefreshWar`; war newer → `mvn -U -DskipTests compile` + `restart` (Maven-resolved server), or delete `.lsfusion-dev/lsfusion-server-<ver>.jar` and re-run `setup` (skill-downloaded server). |
| Scheduler task saved with an **empty action**; `actionCanonicalName('My.action[]')` returns NULL for an action that exists in code | Lightstart skipped the Reflection sync, so actions added since the last full start have no `Reflection.Action` row — the lookup silently returns NULL. Run **one** `restart -FullStart`, then re-create/re-pick the action (see [Lightstart](#lightstart)). |
| Tomcat exits immediately | Read `.lsfusion-dev/tomcat/logs/catalina.*.log`. Usually a bad war or a port clash on `8080`/`8005`. |
| `start-server` says **inconclusive** | First start builds the DB schema and can take minutes. Re-run `log`, or `start-server -Timeout 300`. |
| `api` returns **HTTP 401 Unauthorized** | A credentialed request with wrong (or, on some snapshot-era builds, empty) credentials hit the devmode server — devmode auto-auth only covers requests with **no** `Authorization` header. The `api` command handles this automatically (it omits the header unless a password is set). If you call `/eval/action` by hand, drop `-u admin:` and send no auth — or pass `-u admin:<real password>` only if the admin password was actually rotated. |

## Changing the lsFusion version

`setup -Version` accepts (the skill targets platform 7 only — every alias
resolves within the 7.x line):

- **`stable`** / **`latest`** — the highest non-SNAPSHOT, non-beta 7.x
  release; while none is published, falls back to the latest 7.x build.
- **`dev`** / **`snapshot`** — the latest 7.x SNAPSHOT.
- **`7`** — the latest 7.x build of any kind; **the default** when no
  `-Version` is passed (in a Maven project the pom's platform version wins
  over the default instead). What an alias resolves to depends on what the
  download server currently has.
- An **exact tag** (e.g. `7.0-SNAPSHOT`) — used verbatim.

`lsfdev.ps1 versions` queries <https://download.lsfusion.org/java/> and prints
what is actually available right now together with how each alias resolves.

When you switch versions, `setup` removes the previous server jar, clears the
`server-initialized.flag` so the next start is a **full** one (fresh stats
recalculation and a Reflection sync for the new platform's module set), and
stores the resolved tag back into `config.json`. The war is re-downloaded by the version
switch itself (it is versioned with the platform — no `-Force` involved);
Tomcat is version-independent and is kept (delete `.lsfusion-dev/tomcat` to
force a reinstall). To re-fetch the war at the **same** `-SNAPSHOT` version
(current build), pass `setup -RefreshWar`; `-Force` never re-downloads
binaries.

Once a version is in `config.json`, later `setup` runs reuse it verbatim — the
resolved version is sticky, so the platform never gets upgraded silently. Pass
an alias again (e.g. `setup -Version 7 -Force`) when you want to move to
the current latest.

## Lightstart {#lightstart}

Devmode adds `-Dlsfusion.server.lightstart=true` to the JVM args. With it on,
a typical restart finishes in **30 s – 1 min**; without it (the init marker
absent or invalidated — first launch, version switch, re-created DB, `db.name`
repoint — or an explicit `-FullStart`), the platform re-syncs the whole logic
graph into the database, which can finish quickly with healthy stats but can
also drag on for several minutes if a query plan goes sideways.

**What lightstart does NOT affect.** Server startup correctness, schema sync,
business logic, name resolution, the success or failure of a build. If
`start-server` fails or a property won't resolve, **turning lightstart off
will not help** — the same code runs either way.

**What lightstart DOES skip.** Two classes of DB-stored state, both refreshed
only on a full start:

- **user-side UI/admin preferences** — form-table view settings,
  security-policy reload and similar. Usually you neither notice nor care.
- **the Reflection metadata sync** — the rows in the system `Reflection`
  tables that describe the loaded code (`Reflection.Property` /
  `Reflection.Action` objects, navigator elements, forms; only the *table*
  metadata still syncs under lightstart). Anything that looks logic up **by
  canonical name through those tables** — scheduler tasks (the platform
  resolves the picked action via `actionCanonicalName()`),
  `propertyCanonicalName()` in code, reflection-driven admin forms, per-
  action security-policy setup — does **not** see actions/properties added
  or renamed since the last full start. The failure is **silent**:
  `actionCanonicalName('MyModule.myAction[]')` simply returns NULL, so e.g.
  a scheduler task saves with an **empty action** instead of erroring.

**The one case where `-FullStart` IS the fix.** Added (or renamed) an action
or property that something references **by canonical name** — a scheduler
job, `actionCanonicalName()` / `propertyCanonicalName()`, the Reflection /
security-policy admin forms? Run **one** `restart -FullStart` to sync the
Reflection tables, then go back to lightstart restarts. A full start
reliably re-syncs even when the code did not change since the last light
restart: the light/full flag is folded into the source hash the sync is
keyed on.

**When the skill leaves lightstart ON.** Everything routine: code edits,
adding or modifying modules, changing properties / forms / actions, small
schema changes (a new `DATA` property, a new class). lsFusion handles these
incrementally with lightstart on, and the logic on the server is identical
to what a full start would load.

**When lightstart is forced OFF.** When the init marker is absent or was
invalidated — first launch on a fresh DB, a platform version switch, the
configured database found missing and re-created, a `db.name` repoint — and
when the user explicitly passes
`-FullStart`. Beyond those automatic cases the skill does not silently decide
for you that a change is "significant enough" to require `-FullStart`; that
call belongs to the user.

**Don't propose `-FullStart` as a debugging step** for logic / schema /
startup problems. Not a fix for "Property not found", schema drift, count
mismatches, or compile errors — same code runs either way. The legitimate
`-FullStart` suggestions are exactly two: the canonical-name / Reflection
case above, and the user explicitly caring about the user-facing settings
lightstart skips (table-view layout, security-policy reload).

## Dry run {#dryrun}

Platform mechanics behind `lsfdev.ps1 dryrun` (setting `settings.dryRun`,
in 7.0-SNAPSHOT since build `7.0-20260730.203938-1179`; the platform docs
list it under Working parameters). All facts below are measured on
2026-07-31 builds unless marked as source-derived.

**Lifecycle cutoff.** Server startup fires lifecycle listeners in a fixed
order: `BusinessLogics` (order 100, the whole logical model — parse,
metacode expansion, name resolution, classes / properties / actions /
forms creation and finalization), then `DBManager` (300, schema sync),
`SecurityManager` (400), `RmiManager` (500, RMI port), `RemoteLogicsLoader`
(600, exposes logics), daemons (8000 — the Action API HTTP server,
WebSocket server, RabbitMQ), `ReflectionManager` (9000). With
`settings.dryRun=true` the INIT event stops right before order 300:
**only the logic phase runs**. The JVM then prints
`Dry run finished successfully in N ms, exiting` and exits **0**; any
startup error goes through the normal error logging and exits **1**
(the nonzero code exists precisely so CI / agents can read the verdict).

**What that implies (measured):** zero listening sockets for the dry-run
JVM's entire lifetime (RMI 7652 / Action API 7651 / WebSocket 8887 all
belong to managers past the cutoff) — so it runs next to a live server
with no port juggling; no schema sync, no Reflection sync, no init-marker
implications; a 772-module project completes the JVM phase in ~9 s where
its restart takes 26–41 s+.

**DB connection under dryRun — fixed on 2026-08-03; two behavior
generations exist.** The jar gate cannot tell them apart (`lsfusion.xml`
is identical), so know both:

- **First-wave builds (`20260730.203938` … 2026-08-02)** did open 2
  PostgreSQL connections during the *logic* phase: the
  `DBManager.initReflectionEvents()` init task (the `Initializing
  reflection events` log line) runs before the lifecycle cutoff and
  called `ensureDB`, which **created a missing database** (empty —
  0 tables) and, on an unreachable server, **retried forever** ~1/s
  (`ERROR StartLogger - Connection to <host> refused`, no exit — dead
  exit-code for CI). Source-derived scope of the retry: only SQLSTATE
  08001 / 57P03 (`Connection to X refused`, `The connection attempt
  failed`); other connect errors (a genuinely rejected password) are
  thrown immediately and surface via the exit-code /
  missing-success-marker path. On a dev box whose pg_hba trusts
  localhost, a wrong `db.password` is invisible (measured).
- **Builds since 2026-08-03** (platform commit `d98398f`, *Skip
  DBManager.initReflectionEvents under dryRun*): the task returns early
  — measured on the 2026-08-03 download build: an unreachable
  PostgreSQL **passes** in ~5 s, the dry-run JVM opens **zero sockets
  of any kind**, and a missing database is **NOT created**. "Validate
  without a live database" now holds literally — no DBMS needed. (The
  skip also means DB-stored user property overrides —
  logging/materialized/notnull — are absent from the dry-run model;
  irrelevant for load-time validation.)

`lsfdev.ps1 dryrun` keeps its unreachable-DB watcher as a backstop for
first-wave builds: on them it kills the JVM with a `PostgreSQL is
unreachable` verdict in ~10 s instead of hanging to the timeout; on
current builds the pattern simply never fires.

**Version gate.** The Spring wiring for the setting (`<entry
key="dryRun" .../>` in the jar's root `lsfusion.xml`) exists only in
7.0-SNAPSHOT builds from `20260730.203938` on. On any older build the
`-Dsettings.dryRun=true` flag is **silently ignored** and the "dry run"
boots a REAL server — against the project's actual database and ports.
`lsfdev.ps1 dryrun` therefore (1) inspects the server jar's
`lsfusion.xml` up front and refuses unsupported builds, and (2) as a
backstop for uninspectable jars, kills the JVM the moment
`Server has successfully started` appears in the log.

**Scope and `topModule` (measured).** Module scope is the `REQUIRE`
closure of `logics.topModule` (plus system modules) — same as a real
start. `dryrun -TopModule <M>` overrides it per-run via
`-Dlogics.topModule` (a `-D` outranks the project's
`lsfusion.properties`). Since the 2026-08-03 builds (platform commit
`68ce253`) the value may be a **comma-separated list** — the union of
the closures is loaded; quote it (`-TopModule "Sales,Purchase"`) so
PowerShell passes one string (measured: an unknown name anywhere in the
list fails with `Module 'X' not found`). Everything outside the closure
is dropped **before parsing** — a module outside the closure contributes
nothing, not even syntax errors — and dependents of the listed modules
are not loaded either.
Fast iteration: scoped run on the edited subtree; the gate before a
restart: the unscoped run. Never persist a narrowed `topModule` into the
project config: a *real* start with it would drop the out-of-closure
modules' tables at schema sync.

**lsfdev implementation notes.** The command reuses `start-server`'s
launch plumbing (same Maven / staged classpath, same `-Xmx`, devmode,
`--add-opens`, persisted `-JvmArgs`) with these differences: non-Maven
staging goes to `.lsfusion-dev/dryrun-classes` (never wiping
`target/classes` under a running server; in Maven mode `mvn compile` is
incremental — the same thing an IDE build does); no `Ensure-Database`,
no `-Ddb.*` mirror, no init-marker write, no PID-file/port takeover of
the real server (a stuck *dry run* is reaped via its own
`.lsfusion-dev/dryrun.pid`). Artifacts: `dryrun.out.log` /
`dryrun.err.log` / `dryrun-cmd.txt` in `.lsfusion-dev/`. Error
reporting mirrors a restart: parse errors batched per file, **one
semantic error per run**, printed with `file:line:col` from the first
`ERROR` line onward (the multi-KB `Class path:` preamble is filtered
out of the tail).
