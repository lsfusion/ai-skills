# SSH from Windows for lsFusion deploy

Bootstrap from "I have a password and IP" to "all subsequent ssh/scp calls are non-interactive", and dodge two known PowerShell-5.1 footguns along the way.

## The two PowerShell-5.1 traps you'll hit

These are **not** lsFusion problems — they bite any Windows-→-Linux ssh workflow — but they ruin a deploy session if not handled.

### Trap 1: UTF-8 BOM on native-process pipes

When you pipe a string to a native command in PowerShell 5.1:

```powershell
$script = @'
echo hello
'@
$script | ssh root@<host> 'bash -s'
```

PowerShell adds a UTF-8 BOM (`﻿`, the bytes `EF BB BF`) at the start of the stream **even when you set `$OutputEncoding` to UTF-8 without BOM**. The remote bash sees `<BOM>echo` as the first token and errors with something like:

```
bash: line 1: ﻿echo: command not found
```

This is a documented PowerShell 5.1 bug. PowerShell 7+ doesn't have it.

**Workaround:** base64-encode locally, decode remotely.

<a name="bom-workaround"></a>

```powershell
$script = @'
echo "running on $(hostname)"
ls -la /var/lib/lsfusion/
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
ssh root@<host> "echo $b64 | base64 -d | bash"
```

The base64 string has no BOM-able bytes — it's plain ASCII — so the pipe is safe. The remote bash decodes the exact original bytes before executing. This is the reliable way to send multi-line bash from PowerShell to ssh.

### Trap 2: CRLF in piped text

```powershell
Get-Content key.pub | ssh root@<host> 'cat >> ~/.ssh/authorized_keys'
```

Looks fine. Isn't. PowerShell pipes convert line endings to CRLF on the way out, so `authorized_keys` ends up with `<key>^M\n`. OpenSSH on the server compares against `<key>\n` and the keys don't match — authentication silently fails.

**Symptoms:**

```bash
ssh root@<host> 'cat -A ~/.ssh/authorized_keys'
# Bad line: ssh-ed25519 ABC... user@host^M$
# Good line: ssh-ed25519 ABC... user@host$
```

**Workaround:** use `scp` to ship binary content, and reconstruct text on the remote side using `printf '%s\n'`:

```powershell
$pubkey = (Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub -Raw).TrimEnd("`r","`n")
ssh root@<host> "printf '%s\n' '$pubkey' >> ~/.ssh/authorized_keys"
```

Or even cleaner — scp the file directly, then concatenate on the server:

```powershell
scp $env:USERPROFILE\.ssh\id_ed25519.pub root@<host>:/tmp/newkey.pub
ssh root@<host> 'cat /tmp/newkey.pub >> ~/.ssh/authorized_keys && rm /tmp/newkey.pub'
```

`scp` is binary — no line-ending mangling. After this, verify with `cat -A` as shown above; lines should end in `$` not `^M$`.

<a name="trap-3"></a>

### Trap 3: non-ASCII (Cyrillic / CJK / accents) in a native command's arguments → `?`

Git Bash (MSYS2) is UTF-8 internally, but when it launches a **native Windows executable** — and the bundled `curl` is one (`/mingw64/bin/curl`, a `w64-mingw32` build; so is System32 `curl.exe`) — it re-encodes the command-line arguments to the Windows **ANSI codepage** (e.g. CP1252). Any character that codepage can't represent (all Cyrillic, CJK, many accents) becomes a literal `?` (0x3F) **before the program even runs**. This bites hardest when seeding data through the Action API:

```bash
# BAD: the literal 'Проверка' is mangled to '????????' at the argv boundary;
# curl percent-encodes the '?', the server stores '?'. Nothing is wrong server-side.
curl -G --data-urlencode "script=NEWSESSION{ NEW u=Unit{ name(u)<-'Проверка'; } APPLY; }" "$URL"
```

It really is the argv boundary, not the shell or the server: MSYS-internal tools keep the bytes (`printf '%s' 'Проверка' | od -An -tx1` → `d0 9f d1 80 …`, correct UTF-8), and the *same* word sent from a file or from PowerShell stores correctly on the *same* server.

**Workarounds (either one):**

- Put the payload in a **file** and let curl read it with `@` — `@file` streams bytes directly, never through argv:

  ```bash
  # printf is MSYS-internal, so it keeps UTF-8 when writing the file
  printf '%s' "NEWSESSION{ NEW u=Unit{ name(u)<-'Проверка'; } APPLY; }" > /tmp/s.lsf
  curl -G --data-urlencode "script@/tmp/s.lsf" "$URL"
  ```

- Or send from **PowerShell**, which stays in .NET/UTF-16 and never crosses an ANSI argv boundary:

  ```powershell
  $s   = Get-Content -Raw -Encoding UTF8 .\script.lsf
  $enc = [uri]::EscapeDataString($s)
  $hdr = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('admin:')) }
  Invoke-WebRequest -Uri "$URL`?script=$enc" -Method Post -Headers $hdr -UseBasicParsing
  ```

Send the script in the **query string** (Tomcat decodes it as UTF-8), not the POST **body** (the servlet form-decodes the body as ISO-8859-1 → corruption). Large scripts can exceed the connector's `maxHttpHeaderSize` (8 KB default) → raise it on the SSL connector if you hit `Request header is too large`.

## First-time key install via SSH_ASKPASS

You have `<host>`, `<user>`, password. Goal: get an ed25519 key onto the server's `authorized_keys` so all subsequent ssh/scp/rsync work non-interactively from tool calls.

The whole point of using `SSH_ASKPASS` (rather than just typing the password) is that this skill runs ssh from within tool calls — the tool runner doesn't attach a terminal, so the password prompt has nowhere to read from. `SSH_ASKPASS` lets ssh fetch the password from a helper program instead of from a terminal.

### Step 0: account-state preflight (do this BEFORE anything else)

The single most expensive failure mode in this flow is **the account is in a state where no askpass setup can help**. The password the user handed you is correct, the script is correct, the keyfile is correct — and you'll still see `Permission denied` for a different reason than you think. Cheap one-shot probe that surfaces all of them:

```bash
echo y | ssh -o StrictHostKeyChecking=accept-new <user>@<host> 'true' 2>&1 | head -8
```

Reading the output:

- **`Your password has expired. Password change required but no TTY available.`** — the server's PAM forces a password change at next login. SSH can answer the *original* password prompt, but the follow-up "new password / confirm" flow needs an interactive tty that `SSH_ASKPASS` can't provide. **Ask the user to log in interactively once** (from a normal terminal), set a new password, and tell you what it is — *then* continue with the askpass setup using the new password.
- **`Account locked` / `account expired`** (PAM messages) — same shape: no script-side fix. The user has to unlock / extend the account on the server.
- **`Too many authentication failures`** — local `ssh-agent` is offering N keys ahead of password, server bails before getting there. Re-probe with `-o IdentitiesOnly=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no`. If THAT works, you're fine to proceed; the noise just hides the real auth method.
- **`Permission denied, please try again.`** with a password prompt right after — auth itself is working; ssh is asking for the password (good). Proceed to the actual key-install step below.
- **`Connection refused` / timeout** — sshd isn't listening, firewall, wrong host. Not an account problem.

If step 0 reports an account-state error, **stop and surface it to the user**. Going through the rest of this section first is dead time — you'll spend 5 minutes wiring up askpass only to discover the password was never the bottleneck.

### Step 1: generate the key

```powershell
if (-not (Test-Path "$env:USERPROFILE\.ssh")) {
    New-Item -ItemType Directory -Path "$env:USERPROFILE\.ssh" -Force | Out-Null
}
# -N '""' is an empty passphrase (escape gymnastics work around how PowerShell
# tokenizes "" in argv to ssh-keygen). The key has no passphrase, so it can be
# used non-interactively from tools.
ssh-keygen -t ed25519 -N '""' -f "$env:USERPROFILE\.ssh\id_ed25519" -C "<comment>"
```

**Empty passphrase** is deliberate. A passphrase would force an `ssh-agent` interaction for every ssh call, which doesn't work cleanly inside tool-runner shells. The trade-off: anyone with read access to the .ssh dir on this Windows box gets the key — protect the box, not the key. For elevated security needs, manage keys outside this skill.

### Step 2: install the public key on the server, one time, using a temp askpass script

**Critical gotcha:** the obvious approach `@echo off\necho <password>` in a `.cmd` file **silently corrupts** any password that contains cmd-special characters — `^` (escape), `%` (variable expansion), `&` `<` `>` `|` (redirects/pipes), and sometimes `!` (delayed expansion). The result: cmd "echoes" a mangled string, SSH gets the wrong password, and you see `Permission denied` even though the user gave you the right one.

To avoid that entirely: **write the password to a separate text file as raw bytes**, and have the askpass `.cmd` just `type` it. `type` dumps the file content without parsing, so any character is safe.

```powershell
$pw = '<the password>'   # one-time use; nothing persisted

# Pick names; both files live in %TEMP% (per-user ACL on Windows).
$pwfile  = Join-Path $env:TEMP "ssh-pw-$([Guid]::NewGuid().ToString('N')).txt"
$askpass = Join-Path $env:TEMP "ssh-askpass-$([Guid]::NewGuid().ToString('N')).cmd"

# Write the password as raw UTF-8 bytes WITHOUT a BOM and WITHOUT a trailing
# newline. Using [System.IO.File]::WriteAllText avoids PowerShell's default
# encoding quirks (Set-Content -Encoding ASCII appends a newline; Out-File
# may add a BOM depending on the PS version).
[System.IO.File]::WriteAllText($pwfile, $pw, [System.Text.UTF8Encoding]::new($false))

# The askpass script is one line. The backticks escape the inner quotes so the
# generated .cmd contains literal: @type "C:\...\ssh-pw-xxx.txt"
Set-Content -Path $askpass -Value "@type `"$pwfile`"" -Encoding ASCII

try {
    $env:SSH_ASKPASS         = $askpass
    $env:SSH_ASKPASS_REQUIRE = 'force'   # use askpass even with a terminal attached
    $env:DISPLAY             = 'x'       # OpenSSH on Windows still checks this

    # Strip trailing CR/LF off the public key so authorized_keys ends up with
    # a clean LF terminator on the remote side (see Trap 2 above).
    $pubkey = (Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" -Raw).TrimEnd("`r","`n")

    ssh -o StrictHostKeyChecking=accept-new root@<host> @"
mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\n' '$pubkey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo INSTALLED
"@
} finally {
    Remove-Item $pwfile, $askpass -Force -ErrorAction SilentlyContinue
    Remove-Item env:SSH_ASKPASS         -ErrorAction SilentlyContinue
    Remove-Item env:SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
    Remove-Item env:DISPLAY             -ErrorAction SilentlyContinue
}
```

Notes:

- **Both files hold the password in cleartext for the duration of the ssh call.** `%TEMP%` is per-user ACL'd on Windows, and the `finally` block removes them even on error. Don't run this on a multi-user workstation without thinking.
- **If you've already changed an existing host's key**, run `ssh-keygen -R <host>` first — otherwise OpenSSH refuses to connect with a `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` error.
- `StrictHostKeyChecking=accept-new` auto-accepts the host fingerprint on first connect. Acceptable for a fresh install where you'd accept manually anyway; review if you connect to many unfamiliar hosts.
- The `printf '%s\n' '$pubkey'` form on the remote side guarantees LF-only line endings — see Trap 2 above.
- After this prints `INSTALLED`, **the password is no longer needed**. Tell the user to rotate the password and ideally disable password auth in sshd entirely — the cleartext was in the conversation, in temp memory, and (briefly) on disk.

### Bash variant (Git Bash, Cygwin, WSL — anything that invokes ssh.exe from a POSIX shell)

PowerShell isn't always the right harness — many tool runners default to Bash (e.g. Claude Code's Bash tool on Windows runs Git Bash). The same `SSH_ASKPASS_REQUIRE=force` trick works there with simpler boilerplate, but you need **all three** of these together or it falls back to interactive prompt and hangs:

```bash
# 1. Askpass helper: a script that just echoes the password.
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat > ~/.ssh/askpass.sh <<'EOS'
#!/usr/bin/env bash
echo 'PUT-THE-PASSWORD-HERE'
EOS
chmod 700 ~/.ssh/askpass.sh

# 2. One-time public key install.  Three details that all matter:
#    a) `< /dev/null`               — detach ssh's stdin from the terminal so
#                                     it falls back to SSH_ASKPASS instead of
#                                     reading the password from the tty.
#    b) PreferredAuthentications=password + PubkeyAuthentication=no
#                                   — without this, ssh tries (and fails) every
#                                     key in the agent FIRST, and depending on
#                                     server config the password method may
#                                     never be tried.
#    c) SSH_ASKPASS_REQUIRE=force   — tells modern OpenSSH (8.4+) to use askpass
#                                     even when DISPLAY is unset, so you don't
#                                     need the dummy DISPLAY=x export.
PUBKEY=$(cat ~/.ssh/id_ed25519.pub)
SSH_ASKPASS=~/.ssh/askpass.sh SSH_ASKPASS_REQUIRE=force \
    ssh -o StrictHostKeyChecking=accept-new \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        root@<host> \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
         grep -qF '$PUBKEY' ~/.ssh/authorized_keys 2>/dev/null || \
         echo '$PUBKEY' >> ~/.ssh/authorized_keys; \
         chmod 600 ~/.ssh/authorized_keys && echo INSTALLED" < /dev/null

# 3. After this prints INSTALLED, blow away the askpass script. Key auth
#    works from now on, so the password is dead weight.
shred -u ~/.ssh/askpass.sh 2>/dev/null || rm -f ~/.ssh/askpass.sh
```

Single-quote the password inside `askpass.sh` so `$` / backtick characters survive verbatim. The remote command is also single-quoted across multiple lines — fine in bash, no shell-special expansion of the password happens server-side either.

### Step 3: verify key auth works

```powershell
ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$env:USERPROFILE\.ssh\id_ed25519" root@<host> "hostname; whoami; uname -srm"
```

`BatchMode=yes` makes ssh fail immediately rather than fall back to password prompt. `IdentitiesOnly=yes` makes it use only the key you passed (not any other keys in `~/.ssh/` or `ssh-agent`).

If this returns the remote hostname/user, you're done — all subsequent `ssh root@<host> ...` and `scp ... root@<host>:...` calls will use the key automatically (ssh tries keys in `~/.ssh/id_ed25519`, `~/.ssh/id_rsa`, etc., by default).

## Tools and patterns you'll forbid yourself

This skill **does not use** `plink`, `putty`, `pscp`, `psftp`, or any other PuTTY-suite binary. They're competent tools but they're an extra install, they encode authentication choices in ways that diverge from OpenSSH, and they don't integrate with `ssh-agent` cleanly. The Windows built-in OpenSSH client is sufficient and consistent with how everyone else on the team does SSH.

If a workflow seems to need plink (e.g. easier password handling), step back — usually that means you should be setting up key auth instead.

## Reusable PowerShell helpers

Drop these in the session and they're available for the rest of the deploy:

```powershell
function Invoke-RemoteBash {
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host,
        [Parameter(Mandatory)][string]$Script
    )
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    ssh "$User@$Host" "echo $b64 | base64 -d | bash"
}

function Copy-ToRemote {
    param(
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Host,
        [Parameter(Mandatory)][string]$RemotePath
    )
    scp $LocalPath "${User}@${Host}:${RemotePath}"
}
```

Usage:

```powershell
Invoke-RemoteBash -User root -Host <host> -Script @'
systemctl is-active lsfusion6-server lsfusion6-client postgresql
ss -tlnp | awk '/:(5432|7651|7652|8080)\>/'
'@

Copy-ToRemote -LocalPath C:\Work\app.jar -User root -Host <host> -RemotePath /var/lib/lsfusion/app.jar
```

These are convenience wrappers — nothing stops you from writing the raw `ssh` / `scp` calls inline. The wrappers exist to make the BOM-workaround invisible after one definition.

## When you can drop these workarounds

If the host is running **PowerShell 7+** (`pwsh.exe`), Trap 1 (BOM) is gone — pipe heredocs to ssh directly. Trap 2 (CRLF) still happens because it's a pipeline default, not a 5.1 bug; the `printf '%s\n'` and `scp`-then-cat patterns remain the right answer.

On Linux/macOS, neither trap exists — write the obvious code.
