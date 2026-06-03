# Troubleshooting an lsFusion deploy

Failure modes by symptom. Match the symptom column first, then read the cause and fix.

> The path and unit names below use the current upstream package generation `lsfusion6-*` — see the [naming convention](../SKILL.md#naming-convention-used-throughout-this-skill) in SKILL.md. If you're on a different generation, substitute the prefix accordingly. Multi-line scripts declare `PKG=lsfusion6` and use `${PKG}` throughout so the substitution is a one-character edit.

## Where to look

The platform writes to several files under `/var/log/<pkg>-server/` (where `<pkg>` is `lsfusion6` at the time of writing):

| File | What it has |
|---|---|
| `stdout.log` | Normal startup progress, module init, "Server has successfully started" or "Error starting server, server will be stopped" |
| `stderr.log` | The actual exception when init fails — read this whenever stdout says "Error starting server" |
| `sqlconnection.log` | PostgreSQL connection trace — useful for DB-side issues |
| `scheduler-system.log` | Background scheduler tasks — usually not interesting at deploy time |

Tomcat (the client) logs are at `/var/log/<pkg>-client/`, mostly under `catalina.out`. For "the UI doesn't load but the app server is up" issues, look there.

The convention in this skill is: when something fails, fetch the relevant log tail through ssh. `stdout.log` accumulates across boots — so when diagnosing "did THIS restart succeed", track the last `Current version:` line and read everything below it, not the whole file.

## Symptoms → causes

### 1. `stderr.log`: `Exception while starting logics instance: [error] ModuleName:LINE:COL no viable alternative at input '<keyword>'`

**Cause:** ANTLR parser couldn't recognize `.lsf` syntax at that location. Almost always means the platform on the server is older than the syntax the project uses.

**Diagnostic:**

```bash
# What version is the running platform?
ssh root@<host> 'grep "Current version" /var/log/lsfusion6-server/stdout.log | tail -1'
# What does the project's pom.xml parent expect?
grep -A2 '<parent>' pom.xml | grep '<version>'
```

If the project parent says `7.0-SNAPSHOT` and the server says `6.2 (XXX)`, you need to [upgrade the platform](#platform-version-mismatch).

**Counter-cause:** an actual `.lsf` typo in the project. Open the file at the reported line and check — if the same syntax works locally with the dev skill, it's a version mismatch.

**Fix (version mismatch):**

```bash
ssh root@<host> 'source <(curl -s https://download.lsfusion.org/apt/update-lsfusion6) 7.0-SNAPSHOT'
```

Or pass whatever maven baseVersion matches the project's parent POM. SNAPSHOT versions resolve to the latest timestamped build on `repo.lsfusion.org/nexus`.

### 2. `stderr.log`: `java.lang.RuntimeException: Dropping modules: <Name1>, ...` or `Dropping tables: <Name1>, ...`

**Cause:** The PostgreSQL database has metadata (modules) or concrete tables that the running configuration no longer declares. The platform refuses to drop them silently because that would destroy data.

These are **two distinct guards**, each with its own setting:

- **`Dropping modules`** is gated by `db.denyDropModules` — covers high-level removed modules (e.g. `ProcessUtils` deleted between platform versions, or a `REQUIRE` you removed from the top module).
- **`Dropping tables`** is gated by `db.denyDropTables` — covers concrete tables left behind when the new config doesn't map any class/property to them. Surprisingly common on a fresh server: install-lsfusion6 + update-lsfusion6 boots the bare platform once, which creates tables for default modules (`Chat`, `Schedule`, `Messenger`, `Geo`, `Icon`, …). The first deploy of a small custom config (whose `topModule` doesn't `REQUIRE` those) sees them as obsolete and trips this check.

If only `db.denyDropModules` is set and `db.denyDropTables` isn't, you can pass the first guard and immediately hit the second on the same restart. Set both together unless you have a reason not to.

When does each appear:

- Platform major-version upgrade and an old module was removed in the new platform → **modules**.
- You removed a `REQUIRE` from your top module → **modules**.
- First deploy of a small config onto a server that ran the bare platform first → **tables** (because bare-platform default modules left their tables behind).
- Refactor that removes classes or `DATA` properties → **tables**.

**Fix A (disposable data — typical for dev/test):** Allow drops globally, both flags at once.

```bash
ssh root@<host> 'bash -s' <<'CFG'
PKG=lsfusion6
SETTINGS=/etc/${PKG}-server/settings.properties
for k in db.denyDropModules db.denyDropTables; do
  grep -q "^$k" "$SETTINGS" || echo "$k = false" >> "$SETTINGS"
done
systemctl restart ${PKG}-server
CFG
```

**Fix B (production data — protect against unintended drops):** Allow only the specific names you've confirmed are safe. Use the matching list for whichever guard fired:

```bash
ssh root@<host> 'bash -s' <<'CFG'
PKG=lsfusion6
cat >> /etc/${PKG}-server/settings.properties <<'EOP'
db.allowDropModules = ProcessUtils, OldLegacyModule
db.allowDropTables  = Chat_chat, _auto_Schedule_Holidays
EOP
systemctl restart ${PKG}-server
CFG
```

Anything that needs dropping but isn't in the corresponding allow-list still fails loudly, so genuine surprises don't slip through.

**Fix C (clean slate — destructive):** Drop and recreate the DB. Use only when there is genuinely no data to preserve.

```bash
ssh root@<host> 'bash -s' <<'CFG'
PKG=lsfusion6
systemctl stop ${PKG}-server
sudo -u postgres dropdb lsfusion
sudo -u postgres createdb -O postgres lsfusion
systemctl start ${PKG}-server
CFG
```

### 3. `systemctl is-active` says `inactive` after restart, exit code is nonzero

**Cause:** the JVM exited during startup. `stderr.log` has the reason.

**Diagnostic flow:**

```bash
ssh root@<host> 'bash -s' <<'CFG'
PKG=lsfusion6
systemctl status ${PKG}-server --no-pager -l | head -25
echo "---"
tail -n 40 /var/log/${PKG}-server/stderr.log
echo "---"
journalctl -u ${PKG}-server --since "5 minutes ago" --no-pager | tail -50
CFG
```

Match the exception text against this file. If you can't find a matching symptom, paste the stack trace into the conversation and reason from there.

### 4. `systemctl is-active` says `active`, but `:7652` doesn't appear in `ss -tlnp`

**Cause:** the platform is still initializing. RMI binding happens at the **end** of startup — after parsing all `.lsf` modules, building the class graph, finishing DB sync. For a large multi-module config this can take 5+ minutes on the first run.

**Diagnostic:** read the tail of `stdout.log`. If you see lines like `Initializing main logic for module : #388 of 770 ...`, it's progressing — wait.

**Not-actually-a-bug:** Don't restart while it's still working. A second restart resets the migration progress and you start over. Pick a polling budget (5 min for huge configs) and stick to it.

### 5. `WARN: Failed to initialize tess4j. Add tess4j jar to classpath.`

**Cause:** Tesseract OCR library isn't bundled with the platform. lsFusion has an OCR action that needs it; if the project doesn't call OCR actions, the warning is harmless.

**Fix (if needed):**

```bash
# Download a release of tess4j and drop it next to your app.jar
ssh root@<host> 'cd /var/lib/lsfusion && wget https://repo1.maven.org/maven2/net/sourceforge/tess4j/tess4j/5.16.0/tess4j-5.16.0.jar'
ssh root@<host> 'chown lsfusion:lsfusion /var/lib/lsfusion/tess4j-5.16.0.jar'
ssh root@<host> 'systemctl restart lsfusion6-server'
```

Tesseract data files (`*.traineddata`) are a separate concern — install via `apt install tesseract-ocr` and set `TESSDATA_PREFIX` if your project uses non-default languages.

### 6. UI loads but shows the stock platform welcome page (title `lsfusion`, not your app name)

**Cause:** the app-server unit started, but it didn't pick up the app's `lsfusion.properties` — so it has no `logics.topModule` set, and the platform runs in its bare default state.

**Diagnostic** — ask the **running** server what it loaded; don't pull the deployed jar back down to inspect it:

```bash
# Is the jar where you think it is?
ssh root@<host> 'ls -la /var/lib/lsfusion/'
```

Then verify against the live server and your local source (see the **lsfusion-eval** skill for the endpoints):

- **`/eval/action`** — run a one-liner that touches a class/property from your top module. If `logics.topModule` wasn't set, the app's classes are unknown and the call errors out — that's your confirmation the module didn't load:

  ```bash
  curl -s -u admin: -X POST https://<host>/eval/action \
    --data-urlencode 'script=EXPORT FROM n = STRING(GROUP SUM 1 IF <AppClass> o IS <AppClass>);'
  ```

- **`/files/*`** source API on the web port — list/read the `.lsf` actually deployed on the running server.

- And confirm the **source you packaged** declared the module, before re-deploying:

  ```bash
  grep '^logics.topModule' target/classes/lsfusion.properties
  ```

**Common cause:** the jar was created with the staging directory as a top-level entry (`staging/lsfusion.properties` instead of just `lsfusion.properties`). Repack with `-C staging .` (jar) or by `cd staging && zip -r ../app.jar .` (zip).

### 7. Database connection failures: `Connection refused` / `FATAL: password authentication failed`

**Cause:** the app-server's `settings.properties` doesn't match what PostgreSQL actually has. The auto-installer sets `db.password=11111` and creates the `lsfusion` database; if anything was changed manually, `settings.properties` may drift.

**Diagnostic:**

```bash
ssh root@<host> 'bash -s' <<'CFG'
PKG=lsfusion6
cat /etc/${PKG}-server/settings.properties
echo "---"
sudo -u postgres psql -tAc "select 1"   # raw connectivity
sudo -u postgres psql -tAc "\du"        # what users exist
CFG
```

**Fix:** align `settings.properties` to actual DB state, or `ALTER USER postgres WITH PASSWORD '11111'` to restore the installer's default.

### 8. `bash: line 1: ﻿echo: command not found` (note the invisible character)

**Cause:** PowerShell 5.1 BOM bug. Heredocs piped through ssh from PowerShell get a UTF-8 BOM prepended (`﻿`), and the remote bash sees it as the first character of the script.

**Fix:** Always base64-encode bash scripts you send through ssh from PowerShell:

```powershell
$script = @'
your bash here
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
ssh root@<host> "echo $b64 | base64 -d | bash"
```

Detail in `references/ssh-from-windows.md`.

### 9. Public-key SSH auth fails immediately after installing the key

**Cause:** CRLF in `~/.ssh/authorized_keys`. PowerShell pipes converted the public-key bytes on the way out, and OpenSSH on the server rejects keys with stray CR characters.

**Diagnostic:**

```bash
ssh root@<host> 'cat -A ~/.ssh/authorized_keys'
# Bad: lines end in ^M$ (CR + LF)
# Good: lines end in $ (LF only)
```

**Fix:** re-append using `printf '%s\n' '<key-content>'` on the remote side, never via `Get-Content key.pub | ssh "cat >> authorized_keys"`. Full pattern in `references/ssh-from-windows.md`.

### 10. Deploy "succeeded" but `:8080` still shows the previous app version

**Cause:** Tomcat (the web client) caches static resources. The web-client unit is independent from the app-server unit — replacing `app.jar` only affects the application server.

**Fix:**

```bash
ssh root@<host> 'systemctl restart lsfusion6-client'
```

For app-server-side changes (new modules, modified `.lsf`, schema changes), restarting the app-server unit alone is enough — the web client picks up new metadata over RMI on its next request.

### 11. Out-of-memory during init (OOMKilled)

**Cause:** `-Xmx1g` is the auto-installer default. Large configs with many modules can need more, especially during first-time schema sync.

**Diagnostic:**

```bash
ssh root@<host> 'bash -s' <<'CFG'
PKG=lsfusion6
journalctl -u ${PKG}-server --since "10 minutes ago" | grep -i "oom\|killed\|signal"
systemctl show ${PKG}-server -p MemoryHigh,MemoryMax
CFG
```

**Fix:** bump heap in the app-server's `lsfusion.conf` (under `/etc/<pkg>-server/`):

```ini
FUSION_OPTS=-Xms2g -Xmx4g
CLASSPATH=/var/lib/lsfusion:/var/lib/lsfusion/*
```

```bash
ssh root@<host> 'systemctl daemon-reload && systemctl restart lsfusion6-server'
```

Match heap to host RAM; leave at least 512 MB headroom for PostgreSQL and the OS.

### 12. Stored / displayed text is `?` for every non-ASCII char (Cyrillic, accents, CJK)

Two independent culprits — check both:

- **Server side — JVM charset.** It derives from the service's `LANG`. A systemd service **does** inherit the system locale, so if `localectl` shows a `.UTF-8` locale (and the bundled JDK is 18+, where `file.encoding` is UTF-8 regardless) the server handles UTF-8 correctly. Only if the **system** locale is non-UTF-8 (`C`/`POSIX` → US-ASCII, `*.ISO-8859-1`, …) does the JVM get that charset and store `?`. Fix per [§1 locale](../SKILL.md#1-provision-a-fresh-server): set a `.UTF-8` system locale (or add `-Dfile.encoding=UTF-8` + a `LANG=…UTF-8` line to both `lsfusion.conf`s) and restart.
- **Client side (Windows) — the more common cause when seeding via the Action API.** Passing non-ASCII as an **inline `curl` argument** from Git Bash corrupts it *before it leaves your machine*: Git Bash re-encodes argv to the Windows ANSI codepage when spawning the native `curl.exe`, so non-CP1252 characters become `?` — the server only ever receives `?`. Tell-tale: rows sent from **PowerShell** come back correct while rows sent via inline `curl` are `?`, on the *same* server. Fix: send the script from a **file** (`curl --data-urlencode "script@file.lsf"`, which bypasses argv) or from **PowerShell** (`[uri]::EscapeDataString(...)` into the `?script=` query). See [references/ssh-from-windows.md](ssh-from-windows.md#trap-3).

## Recovery checklist (deploy is broken, can't quickly fix)

When you need the host back to a working state while you investigate locally:

```bash
# 1. Remove the broken jar — the platform goes back to its stock self
ssh root@<host> 'rm /var/lib/lsfusion/app.jar'

# 2. If a previous good jar is around, restore it
ssh root@<host> 'cp /var/lib/lsfusion/app.jar.prev /var/lib/lsfusion/app.jar 2>/dev/null'
ssh root@<host> 'chown lsfusion:lsfusion /var/lib/lsfusion/app.jar 2>/dev/null'

# 3. Restart and wait for "successfully started"
ssh root@<host> 'systemctl restart lsfusion6-server'
```

If the DB also got into a bad state during a failed migration, dropping and recreating is the surest reset — only do this when there's no data worth keeping (covered in Fix C of symptom 2).

## When in doubt: full state dump

If you can't make sense of the failure from this catalog, gather everything at once and reason from the dump:

```bash
ssh root@<host> 'bash -s' <<'EOF'
PKG=lsfusion6
echo "=== version ===" ; grep 'Current version' /var/log/${PKG}-server/stdout.log | tail -3
echo "=== service ===" ; systemctl status ${PKG}-server --no-pager -l | head -25
echo "=== ports ===" ; ss -tlnp | awk '/:(5432|7651|7652|8080)\>/'
echo "=== drop folder ===" ; ls -la /var/lib/lsfusion/
echo "=== install settings ===" ; cat /etc/${PKG}-server/settings.properties
echo "=== last stderr ===" ; tail -n 50 /var/log/${PKG}-server/stderr.log
echo "=== last stdout ===" ; tail -n 30 /var/log/${PKG}-server/stdout.log
EOF
```

From Windows PowerShell, base64-wrap that block per `references/ssh-from-windows.md`.
