---
name: lsfusion-deploy
description: Deploy an lsFusion application to a remote Linux server (Ubuntu/Debian or RHEL family). Covers fresh-server provisioning via the official auto-installer from download.lsfusion.org, switching the installed platform between major versions or release channels when the project requires it, packaging the configuration into a jar that drops into /var/lib/lsfusion, managing the lsFusion app-server and web-client systemd units, enabling HTTPS for the web client via Let's Encrypt / certbot (with optional HTTP→HTTPS redirect), and pulling a snapshot of the remote PostgreSQL database to drive a local lsfusion-dev instance for debugging. Triggers whenever the user wants to install lsFusion on a remote host, push an lsFusion project (existing Maven repo from GitHub OR hand-written .lsf files) to a server via ssh/scp, upgrade or downgrade the platform on a running install, set up TLS on the lsFusion web client, run / debug the production database locally against the dev source tree, or diagnose a stopped lsFusion service / failed schema migration / "Dropping modules" / "Dropping tables" / "no viable alternative" parse error situation. Use it for any task mixing ssh + systemctl + lsfusion, or any mention of "deploy lsfusion", "install lsfusion on the server", "ship the config to the server", "upgrade the platform", "push the .lsf to a host", "enable https on lsfusion", "pull the prod DB locally", "test remote data locally". For LOCAL Windows development (running .lsf on this machine) use the lsfusion-dev skill instead.
---

# lsFusion remote deploy

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

This skill takes an lsFusion configuration — whether a Maven project from GitHub or `.lsf` files written from scratch — and gets it serving on a remote Linux server managed by systemd, talking to a real PostgreSQL.

## Before you start: switch to accept-edits mode

A deploy session is dozens of `ssh`, `scp`, `sudo`, `systemctl restart`, `dropdb`, `chown`, file-edit-via-ssh calls. In Claude Code's **auto mode**, the LLM-based safety classifier flags many of these as risky (network mutations, root-owned config edits, service restarts, destructive DB operations) and either blocks them or interrupts the flow with confirmation prompts. The result is a deploy that stops every few steps even though every action is intended and authorized.

Before starting any of the steps below, tell the user to switch to **accept-edits** mode (`/permissions` → set permission mode, or `shift+tab` to cycle modes — the footer should read `accept edits`). In that mode tool calls run without per-call classification, and the user still sees a transcript of every action. The deploy goes through end-to-end.

If the user wants to stay in auto mode, expect to surface each ssh/systemctl/scp call individually and walk them through approving it; the workflow still works, it's just slow.

## Mental model

After a clean install the server has **three** moving parts:

- **PostgreSQL** — listens on `127.0.0.1:5432`. The auto-installer creates it with user `postgres` / password `11111` / database `lsfusion`.
- **The application-server unit** (systemd) — the JVM running the platform plus your config. Binds RMI on `:7652` and the HTTP Action API on `:7651`. The platform install lives in `/usr/share/<pkg>-server/`, the **drop-folder** for your app is `/var/lib/lsfusion/`.
- **The web-client unit** (systemd) — Tomcat 9 with the lsFusion web-client war. Browser UI on `:8080`.

The application server's CLASSPATH is `/var/lib/lsfusion:/var/lib/lsfusion/*:server.jar` (defined in the unit's `lsfusion.conf`). Anything you drop into `/var/lib/lsfusion/` becomes visible to the platform — jars via the wildcard, loose files via the directory entry.

### Naming convention used throughout this skill

The auto-installer publishes everything under a single package generation, currently named **`lsfusion6`**. So at the time of writing the concrete names are:

| What | Name |
|---|---|
| systemd app-server unit | `lsfusion6-server` |
| systemd web-client unit | `lsfusion6-client` |
| auto-install script | `install-lsfusion6` |
| platform-upgrade script | `update-lsfusion6` |
| install dir | `/usr/share/lsfusion6-server/` |
| config dir | `/etc/lsfusion6-server/` |
| logs dir | `/var/log/lsfusion6-server/` |

This `lsfusion6-*` name is **a fixed packaging identifier; it is not tied to the platform version of the jar inside it**. `update-lsfusion6 <version>` swaps the platform jar (and matching web-client war) for any version Nexus knows about while the package metadata stays the same.

If upstream ever ships a new generation (e.g. `lsfusion7-*`), substitute that name in every command below — the **structure** of the deploy is the same. Long shell blocks in this skill declare a single `PKG=lsfusion6` variable at the top and use `${PKG}` throughout, so updating to a new generation is a one-character edit; short single-line commands keep the literal name for readability.

### Where install-specific parameters live (and why `/etc/lsfusion6-server/settings.properties` IS `conf/settings.properties`)

Every runtime parameter for the deployed install — `db.server`, `db.name`, `db.user`, `db.password`, `db.denyDrop*`, `rmi.port`, anything else — goes into **one file**: `/etc/lsfusion6-server/settings.properties`. Don't scatter overrides into the jar, into systemd drop-ins, or anywhere else.

lsFusion's documented parameter-resolution chain reads "install-specific overrides" from **`conf/settings.properties` relative to the JVM's working directory**. The apt installer wires that path to the writable config like this:

- The systemd unit sets `WorkingDirectory=/usr/share/lsfusion6-server`.
- That directory contains a symlink `conf -> /etc/lsfusion6-server`.
- So when lsFusion opens `conf/settings.properties` it resolves to `/usr/share/lsfusion6-server/conf/settings.properties` → `/etc/lsfusion6-server/settings.properties` — the file you actually edit.

Treat the two names as synonyms; the rest of this skill writes the `/etc/...` path because that's where the bytes physically live (and where you `cat`/`sed` them), but mentally it is `conf/settings.properties` from lsFusion's point of view.

Per the resolution chain, anything in this file is overridden by JVM `-D...` arguments (passed via `FUSION_OPTS` in `/etc/lsfusion6-server/lsfusion.conf`) and by DB-stored settings. It overrides `lsfusion.properties` baked into the jar. So if a key you set in `/etc/lsfusion6-server/settings.properties` appears to have no effect, look for a `-D<key>=<other>` in `lsfusion.conf` first — that's the only layer above it that an install ever touches.

## Decision tree

Pick the path based on what the user wants:

| Situation | Steps |
|---|---|
| Server doesn't exist yet, fresh install + first deploy | [Provision](#1-provision-a-fresh-server) → [Enable HTTPS](#1b-enable-https-via-lets-encrypt-recommended) → [Package](#3-package-the-application) → [Deploy](#4-deploy-and-restart) |
| Server exists, deploying an app for the first time | [Package](#3-package-the-application) → [Deploy](#4-deploy-and-restart) |
| Server exists, deploying an updated jar | [Package](#3-package-the-application) → [Deploy](#4-deploy-and-restart) (idempotent — same flow) |
| Project targets a different platform major version than the server has | [Upgrade platform](#2-upgrade-or-switch-the-platform-version) → continue |
| Existing server, user wants HTTPS on the web client | [Enable HTTPS](#1b-enable-https-via-lets-encrypt-recommended) |
| User wants to debug / develop against the **remote DB** locally | [Pull remote DB local](#5-pull-the-remote-db-to-run-locally) |
| Diagnosing a failed deploy | [Troubleshooting](#troubleshooting) + [references/troubleshooting.md](references/troubleshooting.md) |

For LOCAL Windows development without a remote host, use the **lsfusion-dev** skill. The two skills are complementary — lsfusion-dev runs the same project on this machine; this skill ships it elsewhere.

If the user is on Windows and doesn't have key-based SSH yet, read [references/ssh-from-windows.md](references/ssh-from-windows.md) before anything else — that file also explains the PowerShell 5.1 BOM workaround you'll use throughout this skill.

## 1. Provision a fresh server

Prerequisites:
- Ubuntu 18+ / Debian 9+ (or RHEL 8+ / CentOS 8+ / Fedora 35+ for the dnf variant)
- `curl`, `systemd`, bash login shell, internet access to `download.lsfusion.org` and distro mirrors
- ≥1.5 GB free disk, ≥1.5 GB free RAM (server JVM defaults to `-Xms1g -Xmx1g`)
- root or sudo
- **System locale must end in `.UTF-8` BEFORE running the installer** — both lsFusion services inherit `LANG` from the systemd default, and the JVM derives `file.encoding` from it. Any non-UTF-8 charset (the default `C`/`POSIX` → `US-ASCII`, the legacy `en_US.ISO-8859-1`, `ru_RU.CP1251`, `zh_CN.GBK`, …) silently corrupts every non-ASCII byte that flows through the platform — Cyrillic, accents, CJK get turned into literal `?` (0x3F) in storage. Check first, only change if needed, and **keep the language part** of the existing locale (don't override the user's regional preference — just switch the encoding suffix):

  ```bash
  ssh root@<host> 'bash -s' <<'EOS'
  CUR=$(localectl status 2>/dev/null | awk -F= '/LANG=/{print $2}')
  CUR=${CUR:-${LANG:-C}}
  echo "current LANG=$CUR"
  case "$CUR" in
      *.UTF-8|*.utf8) echo "already UTF-8, nothing to do" ;;
      C|POSIX)        TARGET=C.UTF-8 ;;                                   # no language preference yet
      *.*)            TARGET="${CUR%.*}.UTF-8" ;;                         # e.g. en_US.ISO-8859-1 -> en_US.UTF-8
      *)              TARGET="${CUR}.UTF-8" ;;                            # e.g. en_US -> en_US.UTF-8
  esac
  if [ -n "$TARGET" ]; then
      # Debian/Ubuntu: ensure the target is generated, then activate
      command -v locale-gen >/dev/null && { sed -i "s/^# *\(${TARGET} .*\)/\1/" /etc/locale.gen 2>/dev/null; locale-gen "$TARGET" >/dev/null 2>&1 || true; }
      update-locale LANG="$TARGET"
      echo "set LANG=$TARGET — log out / re-ssh so the change propagates before running the installer"
  fi
  EOS
  ```

  Verify after the installer finishes: `ssh root@<host> "systemctl show lsfusion6-server -p Environment"` should show the chosen `LANG=*.UTF-8`. If the install happened before the locale was fixed, recovery is to patch both `/etc/lsfusion6-{server,client}/lsfusion.conf` — add `LANG=<chosen>.UTF-8` on its own line and `-Dfile.encoding=UTF-8` to `FUSION_OPTS` / `CATALINA_OPTS` — then restart both units.

Run the official auto-installer (from https://docs.lsfusion.org/Execution_auto/). **Always launch detached, never inline.** The installer downloads ~380 MB of `.deb`s (OpenJDK + PostgreSQL 18 + Tomcat 9 + lsfusion6-server + lsfusion6-client), and over an average internet link that takes 4–10 minutes — comfortably longer than typical ssh `ClientAliveInterval` / harness command timeouts. A foreground

```bash
ssh root@<host> "curl -s https://download.lsfusion.org/apt/install-lsfusion6 | bash"   # ❌
```

reliably dies mid-`apt-get` on slow links — the local ssh session times out, you get a non-zero exit, but apt is still running on the remote and there's nothing you can `pgrep` for. The right invocation **decouples ssh duration from install duration**:

```bash
# Ubuntu / Debian
ssh root@<host> "nohup bash -c 'curl -s https://download.lsfusion.org/apt/install-lsfusion6 | bash > /tmp/install.log 2>&1' >/dev/null 2>&1 & echo started"

# RHEL / CentOS / Fedora — same shape, /dnf/ path
ssh root@<host> "nohup bash -c 'curl -s https://download.lsfusion.org/dnf/install-lsfusion6 | bash > /tmp/install.log 2>&1' >/dev/null 2>&1 & echo started"
```

`nohup … &` keeps apt running after the ssh disconnects; `> /tmp/install.log 2>&1` captures its output for later polling; `>/dev/null 2>&1` on the outer ssh detaches its own streams (without this, ssh waits for the background job's fds to close and the trick defeats itself); `& echo started` lets ssh return immediately. After this call returns, the installer is the remote's problem, not the ssh session's.

**Detecting completion: don't watch stdout, watch artifacts.** Neither `install-lsfusion6` nor `update-lsfusion6` writes a terminating "done" / "complete" / "finished" line. The last stdout lines are whatever apt's `dpkg --configure --pending` happened to print last — usually unrelated chatter like "No containers need to be restarted" — so any watcher that does `tail | grep -E "complete|finished"` will hang forever even though the script exited cleanly. Three reliable completion signals, pick whichever fits the situation:

- **Process gone.** Match the lsFusion *orchestrator script* only — `pgrep -af '[i]nstall-lsfusion6'` (install) or `pgrep -af '[u]pdate-lsfusion6|[w]get'` (update). **The bracket — `[i]nstall` not `install` — is mandatory, not cosmetic** (see the self-match gotcha below). **Do NOT put generic `apt-get` / `dpkg` / `unattended-upgr` in this check.** Ubuntu runs apt and dpkg on its own daily timers (`apt-daily`, `unattended-upgrades`), so `pgrep apt-get|dpkg` routinely matches unrelated background activity and reports **"busy" forever even after the lsFusion install/update has already finished**. (Observed on Ubuntu 26.04: an update-poll gated on `apt-get|dpkg` going idle never exited, although the new platform was up and both services were `active` — see the apt-timer gotcha below.)
- **Package installed** (for install only). `dpkg -l | grep '^ii.*lsfusion6-server'` matches.
- **Service back up after the swap** (for update only). Snapshot `grep "Server has successfully started" /var/log/lsfusion6-server/stdout.log | wc -l` BEFORE the upgrade, then wait until that count goes up — this is the **only** signal that the new platform jar actually started, not just landed on disk.

**Gate completion on the artifact, not on apt being idle.** The robust condition is the *artifact* — package installed (install) or success-count-up + both units `active` (update) — optionally AND'd with the lsFusion orchestrator script being gone. Never gate on generic apt/dpkg idling. Pragmatic loops:

```bash
# install:  until the package is configured AND the installer script has exited
until ! pgrep -f '[i]nstall-lsfusion6' >/dev/null && dpkg -l 2>/dev/null | grep -q '^ii.*lsfusion6-server'; do sleep 15; done
# update:   until the success-count rose past baseline AND both units are active
until [ "$(grep 'Server has successfully started' "$LOG" | wc -l)" -gt "$BASE" ] \
      && systemctl is-active lsfusion6-server lsfusion6-client >/dev/null; do sleep 15; done
```

Don't add a stdout-grep clause "for safety" — it doesn't add safety, it just prevents the loop from ever exiting.

> **Gotcha — apt/dpkg run on OS timers, so "apt is idle" is not a completion signal.** On Ubuntu the `apt-daily.timer` / `unattended-upgrades` services fire `apt-get`/`dpkg` independently of your install. Any poll that treats `pgrep apt-get|dpkg` as "still working" can hang indefinitely on that background noise. Watch the lsFusion-specific artifact (package `ii` / success-count / service `active`), and if you must check a process, match `[i]nstall-lsfusion6` / `[u]pdate-lsfusion6` (and `[w]get` for the update's jar/war download), never bare `apt-get`/`dpkg`.

> **Gotcha — `pgrep` self-match: bracket the pattern or the poll never exits.** These checks run over SSH, so the command bash executes on the remote is literally `bash -c "… pgrep -af 'install-lsfusion6' …"` — a process whose *own command line contains the search string*. `pgrep -f` scans full command lines, so it matches the watcher itself → always ≥1 hit → a `! pgrep …` completion test is **always false** and the loop spins forever, even though the real installer exited minutes ago. (Observed on Ubuntu 26.04: `pgrep -af install-lsfusion6` returned a single line that *was the poll command itself*, PID and all.) Fix: bracket the first character — `pgrep -af '[i]nstall-lsfusion6'`. The regex `[i]nstall…` still matches the real `install-lsfusion6` process, but the watcher's own command line now holds the literal text `[i]nstall…` (where `i` is followed by `]`, not `n`), so it no longer matches itself. Same trick for `[u]pdate-lsfusion6` / `[w]get`. This is the deeper reason the **artifact** (package `ii` / success-count / service `active`) is the primary completion signal and the process check is only a secondary AND.

> **Gotcha — counting log lines: use `grep | wc -l`, never `grep -c … || echo 0`.** `grep -c` on a file with **zero** matches both **prints `0` to stdout AND returns exit-status 1**. The "obvious" defensive form `$(grep -c PAT file 2>/dev/null || echo 0)` therefore appends a *second* `0` (so the variable becomes the string `"00"`, or worse, `"0\n0"` depending on how it's captured) and any `[ "$VAR" -gt "$BASE" ]` comparison below either evaluates wrong or errors out with "integer expression expected". This bites the success-line baseline pattern that this skill uses everywhere ("snapshot count BEFORE upgrade, wait for it to go up"). Always:
>
> ```bash
> BASE=$(grep "Server has successfully started" "$LOG" 2>/dev/null | wc -l)
> # NOT: BASE=$(grep -c "Server has successfully started" "$LOG" 2>/dev/null || echo 0)
> ```
>
> `grep | wc -l` always exits 0 (it's `wc`'s exit), always prints one integer, and gives a clean number even on an empty/missing file. The same logic applies to any "count this thing in a possibly-empty file" check in shell.

**How to run that loop from a harness tool: `Bash(run_in_background=true)` + `Monitor`, NOT `ScheduleWakeup` with a fixed delay.** A fixed wakeup is an uninformed guess at duration — small VM with good bandwidth: 4 min; under-provisioned: 10+ min. Pick 4 and you wake mid-install with nothing to do; pick 10 and finished installs sit untouched for several minutes. Background-Bash + Monitor inverts that: the loop prints a one-line status per iteration, Monitor re-invokes on every line and on loop exit, so you react the moment the install actually finishes.

```bash
# 1. Kick install on the remote (detached — not harness-tracked).
ssh root@<host> "nohup bash -c 'curl -s https://download.lsfusion.org/apt/install-lsfusion6 | bash > /tmp/install.log 2>&1' >/dev/null 2>&1 & echo started"

# 2. Local watcher — call as Bash(run_in_background=true). Each iteration prints
#    one status line that Monitor surfaces as a separate event.
while sleep 20; do
    ssh -o BatchMode=yes root@<host> "tail -1 /tmp/install.log; printf 'pkg=%s ' \"\$(dpkg -l 2>/dev/null | grep -c '^ii.*lsfusion6-server')\"; pgrep -af '[i]nstall-lsfusion6' >/dev/null && echo running || echo idle"
    # DONE = artifact present AND installer script gone. Note: match ONLY
    # '[i]nstall-lsfusion6', never 'apt-get|dpkg' — Ubuntu's apt timers run those
    # on their own and would keep the loop "busy" forever (see apt-timer gotcha).
    ssh -o BatchMode=yes root@<host> "! pgrep -af '[i]nstall-lsfusion6' >/dev/null && dpkg -l 2>/dev/null | grep -q '^ii.*lsfusion6-server'" && { echo DONE; break; }
done

# 3. Monitor that background task. The until-clause re-invokes you when the
#    loop prints "DONE" (or any line containing it) and on process exit.
# Monitor(taskId=<task-id-from-step-2>, until="DONE")
```

Reserve `ScheduleWakeup` for **external** state the harness genuinely can't watch — a remote CI build kicked off by a webhook, a cloud queue you can't poll, a fixed-time appointment. For anything you can `tail`/`pgrep`/`grep` over SSH (which is everything in this skill), the right tool is background-Bash + Monitor. The failure mode of the wrong choice is silent dead time, which is what the user notices.

Verify (substitute `PKG` for the upstream package generation — see [Naming convention](#naming-convention-used-throughout-this-skill)):

```bash
PKG=lsfusion6
ssh root@<host> "systemctl is-active ${PKG}-server ${PKG}-client postgresql"
ssh root@<host> "ss -tlnp | awk '/:(5432|7651|7652|8080)\\>/'"
curl -sI http://<host>:8080/ | head -1                              # expect 200
curl -s http://<host>:8080/ | grep -o '<title>[^<]*</title>'        # default: <title>lsfusion</title>
```

The web UI on `:8080` shows the **default lsFusion landing page** (title `lsfusion`) until you deploy an app — that's how you'll later know your config kicked in (the title becomes your app name).

Once the install is verified green, **proactively offer to enable HTTPS** before moving on — see [section 1b](#1b-enable-https-via-lets-encrypt-recommended). Don't wait for the user to ask. Setting it up now means every subsequent verify command runs over `https://` and the app, once deployed, is reachable on the canonical URL out of the gate.

## 1b. Enable HTTPS via Let's Encrypt (recommended)

A fresh install serves plain HTTP on `:8080` only. If the host has public DNS and is reachable from the internet, getting a real TLS cert is a 2-minute job and makes the rest of the session — and the app once deployed — usable on `https://<host>/`. Always offer this; don't silently skip.

Ask the user **two** questions up front (use the question-prompt UI, don't assume the answer):

1. **"Set up HTTPS via Let's Encrypt now?"** — default **Yes**. Requires: DNS A record for `<host>` resolves to this server, ports 80/443 reachable from the internet, ports 80/443 free on the box (auto-installer doesn't bind them).
2. **"Redirect plain HTTP to HTTPS?"** — default **Yes**. Yes: `http://<host>/` → 302 to `https://<host>/`. No: port 80 returns nothing, users must type `https://` explicitly.

If question 1 is declined, skip to section 2/3. Otherwise:

### Preflight

```bash
ssh root@<host> 'bash -s' <<'EOS'
echo "Box external IP:"; curl -s4 ifconfig.me; echo
echo "DNS for <host>:"; getent hosts <host>
echo "Ports 80/443 currently bound on the box:"; ss -tln | awk '/:(80|443)\>/' || echo "  (free)"
EOS
```

DNS must point at this box's external IP; ports 80/443 must be free (the standalone ACME challenge binds 80 directly).

### Install certbot, issue the certificate, install renewal hooks

```bash
ssh root@<host> 'bash -s' <<'EOS'
PKG=lsfusion6
HOST=<host>
EMAIL=<email>          # picks up renewal/expiry warnings — use one the user reads

DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot iptables-persistent netfilter-persistent

certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL" -d "$HOST"

# --- Permissions: don't chmod -R +r (world-readable privkey). Grant read to
# group lsfusion only, and re-apply on every renewal (certbot creates new
# cert<N>.pem files with default root-only perms).
chown -R root:lsfusion /etc/letsencrypt/archive /etc/letsencrypt/live
chmod  -R u=rwX,g=rX,o= /etc/letsencrypt/archive /etc/letsencrypt/live

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/lsfusion.sh <<'HOOK'
#!/bin/bash
set -e
chown -R root:lsfusion /etc/letsencrypt/archive /etc/letsencrypt/live
chmod  -R u=rwX,g=rX,o= /etc/letsencrypt/archive /etc/letsencrypt/live
systemctl restart lsfusion6-client
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/lsfusion.sh

# Sanity: lsfusion user must be able to read the privkey
sudo -u lsfusion test -r /etc/letsencrypt/live/$HOST/privkey.pem && echo "privkey readable by lsfusion: OK"
EOS
```

The auto-installer enables `certbot.timer` so renewals run twice daily without action from you. The deploy hook above restarts `lsfusion6-client` after each successful renewal so Tomcat picks up the new cert — Tomcat reads cert files at startup and doesn't re-read them otherwise.

### Redirect privileged ports to Tomcat

Tomcat runs as `lsfusion` and can't bind 443/80 directly. Redirect via iptables and persist:

```bash
ssh root@<host> 'bash -s' <<'EOS'
# 443 -> 8443: always
iptables -t nat -C PREROUTING -p tcp --dport 443 -j REDIRECT --to-ports 8443 2>/dev/null \
  || iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-ports 8443

# 80 -> 8080: ONLY if user answered "Yes" to the redirect question.
# Skip this block entirely otherwise.
iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 8080 2>/dev/null \
  || iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 8080

netfilter-persistent save
EOS
```

**If you added the 80→8080 rule, certbot renewals will fail** — at renewal time `certbot --standalone` needs to bind 80 directly, but the iptables rule steals incoming traffic. Add pre/post hooks that flip the rule off during renewal:

```bash
ssh root@<host> 'bash -s' <<'EOS'
mkdir -p /etc/letsencrypt/renewal-hooks/{pre,post}

cat > /etc/letsencrypt/renewal-hooks/pre/free-port-80.sh <<'PRE'
#!/bin/bash
iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 8080 2>/dev/null || true
PRE

cat > /etc/letsencrypt/renewal-hooks/post/restore-port-80.sh <<'POST'
#!/bin/bash
iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 8080 2>/dev/null \
  || iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports 8080
POST

chmod 0755 /etc/letsencrypt/renewal-hooks/pre/free-port-80.sh \
           /etc/letsencrypt/renewal-hooks/post/restore-port-80.sh
EOS
```

### Add the SSL connector to Tomcat

Patch `/etc/lsfusion6-client/server.xml` and insert a new `<Connector port="8443">` before `</Service>`. The two `<Connector port="8443">` blocks already in the file are Tomcat shipping defaults pointing at `localhost-rsa.jks` and they're inside `<!-- -->` — don't uncomment those; add a fresh one targeting the Let's Encrypt files. Idempotent insertion via `awk` (looks for the `LETSENCRYPT-<host>` marker so re-running the skill is safe):

```bash
ssh root@<host> 'bash -s' <<'EOS'
HOST=<host>
SRV=/etc/lsfusion6-client/server.xml
cp -n "$SRV" "$SRV.bak"
if ! grep -q "LETSENCRYPT-$HOST" "$SRV"; then
  awk -v h="$HOST" '
    /<\/Service>/ && !done {
      print "    <!-- LETSENCRYPT-" h " -->"
      print "    <Connector port=\"8443\" protocol=\"org.apache.coyote.http11.Http11NioProtocol\""
      print "               maxThreads=\"150\" SSLEnabled=\"true\" >"
      print "        <SSLHostConfig>"
      print "            <Certificate certificateKeyFile=\"/etc/letsencrypt/live/" h "/privkey.pem\""
      print "                         certificateFile=\"/etc/letsencrypt/live/" h "/cert.pem\""
      print "                         certificateChainFile=\"/etc/letsencrypt/live/" h "/chain.pem\""
      print "                         type=\"RSA\" />"
      print "        </SSLHostConfig>"
      print "    </Connector>"
      done = 1
    }
    { print }
  ' "$SRV" > "$SRV.new" && mv "$SRV.new" "$SRV"
fi
EOS
```

### (Redirect=Yes only) Force HTTPS at the Tomcat layer

Two edits in `/etc/lsfusion6-client/`:

1. **`server.xml`** — set the plain HTTP connector's `redirectPort` to `443` (the external port the user sees), not `8443`:

   ```bash
   sed -i 's/redirectPort="8443"/redirectPort="443"/' /etc/lsfusion6-client/server.xml
   ```

2. **`web.xml`** — add a global `security-constraint` so every URL requires `CONFIDENTIAL` transport. Tomcat then issues a 302 to `redirectPort` for any HTTP request. Insert right before `</web-app>`:

   ```bash
   ssh root@<host> 'bash -s' <<'EOS'
   WX=/etc/lsfusion6-client/web.xml
   cp -n "$WX" "$WX.bak"
   if ! grep -q "LETSENCRYPT-redirect" "$WX"; then
     awk '
       /<\/web-app>/ && !done {
         print "    <!-- LETSENCRYPT-redirect -->"
         print "    <security-constraint>"
         print "        <web-resource-collection>"
         print "            <web-resource-name>HTTPS only</web-resource-name>"
         print "            <url-pattern>/*</url-pattern>"
         print "        </web-resource-collection>"
         print "        <user-data-constraint>"
         print "            <transport-guarantee>CONFIDENTIAL</transport-guarantee>"
         print "        </user-data-constraint>"
         print "    </security-constraint>"
         done = 1
       }
       { print }
     ' "$WX" > "$WX.new" && mv "$WX.new" "$WX"
   fi
   EOS
   ```

### Restart, verify, and sanity-check renewal

```bash
ssh root@<host> "systemctl restart lsfusion6-client"
# Tomcat takes ~5–10 s. Then from outside the box:
curl -sI https://<host>/ | head -1                                      # expect 200
echo | openssl s_client -servername <host> -connect <host>:443 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates                         # expect Let's Encrypt issuer
# Redirect=Yes only:
curl -sI http://<host>/ | head -2                                       # expect 302 + Location: https://<host>/...

# End-to-end renewal simulation — runs every hook (pre removes iptables 80,
# certbot rebinds 80, post restores). If this fails, the real renewal in
# ~60 days fails silently. Fix it now.
ssh root@<host> "certbot renew --dry-run"
```

## 2. Upgrade or switch the platform version

The apt/dnf installer ships under a single `lsfusion6-*` package generation with a fixed bundled platform version. If the project targets a different platform version — most commonly because it pins a SNAPSHOT branch (e.g. the parent POM declares `lsfusion.platform.build:logics:7.0-SNAPSHOT`), or just a different major release — swap the platform jar/war in place via `update-lsfusion6`:

```bash
source <(curl -s https://download.lsfusion.org/apt/update-lsfusion6) <maven-baseVersion>
# e.g.
source <(curl -s https://download.lsfusion.org/apt/update-lsfusion6) 7.0-SNAPSHOT
```

What it does (read the script if in doubt: `curl -s https://download.lsfusion.org/apt/update-lsfusion6`):

1. Stops the app-server unit.
2. Downloads `server-<version>-assembly.jar` from `repo.lsfusion.org/nexus` into the platform install dir.
3. Starts the app-server unit — **this is when DB migration runs** and can fail.
4. Stops the web-client unit, downloads matching `web-client-<version>.war`, extracts it into the client's webapp dir, starts the client.

You can pass any Maven baseVersion Nexus knows about — `7.0`, `7.0-SNAPSHOT`, `6.2`. SNAPSHOT versions resolve to the latest timestamped build. Running update again when the latest SNAPSHOT in Nexus is already the one on disk is a no-op for the jar content (sha256 will match before/after), but the script still restarts both services — so the live process changes even when the jar doesn't.

Same completion-detection caveat as the installer applies — `update-lsfusion6` also exits silently with no terminating stdout marker. See the **"Detecting completion: don't watch stdout, watch artifacts"** callout above; for an update the right signal is the `Server has successfully started` count going up past a pre-update baseline.

**Migration failures are common after a major-version bump.** The PostgreSQL database holds metadata for the **previous** platform. A new platform may have removed modules that the old one created tables for, and lsFusion refuses to drop them by default → `java.lang.RuntimeException: Dropping modules: <Name>`. Fix: add `db.denyDropModules = false` to `/etc/lsfusion6-server/settings.properties` and restart. See [references/troubleshooting.md](references/troubleshooting.md) for the full failure catalog.

If the DB is empty / disposable, the simplest path is to nuke it before the version switch:

```bash
ssh root@<host> 'bash -s' <<'EOS'
PKG=lsfusion6
systemctl stop ${PKG}-server
sudo -u postgres dropdb lsfusion
sudo -u postgres createdb -O postgres lsfusion
EOS
```

Destructive — only do this if there's no data to preserve.

## 3. Package the application

What the platform needs at runtime is **one classpath entry** that contains:

- All `.lsf` modules at paths matching their `MODULE` namespace
- A root-level `lsfusion.properties` declaring at least `logics.topModule = <Name>`
- Compiled `.class` files for any Java helpers referenced by `.lsf` (`INTERNAL` actions, etc.)
- Static resources (icons, reports, sql snippets, web assets) the modules load by classpath

A jar (zip with `.jar` extension) is the cleanest shape — single file, easy ownership and atomic replacement. The two project layouts you'll meet:

### Existing Maven project (typical GitHub layout)

A Maven lsFusion project (`pom.xml` at root, `src/main/lsfusion/<ns>/*.lsf`, `src/main/resources/lsfusion.properties`, optional `src/main/java/...`) builds into `target/classes/`. **Important**: `target/classes/` is the right thing to ship — it contains a mix of two things you might not expect to coexist:

- `.lsf` files **copied verbatim** from `src/main/lsfusion/` (preserving the subdir tree)
- Properties and other resources copied from `src/main/resources/`
- Compiled `.class` files produced from `src/main/java/`
- A `builddef.lst` written by the build (AspectJ descriptor — harmless at runtime, ignore it)

That mixed layout IS what the platform expects on classpath. Build, then jar:

```powershell
# from project root, on Windows
mvn -q -DskipTests compile               # makes target/classes fresh
$jar = "$env:JAVA_HOME\bin\jar.exe"      # or any local JDK
& $jar --create --file=app.jar -C target\classes .
```

```bash
# or on Linux/macOS
mvn -q -DskipTests compile
jar cf app.jar -C target/classes .
```

Output `app.jar` is what you scp. Typical size: 5–20 MB.

**Do not run `mvn package` for deploy.** It produces a fat jar including transitive deps — including the platform `server.jar`. Bundling a platform jar into the app, when the server already has its own platform jar in classpath, leads to confusing version-mix failures. Ship only the application content.

### From-scratch project (no Maven)

If the user wrote `.lsf` files by hand without a Maven setup, assemble the same target-classes-like layout manually:

```
staging/
├── lsfusion.properties        # at the root — required
├── <TopModule>.lsf            # the entry module declared by logics.topModule
└── <namespace>/               # subdirs mirror MODULE namespaces
    └── ...
```

Minimum `lsfusion.properties`:

```properties
logics.topModule = <TopModule>
db.denyDropModules = false
```

Then zip with a `.jar` extension (Java jars are zips):

```powershell
Compress-Archive -Path staging\* -DestinationPath app.jar -Force
```

```bash
cd staging && zip -r ../app.jar . && cd ..
```

If the project includes Java helper classes (Action subclasses called from `.lsf`), they must be **pre-compiled** to `.class` files at the right package path under `staging/`. There's no compile step in the from-scratch flow — if there's `.java` to compile, switch to a Maven layout (or `javac` the files manually with the platform `server.jar` on classpath).

See [references/packaging.md](references/packaging.md) for the full layout rules (MODULE-namespace ↔ filesystem path, where icons/reports/sql live, multi-module projects, common omissions).

## 4. Deploy and restart

Substitute `<host>` and adjust `app.jar` to whatever you produced:

```bash
# 1. Upload — use scp, NOT a `Get-Content | ssh` pipe. PowerShell will silently
#    inject CR characters into the stream and the jar will be corrupt.
scp app.jar root@<host>:/var/lib/lsfusion/app.jar

# 2 + 3 + 4. Fix ownership, set migration flags, restart.
#    PKG is the upstream package generation (see Naming convention above).
ssh root@<host> 'bash -s' <<'EOS'
PKG=lsfusion6
chown lsfusion:lsfusion /var/lib/lsfusion/app.jar

# Both flags are needed: dropModules covers removed modules between platform
# versions, dropTables covers obsolete tables left behind when the running
# config no longer declares classes/properties that were there before.
for k in db.denyDropModules db.denyDropTables; do
  grep -q "^$k" /etc/${PKG}-server/settings.properties \
    || echo "$k = false" >> /etc/${PKG}-server/settings.properties
done

systemctl restart ${PKG}-server
EOS
```

### Poll for the start verdict

`systemctl restart` returns the moment the JVM process is up, but the platform takes anywhere from ~30 seconds (small config, stock platform, no migration) to 5+ minutes (large multi-module config, first-time migration). Wait for the actual readiness signal in `stdout.log`:

```bash
ssh root@<host> 'bash -s' <<'EOF'
PKG=lsfusion6
LOG=/var/log/${PKG}-server/stdout.log

# Old log entries from prior boots remain in the file. Track the COUNT of
# success lines before this attempt — wait until it goes up. `grep | wc -l`
# is deliberate; see the gotcha callout next to the install-poll loop above
# for why `grep -c || echo 0` is broken.
BASE=$(grep "Server has successfully started" "$LOG" 2>/dev/null | wc -l)
for i in $(seq 1 180); do   # ~6 min budget
  CUR=$(grep "Server has successfully started" "$LOG" 2>/dev/null | wc -l)
  if [ "$CUR" -gt "$BASE" ]; then echo "STARTED"; break; fi
  systemctl is-active ${PKG}-server >/dev/null || { echo "SERVICE DIED"; break; }
  sleep 2
done
echo "--- last 5 stdout ---"; tail -n 5 "$LOG"
echo "--- last 20 stderr ---"; tail -n 20 /var/log/${PKG}-server/stderr.log
EOF
```

Three possible outcomes:

- **`STARTED`** → run the external check below.
- **`SERVICE DIED`** → read `stderr.log`; see [Troubleshooting](#troubleshooting).
- **Timeout** (loop ran out) → JVM is still alive but not done. Either it's a huge config still working (raise the loop count and wait more), or stuck in a retry loop (read `stdout.log`).

When sending the heredoc through PowerShell on Windows, **base64-encode it first** to dodge the PowerShell 5.1 BOM bug — see [references/ssh-from-windows.md](references/ssh-from-windows.md#bom-workaround).

### External verification

```bash
curl -sI http://<host>:8080/ | head -1                              # expect 200
curl -s http://<host>:8080/ | grep -o '<title>[^<]*</title>'        # title should be the app name, not the default "lsfusion"
```

If the title is your app name (not the default `lsfusion`), the configuration is live end-to-end.

**For deeper verification** — confirming that a specific class, property,
or module from your jar actually resolved on the running server, or counting
rows through the lsFusion layer (NOT through `psql`) — use the
**lsfusion-eval** skill. It covers the HTTP Action API (`/eval/action` on
port 7651, or via the web port over HTTPS), the **devmode-vs-prod auth
rule** (deployed = devmode OFF = `curl -u admin:` with empty password;
bare `curl` without `-u` returns 401), and the recipes for "is this name
in the schema?" / "how many rows?".

For inspecting what `.lsf` is **actually loaded** on the running server —
same skill, Part 2 — the platform's built-in **`/files/list` /
`/files/read` / `/files/search`** HTTP endpoints stream from the running
JVM's classpath, no SSH or jar tooling needed. Reach for that before
anything else when you need to know "is feature X really on the server?".

### Refresh PostgreSQL planner statistics after a first install or a big schema change — call `analyzeDBAction()`

lsFusion generates large, join-heavy SQL. Right after a fresh DB load — or a sync that created/changed many tables — PostgreSQL has **no planner statistics** for those tables, so the first queries and form opens can be dramatically slow until autovacuum eventually catches up. The platform ships a built-in maintenance action for exactly this: **`analyzeDBAction()`** (from the system `Service` module — also callable as `Service.analyzeDBAction()`), which runs PostgreSQL `ANALYZE` on the server's own connection. Call it once, immediately after you see `STARTED`, over the Action API (deployed = devmode OFF = `-u admin:` with empty password — see the **lsfusion-eval** skill):

```bash
curl -sS -u 'admin:' -X POST -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-urlencode "script=analyzeDBAction();" \
  https://<host>/eval/action
```

This is **not** the same as lsFusion's own `Recalculating stats and materializations at the first start` log line — that fills the platform's internal optimizer stat tables, which is separate from PostgreSQL's `ANALYZE`. Prefer the action over raw `psql` (no DB creds, no shell into PostgreSQL, works the same locally and remotely). Run it after the **first** deploy and after any deploy that adds/removes many classes/properties; for steady-state redeploys that only change resources (JS/CSS) or a handful of properties it's unnecessary.

### Lock the drop guards back to `true` once the deploy succeeded

The two `db.denyDrop*` flags exist to prevent silent data loss. Setting them to `false` was a deliberate one-time concession so the **first** restart could finish the schema migration. **As soon as the deploy succeeds**, flip them back to `true` (or just remove the lines) so the **next** unintended schema mismatch — e.g. a future deploy with a typo'd `topModule`, or someone running the wrong jar — fails loudly instead of silently dropping production tables.

```bash
ssh root@<host> 'bash -s' <<'CFG'
PKG=lsfusion6
SETTINGS=/etc/${PKG}-server/settings.properties
# Replace the false lines (idempotent — sed only acts on the false form).
sed -i 's/^db\.denyDropModules *= *false/db.denyDropModules = true/' "$SETTINGS"
sed -i 's/^db\.denyDropTables  *= *false/db.denyDropTables = true/'   "$SETTINGS"
grep -E '^db\.denyDrop(Modules|Tables)' "$SETTINGS"
CFG
```

Don't restart for this — `denyDrop*` is read on the **next** startup; the running server is unaffected. If the next deploy genuinely needs to drop something, you'll see the explicit `Dropping modules` / `Dropping tables` error and can decide consciously to flip the flag again (or list the specific names via `db.allowDropModules` / `db.allowDropTables`).

## 5. Pull the remote DB to run locally

Use case: debug a bug or develop against production-shaped data without touching the live server. The remote keeps serving as-is; you get a local clone of its state to poke at, throw away, re-pull whenever you want a fresh snapshot.

This straddles both skills: the **remote half** (dump + transfer) lives here; the **local half** (restore + run) is the lsfusion-dev skill driving `lsfdev.ps1`. Both have to be set up.

**Prereqs to check first**:
- Local lsFusion dev env already up (project sources in `src/main/lsfusion/`, platform binaries in `.lsfusion-dev/` — see lsfusion-dev `check` / `setup`).
- **Same platform major version locally and remotely**. Different majors → modulesHash mismatch on first start → schema migration runs against the prod snapshot, with all the risks of a real migration. Match versions first (`lsfdev.ps1 setup -Version <remote-version> -Force` locally, or upgrade the remote via [section 2](#2-upgrade-or-switch-the-platform-version)).
- Local PostgreSQL major ≥ remote major. Newer PG restores older dumps; the reverse usually doesn't.

### Steps

1. **Dump on remote** (custom format = compressed + parallel-restore-able):
   ```bash
   ssh root@<host> "sudo -u postgres pg_dump -Fc lsfusion -f /tmp/lsfusion.dump"
   scp root@<host>:/tmp/lsfusion.dump <project-root>\lsfusion.dump
   ssh root@<host> "rm /tmp/lsfusion.dump"   # don't leave dumps lying on the prod box
   ```

2. **Restore locally to a NEW DB name** — don't overwrite the dev DB the local skill auto-created (it's the one `db.name` defaults to, you want to be able to switch back):
   ```powershell
   $env:PGPASSWORD = "<local-postgres-pwd>"
   $pgbin = "C:\Program Files\PostgreSQL\<major>\bin"
   & "$pgbin\dropdb.exe"    --if-exists -U postgres lsfusion_from_remote
   & "$pgbin\createdb.exe"              -U postgres lsfusion_from_remote
   & "$pgbin\pg_restore.exe" -U postgres -d lsfusion_from_remote --no-owner --no-acl --role=postgres .\lsfusion.dump
   ```
   `--no-owner --role=postgres` quietly remaps roles that exist on the prod box but not locally; without it the restore prints harmless ownership warnings but otherwise works.

3. **Point the local project at the restored DB** — single line in `<project-root>\settings.properties`:
   ```properties
   db.name = lsfusion_from_remote
   ```
   Mirror the same value into `<project-root>\.lsfusion-dev\config.json` (`"dbName": "lsfusion_from_remote"`) so re-running `lsfdev.ps1 setup` doesn't revert it.

4. **Restart and verify**:
   ```
   powershell -ExecutionPolicy Bypass -File .claude/skills/lsfusion-dev/scripts/lsfdev.ps1 restart
   ```
   In the log, look for `Comparing modulesHash: old <X>, new <X>` — same hash on both sides means the local sources match the schema the prod DB was last written with. Different hashes → schema sync runs (usually fine if platform versions match; pay attention to "Dropping ..." lines that would mean local sources drifted from prod).

### Refreshing the snapshot later

Just repeat the cycle (`pg_dump` → `scp` → `dropdb`/`createdb`/`pg_restore`) — keep the same `lsfusion_from_remote` name, and the running server picks up new contents after `lsfdev.ps1 restart`. No config edits needed.

### Switching back to the clean dev DB

Comment out / remove the `db.name` line in `settings.properties` (and restore the original `dbName` in `config.json`), then `lsfdev.ps1 restart`. The locally-generated `lsfusion_<folder>_<hash>` DB is still there with whatever state it had before — production snapshot stays parked under its own name for next time.

## Troubleshooting

Quick lookup. For deeper analysis and recovery steps see [references/troubleshooting.md](references/troubleshooting.md).

### "no viable alternative at input '<keyword>'" / parse errors in `stderr.log`

The platform on the server can't parse `.lsf` syntax the project uses. Almost always: project targets a newer major version than the server. **[Upgrade the platform](#2-upgrade-or-switch-the-platform-version)** to the version the project's `pom.xml` parent declares (`lsfusion.platform.build:logics:<X.Y>(-SNAPSHOT)`).

### `RuntimeException: Dropping modules: <Name>` or `Dropping tables: <Name1>, ...`

Two separate but similar failures, both about DB metadata being out of sync with the running configuration:

- **`Dropping modules`** — the DB records modules (e.g. `ProcessUtils`) that aren't in the current jar/classpath. Allow via `db.denyDropModules = false`.
- **`Dropping tables`** — the DB has concrete tables (`Chat_chat`, `_auto_Schedule_Holidays`, …) that no class/property in the running config maps to. Allow via `db.denyDropTables = false`.

You will typically hit **both** in two situations: (a) first deploy after a platform major upgrade (modules removed between versions) and (b) first deploy of a small config onto a server that previously ran with just the bare platform — the bare run created tables for default modules like Chat / Geo / Icon / Schedule, and your `topModule` doesn't `REQUIRE` them. That's why step 4's settings block in this skill writes **both** flags at once.

If data must survive selectively, use the allow-list variants instead so unexpected drops still fail loudly:

- `db.allowDropModules = ModuleA, ModuleB`
- `db.allowDropTables  = TableA, TableB`

### Service is `active` but `:7652` doesn't listen

The application server binds RMI **at the end** of initialization. Until then `systemctl is-active` says `active` but the platform isn't ready. Keep polling `stdout.log` for `Server has successfully started in N ms`.

### `Failed to initialize tess4j. Add tess4j jar to classpath.`

Non-fatal. lsFusion's OCR action needs the tess4j library, which the auto-installer doesn't bundle. Ignore unless the project uses OCR — then drop a `tess4j-*.jar` into `/var/lib/lsfusion/` alongside `app.jar`.

### "bash: line 1: syntax error" / "command not found: ﻿echo" when running scripts via PowerShell + ssh

PowerShell 5.1 prepends a UTF-8 BOM to here-strings sent through native-process pipes, even with `$OutputEncoding` set to UTF-8 without BOM. The remote bash sees `<BOM>echo` as the first token and chokes. **Always base64-encode** multi-line bash sent through ssh from PowerShell — see [references/ssh-from-windows.md](references/ssh-from-windows.md#bom-workaround).

### Public-key auth fails right after first install

CRLF in `authorized_keys`. PowerShell pipes mangle line endings on the way out. Re-do the install via `scp` + remote-side `printf '%s\n'`, never `Get-Content key.pub | ssh "cat >> authorized_keys"`. See [references/ssh-from-windows.md](references/ssh-from-windows.md).

## Notes and pitfalls

- **Init time scales with config size.** Stock platform on a fresh DB: ~35 s. Medium multi-module config with first-time schema sync: 5–10 min. Don't shorten the polling loop without understanding the config.

- **`/etc/lsfusion6-server/settings.properties` overrides the jar's `lsfusion.properties`, not the other way around.** Per the resolution chain (see [the section above](#where-install-specific-parameters-live-and-why-etclsfusion6-serversettingsproperties-is-confsettingsproperties)), install-side `conf/settings.properties` is layer 3 and the project's `lsfusion.properties` is layer 2 — later layers win. So if the jar sets `db.denyDropModules = false` and you keep `db.denyDropModules = true` in `/etc/lsfusion6-server/settings.properties`, the install-side value wins and drops are blocked. Decide deliberately which layer owns each key; duplicating is fine when intentional, surprising when accidental.

- **Ports `:7651` and `:7652` listen on `*` by default** — exposed to the internet on a public host. Only `:8080` should be public-facing. Before exposing the host, firewall the others (`ufw allow 8080; ufw deny 7651,7652`) or rebind to `127.0.0.1` in the app-server's `lsfusion.conf` under `/etc/<pkg>-server/`.

- **Default DB password is `11111` after auto-install.** Change it (`ALTER USER postgres WITH PASSWORD '...'`) and update `db.password` in `settings.properties` before exposing the host.

- **Data lives in PostgreSQL, not in the jar.** Removing `app.jar` and restarting reverts the UI to the stock platform, but the database still has the project's tables and rows. Drop or migrate the DB explicitly for a clean slate.

- **Rollback is "remove jar, restart".** If a deploy fails mid-init, the server stays in a stopped state — `inactive`. Removing your jar from `/var/lib/lsfusion/` and restarting the app-server unit brings the bare platform back online so the rest of the host is at least reachable while you debug locally.

- **For a known-bad jar, restore the previous one explicitly.** lsFusion has no built-in version slot — what's in `/var/lib/lsfusion/` is what runs. Keep one prior jar around (`app.jar.prev`) when shipping updates so you can swap back in seconds.
