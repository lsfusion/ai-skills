---
name: lsfusion-eval
description: >-
  Run lsFusion code against a running server (local dev install or deployed
  production) and inspect what code is actually loaded on that server. Triggers
  whenever the user wants to: evaluate an lsFusion expression or run a script
  via HTTP (/exec, /eval, /eval/action endpoints), call a project action by
  name remotely, check that a class / property / form / module exists in the
  running config, count or sample data through the lsFusion layer instead of
  hitting PostgreSQL directly, or read / grep the `.lsf` sources that are
  actually deployed on a remote host (via the `/files/*` API on the running
  web port). Use this skill any time the task is "ask the server" rather
  than "edit code locally" — it's the canonical way to verify
  remote-server state before changing things, debug what's actually running,
  and answer "is the schema in sync with the source I have?". Triggers on
  phrases like "call action via HTTP", "/eval", "eval/action", "run lsfusion
  script remotely", "check what's on the server", "what logic is running on
  the server", "look at .lsf on the server", "count via API", "API check",
  "verify class/property on the server".
---

# lsFusion HTTP Action API & remote-install introspection

> **Companion MCP server — `lsfusion-ai`** ([`ai.lsfusion.org`](https://ai.lsfusion.org/mcp),
> registered by the `lsfusion-ai-skills` plugin). Call
> **`mcp__lsfusion-ai__lsfusion_get_guidance`** **first** in any lsFusion task
> (if its rules aren't already in context) and follow every rule it returns —
> the element order, the coding rules, and the `lsfusion_report_feedback`
> consent policy all live there. Confirm syntax with
> **`mcp__lsfusion-ai__lsfusion_retrieve_docs`** instead of guessing. If these
> tools are missing, the server isn't installed — see the
> [ai-skills README](https://github.com/lsfusion/ai-skills#readme) to add it.

This skill covers two complementary ways to inspect a running lsFusion
install — local dev or production — **without** touching PostgreSQL directly:

1. **Run code via HTTP Action API** — ask the server "evaluate this lsFusion
   expression, give me the answer (or just tell me it compiled)". Uses the
   lsFusion **name resolution and security** layers, so a successful response
   proves the names you reference are really in the running schema.
2. **Read / grep the deployed source via the File API** — the `.lsf` files
   actually loaded by the server are served back over the `/files/list` /
   `/files/read` / `/files/search` endpoints on the web port. The answer
   comes from what the JVM has on its classpath right now, not from
   anything on disk.

Together these answer the question **"what is *actually* running on this
server right now?"** — which you must answer truthfully before you change
anything. If your local sources differ from what's deployed, every assumption
you make from reading local code is wrong.

> **The mistake that brings agents here:** writing a `TestData.lsf` /
> `SeedData.lsf` / `Migration001.lsf` / `FixCustomer.lsf` module to call
> *once*, adding it to top-`REQUIRE`, and restarting the server — when
> the entire job was a short script the eval endpoint runs in sub-second
> without touching the codebase. Reach for this skill the moment a task
> is **runtime data manipulation**, not schema. The lsfusion-dev skill
> cross-references this distinction; honour it.

## When to use this vs. other approaches

| You want to … | Use |
|---|---|
| Seed test data on a dev install | **This skill** — POST a mutation script to `/eval/action` |
| One-shot fix on production data (with user approval) | **This skill** — same path; **never** silently |
| Clean up all rows of a class | **This skill** — POST a delete-and-apply script to `/eval/action` |
| Evaluate an lsFusion expression / call an action on a running server | **This skill** — HTTP Action API |
| Confirm a class / property / form exists in the running schema | **This skill** — `RETURN OVERRIDE (GROUP SUM 1 IF Class c IS Class), 0;` over `/eval/action` (7.0+; on 6.x: `EXPORT FROM cnt = (OVERRIDE (GROUP SUM 1 IF Class c IS Class), 0);`): 200 + count = exists, 500 "not found" = it doesn't |
| Count / sample data | **This skill** — `RETURN <expr>;` (7.0+) or `EXPORT FROM ...` (any version) |
| See the `.lsf` source actually loaded on a remote host | **This skill** — `/files/list`, `/files/read`, `/files/search` on the web port |
| Inspect physical DB tables / columns / indexes | Direct `psql` — but this is a last resort; **first ask the user**, per the rule in the **lsfusion-dev** skill. lsFusion mangles names; raw SQL almost always misleads. |
| Edit `.lsf` source | The lsfusion-dev skill + IDE MCP tools |
| Deploy a new jar | The lsfusion-deploy skill |

The **fixed verification order** (rationale in the lsfusion-dev skill,
step 5) is the same locally and remotely — never UI first: **server log**
(`tail /var/log/lsfusion6-server/stdout.log` over SSH, or `lsfdev.ps1 log`)
→ **API** (this skill's `/eval/action` and `/files/*`) → **UI** (Playwright:
Part 3 for remote, lsfusion-dev `verify` for local). Direct `psql` is only
for what neither log nor API can answer (DBA recovery, physical-layout
debugging) — and only after asking the user.

## Part 1: HTTP Action API

### Endpoints

The lsFusion application server exposes the Action API on port **`7651`**
(direct). On a deployed host fronted by the web client (Tomcat), the same
API is also reachable through the web port — `8080` (HTTP) or via HTTPS on
the host's external port (typically `443`). Pick whichever is reachable
from where you're running curl:

| Path | What it does | Key parameter |
|---|---|---|
| `/exec?action=<name>` | Run a **named** action declared in the project | `action=` |
| `/eval?script=<code>` | Run an lsFusion script that **defines** an action `run` and executes it | `script=` |
| `/eval/action?script=<code>` | Run an **action-body** snippet directly (no surrounding `run() { ... }` wrapper needed) | `script=` |

Most introspection ("does this class exist", "count rows", "send a value
back") fits `/eval/action` — you write one line of action code that sends
the answer back in the response body, the server runs it, you read the
value (the status code alone only proves the script compiled). **The
value-returning statement depends on the platform major version**: `RETURN
<expr>;` exists on **7.0+ only** — on 6.x (including the current `stable` =
6.2 that the lsfusion-dev skill installs by default) it is a **parse
error** (`extraneous input ... expecting ';'`); the 6.x equivalent is
`EXPORT FROM res = <expr>;`, which works on every version. Check the
target's version first (`Current version:` in the server log) and pick the
matching form below.

**Access control — `enableAPI` is the master gate; `@@api`/`@@noauth` are
per-action overrides.** The `enableAPI` working parameter (default **`0`**
since platform v7; **`2`** under devmode) decides who may reach the Action
API at all:

- `2` — anonymous allowed (dev / sandbox only; never production)
- `1` — **any authenticated user may call any action**
- `0` (the v7 default) — allowed only for: `@@noauth` actions, authenticated
  requests to `@@api` actions, and authenticated users who have access to the
  `System.interpreter` navigator form

A **named project action** opts into the API with an annotation on its
declaration:

- `@@api` — callable when authenticated, even at `enableAPI=0`
- `@@noauth` — callable without authentication, bypassing `enableAPI` entirely

**`/eval` and `/eval/action` are built-in endpoints, not `@@api` actions** —
`@@api` marks a *named* action and does not apply to these endpoints, so it
never opens them. Because they execute **arbitrary** lsFusion code, at
`enableAPI=0` they require the caller to have access to the
`System.interpreter` form (the same gate as running code in the UI), and at
`enableAPI=1` **every authenticated user** can run arbitrary code through
them — which is exactly why production should keep `enableAPI=0` and expose
specific `@@api` actions instead (see "Production security" below). The
endpoints also need the platform's EVAL support loaded; the skill family's
default top-module `REQUIRE` list includes `Eval`, and a `/eval/action` 404
usually means the running project doesn't `REQUIRE Eval`.

### Authentication (this is where everyone trips)

Two methods, per the platform docs:

- **Basic Auth** — `Authorization: Basic <base64(user:pass)>` (curl: `-u user:pass`)
- **Bearer token** — `Authorization: Bearer <token>`, where the token comes from `Authentication.getAuthToken[]`

The default account on a fresh install is **`admin`** with **empty password**.
But — and this is the trap — devmode changes the rules in a way that's easy
to get wrong:

| Server state | What to send | Why |
|---|---|---|
| **Devmode ON** (local dev install, `-Dlsfusion.server.devmode=true`) | `curl` **without `-u`** — no `Authorization` header at all | Server auto-authenticates as `admin` only when it sees **no** header. Works on every platform version. |
| **Devmode OFF** (production, deployed via lsfusion-deploy) | `curl -u admin:` (empty password) | API requires auth; `admin:` sends Basic with empty password, server validates and accepts. `admin` reaches `/eval/action` even at the v7 default `enableAPI=0` because it has `System.interpreter` access — a **non-admin** user would be refused there (see access control above). |
| **Admin password rotated** | `curl -u admin:<real password>` | Self-explanatory |

**The trap:** "no header" ≠ "header with empty password". `curl` without
`-u` sends nothing; `curl -u admin:` sends Basic Auth with empty password.
Devmode-auto-auth fires **only** when the server sees no header; with a
header present the server runs a real credential check on what you sent.
`-u admin:<wrong-guess>` therefore returns `HTTP 401` even in devmode —
don't try `-u admin:fusion` or `-u admin:admin` "just in case". An
**empty-password** Basic (`-u admin:`) is accepted by current builds (200
verified on both 6.2 and 7.0-SNAPSHOT, 2026-06; the empty password matches
the default admin account), though at least one snapshot-era build has been
observed rejecting it with 401. The no-header form has no such history —
make it your default for devmode, and fall back to a real password only if
the user supplies one.

### Production security: never raise `enableAPI` to reach `/eval/action`

`/eval/action` runs **arbitrary** lsFusion code. The platform's hardening
default is `enableAPI=0` (since v7), under which the endpoint is reachable
only by `System.interpreter`-privileged users (e.g. `admin`) — that is the
state you want in production. If a non-admin's `/eval/action` call is being
refused, the fix is **not** to set `enableAPI=1`: that flips on arbitrary
code execution over HTTP for *every authenticated user*, bypassing the
`System.interpreter` form gate that limits the interpreter in the UI. Instead
wrap the specific operation in a named action annotated `@@api` (callable at
`enableAPI=0`) and have it validate `currentUser()` itself. Use `enableAPI=2`
(anonymous) only on a throwaway dev/sandbox box, never production. If a role
genuinely needs broad API access, grant it per-role via
`Administration → System → Settings → Parameters`, not globally. (This
mirrors the platform docs — *Working parameters* `enableAPI`,
*Access from an external system*, and *MCP server setup*.)

### Sending an lsFusion script via curl

Use **POST** with `Content-Type: application/x-www-form-urlencoded; charset=UTF-8`
and pass the script through `--data-urlencode script=...`. Keep the charset
suffix as cheap hygiene — but know where non-ASCII *actually* gets
corrupted, because it is **not the HTTP transport**: with the server JVM on
a UTF-8 default encoding (lsfusion-dev always passes
`-Dfile.encoding=UTF-8`; the lsfusion-deploy skill's locale preflight
ensures it on servers), Cyrillic survives POST bodies and query strings
alike — verified **byte-for-byte on both 6.2 and 7.0-SNAPSHOT** (2026-06),
on the app-server port and the web port. The corruptions that do happen are
**client-side, on Windows**:

- **Outbound — argv.** Non-ASCII in a native curl's **inline** argument is
  re-encoded to the ANSI code page before curl even runs, and the server
  faithfully stores `?`. Pass non-ASCII scripts from a **file**
  (`--data-urlencode "script@C:/path/file.lsf"`) or send from PowerShell —
  never inline.
- **Inbound — console pipes.** Piping a UTF-8 response through console
  tools re-decodes it in the ANSI code page and *fabricates* mojibake that
  is not in the data. Verify **bytes**, not console text: `curl -o
  resp.json`, then read the file as UTF-8. (Exactly this artifact has
  produced false "the server mangles Cyrillic" reports before.)

If a server *was* installed with a non-UTF-8 locale (legacy hosts), fix the
JVM encoding per the lsfusion-deploy skill's locale section instead of
fighting transports.

```bash
# Local dev (devmode), inline script — response body is "hello"
curl -sS -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-urlencode "script=RETURN 'hello';" \
  http://localhost:7651/eval/action

# Production (devmode off), inline script, on HTTPS via web port
curl -sS -u 'admin:' -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-urlencode "script=RETURN 'hello';" \
  https://<host>/eval/action

# Long script from a file (avoid quoting hell).
# IMPORTANT: on Windows the bundled curl.exe is a Windows-native binary —
# it does NOT understand Git Bash's /tmp prefix. `script@/tmp/probe.lsf` will
# either silently produce an empty `script=` param (server then returns
# HTTP 500 "Eval script was not found"), or pick up an unrelated file at
# C:\tmp\probe.lsf. Always pass a path that the actual curl process can
# resolve — either an absolute Windows path with forward slashes, or
# run curl from the same Bash environment that owns the temp file.
curl -sS -u 'admin:' -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-urlencode "script@C:/Users/me/probe.lsf" \
  https://<host>/eval/action
```

Always pass `-w '\nHTTP %{http_code}\n'` in introspection calls — the response
body is often empty (see "Reading the response" below), so the status code is
your real signal.

**The `script=...` body is lsFusion source.** Everything that this skill
documents is the HTTP wrapper — endpoints, auth, content-type, response
codes, file-API parameters. The contents of `script=` is real lsFusion
code, with all the language's syntax rules and semantic constraints. Run
`lsfusion_get_guidance` (once per session) and `lsfusion_retrieve_docs`
**before** writing or modifying any non-trivial script. Do not guess
syntax from English intuition — string literals use single quotes (not
double), aggregation has restrictions on how operators can be combined,
etc., and every such fact is in the language reference. This skill
deliberately does not duplicate those rules; reaching for `retrieve_docs`
is part of the workflow.

### Reading the response

| Status | Meaning |
|---|---|
| `HTTP 200`, empty body | Script compiled, name-resolved against the running schema, and ran — **nothing more**. A `MESSAGE` produces exactly this (its text is swallowed — see the gotchas), and so does a mutation whose `APPLY` was silently **canceled by a constraint**. An empty 200 is never data-level proof; write scripts that `RETURN` something. |
| `HTTP 200`, body present | Script ended in `RETURN <expr>;` or declared an `EXPORT FROM ...` — the value/export is the body. See "Getting values back" below. |
| `HTTP 401` | Auth issue — see the trap table above. Usually means you sent the wrong `-u` form, NOT that the password is wrong. |
| `HTTP 500`, body with `[error]:` | The script failed one of the compile phases (see "Syntax-checking" below for the exact order). Three error shapes, in the order the server checks them: a **parse error** (`no viable alternative`, `extraneous input`, `missing X`, `mismatched input`) = bad syntax; **`... is not found`** = an unknown class/property/action (the deployed config differs from yours, or a missing REQUIRE); **`X cannot be used in EVAL module`** = a forbidden construct whose syntax+names are actually fine (see below). Genuine type mismatches (`... types don't match`, `should have integral class`) surface only when the value is realized — note INTEGER+STRING is **not** one (it coerces). Only the first error is reported. |
| `HTTP 404` | Endpoint not in this build (no `Eval` module REQUIREd, or wrong path). |

The canonical "is this name in the running schema?" check against
`/eval/action` is
`EXPORT FROM cnt = (OVERRIDE (GROUP SUM 1 IF MyClass o IS MyClass), 0);`
(or the `RETURN` one-liner on 7.0+) — a 500 "not found" answers *no*, a 200
with the count in the body answers *yes* (and tells you how many). Don't use
`MESSAGE` for this: it yields the same empty 200 as half a dozen failure
modes.

### Syntax-checking `.lsf` without a restart

A `.lsf` edit normally needs a server restart (30–60 s) to find out whether
it even parses. eval is a **sub-second first-pass linter** for the whole
`.lsf` surface — not just expressions — because the eval string is compiled
as a throwaway module that depends on every loaded module. The server runs
the compile phases **in a fixed order**, and the error you get back tells you
exactly which phase failed (verified live on 7.0-SNAPSHOT):

| Phase (in order) | Catches | Error shape in the body |
|---|---|---|
| 1. Parse (grammar) | malformed syntax in **anything**, including forbidden constructs | `no viable alternative` / `extraneous input` / `missing X` / `mismatched input` / `required (...)+ loop` |
| 2. Name resolution | unknown class / property / action, missing `REQUIRE` — incl. names used inside `FORM` and event conditions | `property or action '<name>' is not found` |
| 3. EVAL restriction | a construct eval can't load (see below) — reached **only** once syntax + names are clean | `<X> statement / option cannot be used in EVAL module` |
| 4. Type realization | genuine type mismatches — but only when the value is actually used (lazy on unused declarations; INTEGER+STRING coerces, not an error) | `... types don't match` / `should have integral class` |

Because phase 1 runs first and phase 2 second, you can throw **any**
declaration at eval and read the result by three outcomes:

- **parse error** → a real syntax bug in your code. Fix it.
- **`... is not found`** → a referenced element doesn't exist (typo, or a
  `REQUIRE` you haven't added).
- **`... cannot be used in EVAL module`** → treat as **PASS**: the
  construct's syntax and names are clean; eval just won't load it. It will
  load on the next real restart.

So `CLASS`, persistent `DATA` (`NONULL` / `MATERIALIZED` / `INDEXED`),
`WHEN`, `CONSTRAINT`, aggregations etc. are all syntax+name checkable — a
typo in them yields a parse error, a clean one yields "cannot be used".
Plain calc properties, session `DATA`, and whole `FORM` declarations are
loadable, so they get checked all the way through (a `FORM` even
name-resolves the properties in its `PROPERTIES` block).

```bash
# wrap the edit as eval statements (statements mode needs a run action).
# 200 => parses + names resolve; 500 => read the phase from the error shape.
curl -sS -X POST -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-urlencode "script=
profit (Order o) = revenue(o) - cost(o);   // your new property
run() { }
" http://localhost:7651/eval
# devmode: no -u.  lsfdev.ps1 api works too (it prints the 500 body).
```

Limits — eval is a linter, **not** the loader: it does not validate the
load-time semantics specific to forbidden constructs (constraint logic,
whether `MATERIALIZED` is legal on that property shape, aggregation
well-formedness beyond grammar), only one error is reported per call (fix
and re-run), and one statement's error masks later ones. For a whole new
module in one pass, temporarily strip the load-only options
(`NONULL`/`MATERIALIZED`/`INDEXED`) so the `DATA`/calc/form surface checks
cleanly, and probe each `CLASS`/`WHEN`/`CONSTRAINT` separately. Actually
loading the schema still requires the restart — this just catches the typos
first, cheaply.

### Getting values back

`MESSAGE` is useless over the Action API: its text is swallowed entirely —
not in the response body, and (for a plain `MESSAGE`) not even in the server
log; only `MESSAGE ... NOWAIT` leaves a `Server message:` line in the log.
Don't put `MESSAGE` in API scripts at all. Two ways to actually read a value:

**1. `RETURN <expr>;` (platform 7.0+ only) — the action's return value
becomes the response body.** Simplest path for a scalar (a count, a name, a
flag). Works on both endpoints: as the last statement of an `/eval/action`
body, or inside `run()` for `/eval`. **On 6.x this is a parse error** — use
`EXPORT FROM` (method 2), which carries scalars just as well.

```bash
# count via /eval/action — response body is the number, e.g. "6"
# (localhost devmode → NO -u; on production add -u 'admin:' per the auth table)
curl -sS -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-urlencode "script=RETURN (GROUP SUM 1 IF Item i IS Item);" \
  http://localhost:7651/eval/action

# same through /eval — RETURN inside the run action
curl -sS -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-urlencode "script=run() { RETURN (GROUP SUM 1 IF Item i IS Item); }" \
  http://localhost:7651/eval
```

**2. `EXPORT FROM` to stdout via the response body — works on every
version.** For tabular / structured data (and, on 6.x, for scalars too) the
action's `EXPORT` target becomes the HTTP response body — content type is
derived from the format keyword.

```bash
# (localhost devmode → NO -u; on production add -u 'admin:')
curl -sS -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-urlencode "script=
EXPORT JSON FROM idItem = id(Item i), nameItem = name(i) WHERE i IS Item;
" \
  http://localhost:7651/eval/action

# scalar via EXPORT — the 6.x substitute for RETURN (works on 7.0+ too):
#   EXPORT FROM res = 'hello';            → {"res":"hello"}
#   EXPORT FROM cnt = (OVERRIDE (GROUP SUM 1 IF Item i IS Item), 0);
```

**Don't wrap `EXPORT` in `NEWSESSION { ... }`.** The export lands in a
session-local property (`exportFile()`), which the HTTP layer reads *after*
the action finishes; a surrounding `NEWSESSION` throws that property away on
exit, so the response comes back **empty with HTTP 200** (verified on 6.2
and 7.0). This is specific to `EXPORT` — `RETURN` is control flow that
propagates up the stack, so `NEWSESSION { ... RETURN x; }` *does* return `x`
(verified on 7.0). Either way, one-shot eval scripts don't need `NEWSESSION`
at all — every `/eval`/`/eval/action` call already runs in its own fresh
session — so just keep the `EXPORT`/`RETURN` at the top level.

For one-off introspection (just confirming a class exists), `RETURN` is also
the shortest form — the same one-liner as a compile-probe, but the count
comes back in the body instead of an ambiguous empty 200.

### Common recipes

Each answers in the response body. The `EXPORT` forms run on **every**
platform version (verified live on 6.2 and 7.0-SNAPSHOT, 2026-06); on 7.0+
any of them can be shortened to `RETURN <the same expr>;`.

```lsf
// Does class X exist, and how many objects? 200 + count = yes; 500 "not found" = no.
EXPORT FROM cnt = (OVERRIDE (GROUP SUM 1 IF X x IS X), 0);
// 7.0+ shorthand: RETURN OVERRIDE (GROUP SUM 1 IF X x IS X), 0;

// Does property p(Class) exist, and on how many objects is it set?
EXPORT FROM res = STRING((OVERRIDE (GROUP SUM 1 IF p(Class c)), 0)) + ' / ' +
                  STRING((OVERRIDE (GROUP SUM 1 IF c IS Class), 0));

// First 5 names from class X (sample). ORDER by the PROPERTY, not the alias:
// ORDER nm compiles but fails at runtime with a misleading
// "Set operations is invalid" 500.
EXPORT JSON FROM nm = name(X x) ORDER name(x) TOP 5;

// Module loaded? Reference an element only that module defines — a class
// works best: 200 = loaded, 500 "not found" = not in the running config.
EXPORT FROM cnt = (OVERRIDE (GROUP SUM 1 IF Task t IS Task), 0);   // probes the Task module
```

(For the `Eval` module specifically no probe is needed — a working
`/eval/action` call *is* the proof: the endpoint exists only when the running
config REQUIREs `Eval`.)

Wrapping counts in `STRING(...)` when concatenating with text is good style,
but it is not required to avoid an error: `+` between INTEGER and STRING
**coerces** (verified — `'count=' + 5` → `count=5`, `5 + ' items'` → `5 items`,
in either order), it does not throw. When a comma-bearing `OVERRIDE` sits
inside an argument list, give it its own parentheses
(`STRING((OVERRIDE ..., 0))`), or the comma is parsed as an argument
separator.

### Chaining and verifying

The `script=` body can carry any number of statements. Two POSTs
sequenced in a shell pipeline are equally fine — either approach lets
you "clear then refill" or "mutate then count" in one round of API
work:

```bash
curl -sS -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-urlencode "script@/path/to/clean.lsf" \
  http://localhost:7651/eval/action
# inspect HTTP code, continue
curl -sS -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-urlencode "script@/path/to/seed.lsf" \
  http://localhost:7651/eval/action
```

**`HTTP 200` is not proof the mutation landed.** The server returns 200
when the script *compiled and ran* — but a failed `APPLY` (constraint
violation, missing required field, etc.) cancels silently and returns the
same 200 with an empty body. Make every mutation script self-checking; no
`NEWSESSION` wrapper is needed (an eval call already runs in its own
session) — and with `EXPORT` it would even *break* the readback (see the
note in "Getting values back"):

```lsf
// any version (6.x and 7.0+):
// ... NEW / assignments ...
APPLY;
EXPORT FROM res = (OVERRIDE 'CANCELED: ' + applyMessage(), 'OK');

// 7.0+ alternative with RETURN:
// ... NEW / assignments ...
APPLY;
IF canceled() THEN RETURN 'CANCELED: ' + (OVERRIDE applyMessage(), 'no message');
RETURN 'OK: ' + STRING((OVERRIDE (GROUP SUM 1 IF ...), 0));   // count proves it landed
```

`applyMessage()` carries the human-readable constraint text — but it can be
`NULL`, and `'CANCELED: ' + NULL` is `NULL` (an empty response that looks
like success), so always wrap it in `OVERRIDE`. Alternatively verify with a
separate count call or a Playwright screenshot of the list form (Part 3).
Don't trust the transport-level 200 as data-level confirmation.

**Asserting a computed value on the object you just created.** You can't read
the `NEW` alias after `APPLY` — it's scoped to its block (ACTION §2), and a
plain `LOCAL` is reset by `APPLY` (CHANGE §5); a class-wide aggregate mixes in
other rows on a real DB. Two ways to read the **specific** object (verified on 7.0):

```lsf
// 1. Re-find by a unique business key after APPLY (simplest, when it has one):
APPLY;
RETURN (GROUP MAX calcProp(Cls o) IF keyProp(o) = <key>);

// 2. Carry the object through APPLY in a nested LOCAL:
LOCAL created = Cls ();
NEW o = Cls { ... ; created() <- o; }   // capture while o is in scope
APPLY NESTED (created);                  // preserve the LOCAL across APPLY
RETURN calcProp(created());
```

**Leave no trace in the codebase.** A one-shot seed / cleanup / fix
should not change the project tree. The `.lsf` script you posted lives
under `.lsfusion-dev/` or `/tmp/`, not under `src/main/lsfusion/`. If
you find yourself adding a new module to top-`REQUIRE` to call it once
from the UI, you're in the anti-pattern this skill exists to prevent.

## Part 2: Reading the deployed source via the File API

The running server exposes its **classpath** — every `.lsf` module, every
properties file, every resource that the JVM loaded — over a read-only HTTP
API. You ask the server for a file and it streams the bytes it's actually
serving from. The answer is by construction the source the running JVM
is using; nothing on the host filesystem can shadow it or fall behind.

This is **the** way to confirm what's on a server. Reach for it before
anything else when the question is "is feature X really deployed?" or
"what does Y look like right now over there?".

### Endpoints

All three are `POST` to the **web port** (Tomcat — `8080` or via HTTPS on
the host's external port). Body is `application/json`. The app-server HTTP
port `7651` serves only the Action API (`/exec`, `/eval`, `/eval/action`) —
hitting `/files/*` there fails with `HTTP 500` ("Something went wrong"), not
a clean 404, so don't read that as a server-side bug.

| Path | Body | Purpose |
|---|---|---|
| `/files/list` | `{"pathPattern":"<glob>","limit":N,"offset":N}` | List every classpath entry matching a glob |
| `/files/read` | `{"path":"/<path>","offset":N,"maxBytes":N}` | Stream the bytes of one entry |
| `/files/search` | `{"regex":"<pat>","pathPattern":"<glob>","limit":N,"contextChars":N,"timeoutSeconds":N,"maxScannedFiles":N,"maxFileBytes":N}` | Regex-grep across entries; returns matching lines with file path + line number + excerpt |

**Check `truncated` and `timedOut` in every response — the defaults bite.**
`/files/list` caps at **500** entries by default (`"truncated": true` means
there are more — page with `offset` or narrow the glob). `/files/search` runs
under a **~5-second** default time budget, and on a wide glob
(`**/*.lsf` over a classpath with a couple hundred jars) candidate
enumeration alone can eat all of it — the response comes back
`{"hits":[], "timedOut":true, "scannedFiles":0}`, which **looks exactly like
"no matches" if you only read `hits`**. Never conclude "not found" from a
response with `"timedOut": true`. For wide scans, pass an explicit
`"timeoutSeconds": 15` (or more) and narrow `pathPattern` to the namespace
you care about; `scannedFiles` vs `candidates` in the response tells you how
much of the classpath was actually covered.

Auth is identical to the rest of the Action API: production → `-u admin:`
(empty password is the default); devmode → no `-u` at all. See the auth
section in Part 1 if anything is unclear.

The API is part of the platform's **`ClasspathFileTools`** server (the stack
trace on a `400`-shaped error mentions
`lsfusion.server.physics.admin.files.ClasspathFileTools`) and is bundled
with the standard package on platform builds from **mid-2026 onwards**
(7.0-SNAPSHOT released 2026-05-26 was the first build to ship it locally
on this skill's test host). On older builds `POST /files/list` returns
`HTTP 405` because the path isn't mapped — that's the signal to upgrade
the platform via the lsfusion-deploy skill.

### Paths in the classpath

Every path is **classpath-rooted** with a leading slash. There is no notion
of a host filesystem path here — the API flattens whatever the JVM's
classpath contains:

- `/<TopModule>.lsf` — the top module sits at the root of the classpath
- `/lsfusion.properties` — root-level config picked up by the server
- `/<namespace>/<Class>.lsf` — sub-paths mirror MODULE namespaces (e.g.
  `/library/books/Book.lsf`)
- `/system/Authentication.lsf` — platform modules live alongside yours

The glob patterns are POSIX-shell-style with `**` for "any number of
directories": `**/*.lsf`, `<namespace>/**`, `**/<Class>*.lsf`.

### Concrete recipes

Substitute `<host>`, the class names, and the namespace for whatever the
project actually uses. The shapes below stay the same.

```bash
# Does my new module exist on the running server?
curl -sS -u 'admin:' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"pathPattern":"**/<Class>*.lsf"}' \
  https://<host>/files/list
# → {"timedOut":false,"offset":0,"limit":500,
#    "files":["/<ns>/<Class>.lsf","/<ns>/<RelatedClass>.lsf"],"truncated":false}

# What does my top module declare on the deployed server?
curl -sS -u 'admin:' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"path":"/<TopModule>.lsf"}' \
  https://<host>/files/read

# Read the deployed lsfusion.properties — confirms logics.topModule, db.deny* flags as the server saw them at boot
curl -sS -u 'admin:' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"path":"/lsfusion.properties"}' \
  https://<host>/files/read

# Find every place a name is referenced (regex grep), .lsf only, with context.
# Explicit timeoutSeconds: the ~5 s default can expire before a wide glob
# scans a single file (see the callout above).
curl -sS -u 'admin:' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"regex":"<propertyName>","pathPattern":"**/*.lsf","limit":50,"contextChars":80,"timeoutSeconds":15}' \
  https://<host>/files/search
# → {"hits":[{"path":"/<ns>/<Class>.lsf","line":7,"excerpt":"<propertyName> = DATA <OtherClass> (<Class>);"}, …],
#    "candidates":420,"timedOut":false,"scannedFiles":37,"truncated":false}
```

### Read response shape

`POST /files/read` returns:

```json
{
  "path": "/lsfusion.properties",
  "offset": 0,
  "bytesRead": 173,
  "truncated": false,
  "mimeType": "text/properties",
  "eof": true,
  "content": "logics.topModule = <TopModule>\r\n…"
}
```

For text files `content` is the file as a JSON-escaped string — pipe through
`jq -r .content` to get the raw text. For binary files the API still wraps
bytes into the same JSON envelope; expect non-printable escapes if you
read e.g. an image. The `mimeType` field reflects what the platform thinks
based on file extension. `truncated: true` plus a non-`eof` response means
you hit `maxBytes` (defaults are reasonable but bounded) — re-request with
a larger `maxBytes` or page via `offset`.

### Comparing deployed source with local

```bash
# Pull the deployed copy and diff against your local working tree
curl -sS -u 'admin:' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"path":"/<namespace>/<Class>.lsf"}' \
  https://<host>/files/read | jq -r .content \
  > /tmp/deployed.<Class>.lsf
diff /tmp/deployed.<Class>.lsf src/main/lsfusion/<namespace>/<Class>.lsf
```

If the diff is empty, what you have locally is what's running. If not,
the running jar is from a different commit — redeploy via the
lsfusion-deploy skill (or git-checkout to whatever matches, depending on
which direction is correct for the task).

## Part 3: Visual verification via Playwright (browser-level)

API calls prove things to you. **Screenshots prove things to the user.**
When a task is "I added a field to this form" or "the new attribute should
appear in this column", a rendered screenshot is unambiguous in a way that
a JSON count is not — and the user can see at a glance whether the result
matches expectations.

### When to write your own Playwright vs use `lsfdev.ps1 verify`

The lsfusion-dev skill's `verify` command is **local-only** — it bakes the
URL from `.lsfusion-dev/config.json`, logs in to the local dev install, and
takes one landing-page screenshot. That's enough for "the local server
came up". For anything else — a deployed host (lsfusion-deploy target), a
specific form, a multi-step navigation, multiple screenshots — write a
small Python script with Playwright directly. The full reference template
is in [references/playwright-remote.py](references/playwright-remote.py);
copy it, adapt URL / credentials / the body of `navigate_and_capture()`,
and run.

### Things that will cost you a debug cycle if you don't know them

The reference script bakes in workarounds for each of these — read it
before writing your own.

- **Login form selectors.** When devmode is OFF (any deployed install) the
  login form is real. Platform-standard inputs: `input[name="username"]`
  and `input[name="password"]`, with an `input[name="submit"][type="submit"]`
  button. Default account `admin` / empty password unless rotated. After
  clicking submit,
  wait `networkidle` plus a 2–3 s settle for the SPA to render the
  navigator. When devmode is ON, there's no form — your fill calls will
  time out; treat that as a no-op, not a failure.
- **Grid rows do NOT open the detail card on double-click.** The canonical
  action is the `Edit` toolbar button in the bottom-right of the grid
  toolbar, after selecting the row. New objects come from the `Service` /
  `Product` / similar `+ Add` buttons next to `Edit`.
- **The `Loading` overlay between actions.** After clicking `Edit`, lsFusion
  shows a `Loading` spinner before the card paints. A naive
  `wait_for_timeout(2000)` captures the spinner, not the form. Wait for the
  overlay to detach first: `page.wait_for_selector("text=Loading", state="detached")`,
  then `wait_for_load_state("networkidle")`, then an extra 2 s settle.
  Caveat: the word `Loading` may be localized on non-English installs —
  wrap in `try` and fall back to a generous fixed wait so the script still
  produces output, just maybe of the spinner.
- **Grids scroll horizontally.** A form's `EXTEND FORM ... PROPERTIES(i) myNewCol`
  appends `myNewCol` to the right end of the columns; on a 1600 px viewport
  with a typical Items grid it'll be off-screen. Focus the grid (click any
  visible cell) and press `End` 10–20 times to scroll the new columns into
  view.
- **Navigator tooltip pollution.** Hovering a navigator sidebar entry shows
  a tooltip with `sID: ...` / `Path: ...` and it **lingers**. Before each
  screenshot, click in dead space (`page.mouse.click(800, 400)`) to dismiss
  it — otherwise screenshots end up with a debug tooltip stuck to the
  navigator that's nothing to do with the form you're proving.
- **UI strings are locale-dependent.** The same deployed install can serve
  English / Polish / Russian / Ukrainian / ... depending on per-user
  preference and the resource bundles in the project. Don't hardcode UI
  text as the only navigation strategy. The reference script tries text
  first and prints "could not find" on miss; that miss is a signal to look
  at a screenshot of where you actually ended up and pick a different
  matcher, NOT a fatal error.

### What the reference script captures by default

[references/playwright-remote.py](references/playwright-remote.py) ships
with a `navigate_and_capture()` body that takes 6 screenshots — login,
post-login navigator, items grid, items grid scrolled right, one item
detail card, plus the price segments / categories list. Treat this as
illustration of the pattern (`click navigator entry → wait → screenshot`)
and replace the body with whatever your task needs. Output goes to
`./screenshots/` next to the script.

## Notes & gotchas

- **`-u admin:` ≠ no `-u`.** Repeat after me. The single mistake worth more
  than all the others combined.
- **Use `--data-urlencode`, not `--data`.** With `--data` the shell does
  no encoding and `&`, `+`, `=`, `%` inside your script become protocol
  syntax — the server then parses garbage.
- **Script from file: `--data-urlencode "script@/path/to/file.lsf"`** (note
  the `@`, not `=`). Cleanest way to pass a multi-line script with quotes
  and `$` inside.
- **`/eval` wants a `run` action; `/eval/action` wants an action body.**
  Mixing them up returns "Property or action 'run' not found" (passed an
  action body to `/eval`) or "syntax error" (passed a module with `MODULE` /
  `REQUIRE` to `/eval/action`).
- **Production `/eval/action` requires the Eval module to be REQUIREd by
  the project.** It's in the default REQUIRE list this skill family
  recommends. If the deployed project doesn't have it, `/eval/action`
  returns 404 — you'll have to deploy a temporary build with `Eval` added,
  or use `/exec?action=<an action the project itself declares with @@api>`.
- **The eval API is a runtime tool.** Don't use it as a substitute for
  proper migration scripts or for changing production data without
  approval — that's exactly the kind of action the user trust pattern
  asks you to escalate, not silently execute.
