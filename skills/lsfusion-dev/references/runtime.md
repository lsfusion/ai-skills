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
    │                       webapps/ROOT.war (the download itself is not kept)
    ├── server.out.log / server.err.log
    ├── tomcat.out.log
    ├── server.pid / tomcat.pid
    ├── server-initialized.flag   marker; light start is used once it exists
    ├── verify-login.png          Playwright screenshot of the login page
    ├── verify-app.png            Playwright screenshot after the login attempt
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
     [-Dlsfusion.server.lightstart=true] -Xmx2g -Dfile.encoding=UTF-8 \
     -cp "target\classes;.lsfusion-dev\lsfusion-server-<ver>.jar" \
     lsfusion.server.logics.BusinessLogicsBootstrap
```

Success is the log line `Server has successfully started`. Listens on RMI
`7652` and HTTP Action API `7651`.

**Development JVM options.** `-Dlsfusion.server.devmode=true` is always set for
local development. Beyond turning on dev-friendly behaviour, **devmode also
auto-authenticates the user as `admin`** — the web client opens straight on
the navigator with no login form, both in the user's browser and in headless
`verify` runs. Outside devmode the default credentials (`admin` / empty
password) apply and the login form is rendered as usual.

Devmode auth has one trap that drives how the `api` command talks to the
Action API: devmode grants access **only to a request that carries no
`Authorization` header at all** (it treats it as the anonymous user). A request
that *does* send Basic auth for `admin` with an **empty** password makes the
server run a real credential check and reject it with **HTTP 401**. So the
`api` command sends **no** `Authorization` header unless a non-empty admin
password is configured (`-AdminPassword` at setup, or stored in
`config.json`); with the default blank password it calls anonymously. This is
the same rule the **lsfusion-eval** skill documents: devmode → no `-u`;
password set / rotated → `-u admin:<password>`.

The three `-Ddb.denyDrop{Modules,Tables,Properties}=false` flags let the
schema sync remove modules, tables, and columns that disappear between
runs (REQUIRE-graph changes, platform upgrades that ship a different
module set, property-type edits). Without them lsFusion aborts startup
with *"Dropping … is restricted by settings"*. They are dev-only — a
production deploy keeps the defaults (`true`) so destructive schema
changes need an explicit override in its own `settings.properties`.

`-Dlsfusion.server.lightstart=true` skips parts of startup for a much faster
restart, but it must not be used until the database schema is fully built and
in sync. The skill enables light start by default and drops it only:

- on the **first launch** — detected via the `.lsfusion-dev/server-initialized.flag`
  marker, which is created after the first successful start; and
- when **`-FullStart`** is passed — use this after significant data-model
  changes (new or removed classes, changed property types, anything affecting
  the database structure): `lsfdev.ps1 restart -FullStart`.

If a light-start restart behaves oddly after a data-model change, redo it with
`-FullStart` to force a full schema sync.

**Web server** (`start-web`): Tomcat is started by invoking its
`org.apache.catalina.startup.Bootstrap` directly (so the skill owns the PID).
The war is deployed as `webapps/ROOT.war`, so the UI is at the context root
`http://localhost:8080/`. The web client connects to the application server
over RMI on `localhost:7652` by default — no extra configuration is needed when
everything runs locally with default ports.

## settings.properties keys

`settings.properties` lives in the project folder. Keys the skill writes:

| Key | Meaning | Default |
|---|---|---|
| `db.server` | PostgreSQL host (add `:port` if not 5432) | `localhost` |
| `db.name` | database name — generated uniquely per project (`lsfusion_<folder>_<hash>`) unless `-DbName` is given | (per project) |
| `db.user` | PostgreSQL user | `postgres` |
| `db.password` | PostgreSQL password | (empty) |
| `logics.topModule` | top module to load; blank = load all found | (blank) |

Other useful keys (add by hand if needed): `rmi.port` (default `7652`),
`http.port` (default `7651`), `logics.includePaths` / `logics.excludePaths`,
`user.language` / `user.country` (locale).

To change ports, edit both `settings.properties` and
`.lsfusion-dev/config.json` so the skill and the server agree.

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
| `pg_hba.conf` / authentication method rejected | PostgreSQL must allow `md5`/`scram`/`trust` for the user. Edit `pg_hba.conf` and reload PostgreSQL. |
| `error parsing`, `syntax error`, `expecting ...` | An `.lsf` syntax error. Read the file/line in the message, fix it with `lsfusion_retrieve_docs`, then `restart`. |
| `module ... not found` | A `REQUIRE`d module name is wrong or missing. Check module names. |
| `InaccessibleObjectException` / `module does not "opens"` | JDK module access. The skill already adds common `--add-opens`; add the exact failing one to the `Add-Opens` function in `lsfdev.ps1`, or use JDK 11. |
| `Address already in use` / port `7652`/`8080` busy | Another process holds the port. `lsfdev.ps1 stop`, or change the port in config + settings. |
| Web UI loads but shows a connection error | The application server is not running or not on `7652`. Check `lsfdev.ps1 status` and the server log. |
| Tomcat exits immediately | Read `.lsfusion-dev/tomcat/logs/catalina.*.log`. Usually a bad war or a port clash on `8080`/`8005`. |
| `start-server` says **inconclusive** | First start builds the DB schema and can take minutes. Re-run `log`, or `start-server -Timeout 300`. |
| `api` returns **HTTP 401 Unauthorized** | A credentialed request hit the devmode server. Devmode only accepts requests with **no** `Authorization` header (anonymous); `admin` with an empty password is rejected. The `api` command handles this automatically (it omits the header unless a password is set). If you call `/eval/action` by hand, drop `-u admin:` and send no auth — or pass `-u admin:<real password>` only if the admin password was actually rotated. |

## Changing the lsFusion version

`setup -Version` accepts:

- **`stable`** / **`latest`** (the default) — the highest non-SNAPSHOT,
  non-beta release.
- **`dev`** / **`snapshot`** — the latest SNAPSHOT release.
- A **major-number alias** (e.g. `6`, `7`) — the latest release in that
  major line. What that resolves to depends on what the download server
  currently has; major lines can be stable or SNAPSHOT-only.
- An **exact tag** (e.g. `6.2`, `7.0-SNAPSHOT`) — used verbatim.

`lsfdev.ps1 versions` queries <https://download.lsfusion.org/java/> and prints
what is actually available right now together with how each alias resolves.

When you switch versions, `setup` removes the previous server jar, clears the
`server-initialized.flag` so the next start does a full schema sync (schema
between majors differs enough that light start is unsafe), and stores the
resolved tag back into `config.json`. Pass `-Force` if you also need Tomcat
or the war re-downloaded.

Once a version is in `config.json`, later `setup` runs reuse it verbatim — the
resolved version is sticky, so the platform never gets upgraded silently. Pass
an alias again (e.g. `setup -Version stable -Force`) when you want to move to
the current latest.

## Updating after editing `.lsf` files

Any change to a `.lsf` module requires an application-server restart:
`lsfdev.ps1 restart`. The web server (Tomcat) does **not** need restarting.

## Lightstart {#lightstart}

Devmode adds `-Dlsfusion.server.lightstart=true` to the JVM args. With it on,
a typical restart finishes in **30 s – 1 min**; without it (`-FullStart` or
the very first launch on a fresh DB), the platform re-syncs the whole logic
graph into the database, which can finish quickly with healthy stats but can
also drag on for several minutes if a query plan goes sideways.

**What lightstart does NOT affect.** Server startup correctness, schema sync,
business logic, name resolution, the success or failure of a build. If
`start-server` fails or a property won't resolve, **turning lightstart off
will not help** — the same code runs either way. Lightstart only skips
reloading a narrow class of user-facing configuration: form-table view
settings, security policies, and similar admin-side preferences stored in
the DB. Most of the time you neither notice nor care.

**When the skill leaves lightstart ON.** Everything routine: code edits,
adding or modifying modules, changing properties / forms / actions, small
schema changes (a new `DATA` property, a new class). lsFusion handles these
incrementally with lightstart on, and the logic on the server is identical
to what a full start would load.

**When lightstart is forced OFF.** Two cases only: (1) the very first launch
on a fresh DB — no prior state to be incremental from; (2) the user
explicitly passes `-FullStart`. The skill does not silently decide for you
that a change is "significant enough" to require `-FullStart`; that call
belongs to the user.

**Don't propose `-FullStart` as a debugging step** for logic / schema /
startup problems. Not a fix for "Property not found", schema drift, count
mismatches, or compile errors — same code runs either way. Suggest
`-FullStart` only when the user explicitly cares about the user-facing
settings that lightstart skips (table-view layout, security-policy reload).
