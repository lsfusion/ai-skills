# `lsfdev.ps1 verify` — reference

The full contract of the UI check of the lsfusion-dev skill: what a run
produces, the direct form open (`-OpenScript`), navigation and gestures
(`-Click`, `-DoubleClick`), generic interaction steps (`-Do`), exit codes
and diagnosis lines, the watchdog, persistent sessions (`-Session`), remote
targets (`-Url`), and the split between `verify` and an in-app browser.
SKILL.md step 5 has the short form and the fixed log → API → UI order;
read this file before the first run that uses `-Do`, `-DoubleClick`,
`-Session` or `-Url`, and whenever a `verify` run fails. "Step 4" / "step
5" below refer to SKILL.md's Standard workflow; "Part 3" is the
Playwright-script part of the lsfusion-eval skill.

## What a run does

`verify` drives a headless Chromium (via Playwright) to:
- screenshot the landing page → `.lsfusion-dev/verify-login.png`,
- **if a login form is present** (devmode off), log in — credentials
  from `-User` / `-Password`, default `admin` / empty — and screenshot
  the result → `.lsfusion-dev/verify-app.png`,
- dump the final DOM → `verify-dom.html` and the browser console →
  `verify-console.txt` — `console.*` messages **and uncaught page
  exceptions** (`[pageerror]` lines).

In devmode lsFusion auto-authenticates, so there is **no login form**
and the landing screenshot already shows the navigator + forms. The
first `verify` ever installs Playwright + Chromium (~120 MB); one-time.

## Targets: the local web client and `-Url`

**The target is the local web client by default; `-Url <base>` points
the same run at any other one** — a deployed host, a non-devmode
server, a second local instance. Pass the web client's base URL
including its application context (`https://host/app/`) and the
target's own credentials (`-User`/`-Password`; the login form is
detected automatically — no local `-NoDevMode` is involved). Run it
from a project already set up with this skill (`-ProjectDir`): the
project supplies the configuration and the writable browser/artifact
state, while its own server, Tomcat and database need not be running
(don't `setup` a project just for this — setup provisions a database).
Two limits: the certificate must be valid (there is no insecure-TLS
switch), and `-OpenScript` on the target is still gated by the platform
— the `Eval` module in the build plus the UI/API permissions listed in
the shared reference below.

## Direct form open — `-OpenScript`

**To verify a specific form, open it directly with `-OpenScript` — the
default; don't click through the navigator.** `verify` navigates the
headless browser to `<web>/eval/action?script=<your code>` — the
direct-open URL mechanism (canonical reference, shared with the
lsfusion-eval skill:
[form-open-url.md](../../lsfusion-eval/references/form-open-url.md))
— and the form opens exactly as if a user had opened it — screenshot →
`verify-open.png`. The payload is an ordinary action script, fully
parameterizable — a named form, a form with bound objects, or the edit
card of one specific object:

```
# a navigator form by name - assert a value the form SHOWS (a grid cell,
# a panel value), never the form's own caption (see the -OpenExpect rule below)
lsfdev.ps1 verify -OpenScript "SHOW Shop.items DOCKED;" -OpenExpect "Coffee beans"

# the edit card of one object, looked up by business key
lsfdev.ps1 verify -OpenScript "FOR Shop.name(Shop.Item i) = 'Coffee beans' DO SHOW EDIT Shop.Item = i DOCKED;" -OpenExpect "Coffee beans"

# ...or by internal id (grab it beforehand with api: EXPORT FROM id = Shop.Item i, ...)
lsfdev.ps1 verify -OpenScript "FOR LONG(Shop.Item i AS Shop.Item) = 32178 DO SHOW EDIT Shop.Item = i DOCKED;"
```

- **Open the form in the window mode it will have in production — for
  navigator forms and edit cards that means `DOCKED`, as in every example
  above.** A bare `SHOW` in this call context defaults to a small
  *floating* window whose layout (column widths, flex fills, collapsed
  containers) is not what the user will see — append `DOCKED` to judge
  the actual `DESIGN`; keep `FLOAT`/`EMBEDDED`/`POPUP` only when the
  form genuinely opens that way in prod (e.g. `DIALOG`, `SHOW … FLOAT`),
  and when prod opens the form through a project action, call *that
  action* — mode, filters and session come along (rationale: the shared
  reference above).
- **Qualify every name with its namespace** (`Shop.items`, not `items`).
  The script compiles against *all* loaded modules — a bare name that is
  unique in your module (`name`, `date`, …) is routinely ambiguous here.
  Same rule as `api` scripts.
- `-OpenExpect "<text>"` waits for that text on the opened form and
  reports found / not-found — that's your assertion; without it you just
  get the screenshot. It matches **visible text nodes AND the values of
  visible inputs** (a form field's content is an input `value`, not a
  text node), and the report says which kind matched: a plain
  "visible" for text, "as the VALUE of a visible input" for field
  content. **Never use the form's own caption as the expect text**: the
  caption renders on the docked **tab** (and in the navigator) —
  *outside* the form's `[lsfusion-form]` subtree — so the scoped check
  reports it as `on the page but NOT inside the opened form` and strict
  verify exits 2 even though the right form opened (the report then
  names the tab-caption match as the likely cause). Assert something
  that renders *inside* the form: a container/panel caption or a known
  data value, like every example above.
- **The open itself is cross-checked against the DOM.** The report
  prints the form really on screen (`Active form : tab '…'; visible
  sID(s): …`) and compares it with the form/class the script names —
  `[OK] Open check: the script's form is on screen ('…' - sID …)` is the
  real pass (the trailing note says which evidence matched). A
  `[WARN] Open check:` means the `SHOW` did not take effect (or its form
  was covered): measured false positive — an app's own
  `onWebClientStarted` opened a dashboard over the requested card, and
  the card's name sitting in a dashboard grid still satisfied the text
  search. When the matched form is a concrete DOM element, the
  `-OpenExpect` hit is additionally **scoped to that form's subtree** —
  text sitting only on another form reports as `on the page but NOT
  inside the opened form`. For `SHOW EDIT/LIST <Class>` the DOM carries
  no class identity (an auto form is just `_FORM_<n>`, a caption is just
  text), so the open check alone is only *circumstantial* (Info, not
  OK): **pair such opens with `-OpenExpect`** — a hit inside that form
  is what verifies it. **A found `-OpenExpect` under a WARNed open check
  is demoted to a WARN — never treat it as a pass**, and it fails the
  strict exit (verify exits 2 on any failed check; `-AllowWarnings` for
  report-only exit 0); same when the cross-check itself could not run or
  confirm while the script names a form (`UNVERIFIED`). Only when the
  script's form is merely *named* nothing like what it shows (custom
  edit form named unlike its class) may a WARN be over-cautious — then
  judge `verify-open.png` (and pass `-AllowWarnings` if that run must
  exit 0).
- **Checking several forms in a row? Pass `-OutPrefix <stem>` per run.**
  Every verify run wipes and rewrites its standard artifact set (the
  `screenshot:<name>` files of `-Do` chains are left alone), so a batch loop
  without it keeps only the *last* form's `verify-open.png` — the
  evidence of the other runs is gone. With a per-form stem each run
  writes its own set (`items-open.png`, `items-dom.html`,
  `items-console.txt`, …) and the report's "judge …" messages name those
  files:

  ```
  foreach ($f in 'items','partners','orders') {
    lsfdev.ps1 verify -OpenScript "SHOW Shop.$f DOCKED;" -OutPrefix $f
  }
  ```

  Letters, digits, `.`, `_`, `-` only; the default stem stays `verify`.
- Non-ASCII script text (Cyrillic keys, localized captions) → UTF-8 file
  + `-OpenScriptFile`, exactly like `api -ScriptFile` (see the UTF-8
  pitfall in step 4).
- A script error (unknown form, missing namespace, typo) surfaces as the
  server's error text in the verify output — fix and re-run; nothing to
  screenshot-guess.
- Needs the web client up; in devmode it rides the auto-auth admin
  session. The `SHOW EDIT` / `SHOW … OBJECTS` forms and the non-devmode
  auth gating are in the shared reference above.

## Navigation and gestures — `-Click` / `-DoubleClick`

**To test the user's path, use `-Click` / `-DoubleClick`** — reach for
them when the *navigation itself* is what you're verifying (the navigator
entry exists, is reachable, opens the right form), or when the user's
double-click gesture on a grid cell is what you're testing (`-OpenScript`
or `-Click` brings up the list form, `-DoubleClick` double-clicks a cell
there):

```
lsfdev.ps1 verify -Click "Master data > Items"
lsfdev.ps1 verify -OpenScript "SHOW Shop.items DOCKED;" -DoubleClick "Coffee beans" -DoubleClickExpect "Shop.item"
```

`-Click` clicks navigator entries by their visible text (chain with `>`
for tab-then-entry) → `verify-click.png`. **`-DoubleClick` is a gesture,
not "open the card"** — what a double-click does is decided per cell by
the platform (web client `GKeyStroke.isEditObjectEvent`, measured on 7.0):
an **editable** cell starts its **in-place editor** (the `CHANGE` event)
and opens no form; a **read-only** cell of an object whose class has an
edit form (declared `EDIT` form or the auto-generated one) opens that
form (`editObject`); a property with `CHANGEMOUSE 'DBLCLK'` runs *that*
action instead, editable or not; a `CUSTOM` renderer decides itself; in a `DIALOG` a double-click
is *OK* (`System.formOk` is bound to it). So `verify` **classifies the
outcome** after the gesture — `opened form <sID> (active tab '…')`,
`in-place editor`, or `no visible reaction` — screenshots it →
`verify-dblclick.png`, and never fails on the outcome by itself. **To
assert that a card opened, add `-DoubleClickExpect "<form sID | tab
caption | text inside the card>"`** — it passes only on a form the
double-click opened (unmet = failed check, exit 2). When the card itself
is what you need to see, skip the gesture: the direct open `-OpenScript
"FOR Shop.name(Shop.Item i) = 'Coffee beans' DO SHOW EDIT Shop.Item = i
DOCKED;" -OpenExpect "…"` opens it regardless of the list's cell state.

## Generic interaction steps — `-Do`

**To drive elements `-Click` cannot reach — buttons/inputs inside `CUSTOM`
(React) components, filters, dialogs — pass `-Do`**: an ordered list of
generic interaction steps, run after the `-OpenScript` open /
`-Click`/`-DoubleClick` navigation, each `verb:rest` with **any Playwright
selector** (css, `text=...`, `button:has-text(...)`):

- `click:<selector>` / `dblclick:<selector>` — e.g. `click:text=Поставить`
  hits a React button by its caption. Failures are **classified** like
  `-Click`'s, never a bare `Timeout 15000ms`: *DISABLED* (for native
  lsFusion controls that usually means a **server-side** state —
  `DISABLEIF`/readonly, commonest real cause: a value typed just before
  was never committed; CUSTOM/React components may also disable purely
  client-side), *another element intercepts the pointer* (naming the
  overlay), *became hidden*, *disappeared* — mixed retry histories
  report the **last** observed state. **Grid-row action buttons**:
  `click:text="▶"` hits the column **header** (the header carries the
  caption text; the row buttons are icon-only) — scope by row instead:
  `click:tr:has-text("<text unique to that row>") .btn`. Interaction
  verbs take the *first visible* match, so the row text must identify
  ONE row, and bare `.btn` is safe only when the row has exactly one
  button — with several, use a button-specific class/attribute from
  `verify-dom.html`;
- `hover:<selector>` — real mouse-over (tooltips, hover-revealed handles);
- `rclick:<selector>` — right button: the real `contextmenu` event
  (grid/row context menus) — no synthetic `dispatchEvent` via `eval:`
  needed;
- `drag:<selector>=><selector>` — a **real mouse gesture**: `mousedown` on
  the source, intermediate `mousemove`s, `mouseup` on the target — what
  drag-to-draw UIs (Gantt dependency links, resize handles, sliders)
  actually listen for. `click`/`dblclick`/`rclick`/`hover`/`drag`/`dnd`
  selectors accept an `@x,y` offset from the element's top-left corner
  (`drag:.task-a@120,8=>.task-b@4,8` starts from a bar's edge connector);
- `dnd:<selector>=><selector>` — **HTML5 drag-and-drop**, the OTHER drag
  protocol: real `DragEvent`s (`dragstart` → `dragover` → `drop` →
  `dragend`) sharing one live `DataTransfer`, so what the component's
  `dragstart` handler `setData()`s is readable in its `drop` handler.
  Kanban boards, sortable lists and drop zones (`draggable="true"`
  elements) listen to these and never see a mouse-event drag — a
  component speaks one protocol or the other, so when `drag:` visibly
  does nothing, use `dnd:`. The step reports whether `dragover` was
  `preventDefault()`ed (a real browser fires `drop` only then — `NOT
  preventDefault()ed` means the target isn't an armed drop zone) and the
  `DataTransfer` types the source set;
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
- `edit:<caption>=><value>` — **the way to type into an lsFusion
  panel/grid cell**: the in-place editor's `<input>` does not exist until
  the cell gets focus, so `fill:`/`type:` can never reach it, and a blind
  `dblclick@x,y` is viewport-fragile. `edit:` finds the panel cell by its
  visible caption (the platform's own label→cell wiring, exact match then
  substring; any Playwright selector also works as the target — that's
  how you hit a *grid* cell), double-clicks it, selects all, types the
  value and **commits with the right gesture for the editor kind**:
  single-line editors commit on Enter, but **multiline editors (`TEXT`
  properties → `textarea`, rich text → contenteditable) treat plain
  Enter as a NEWLINE** — the value then never reaches the server and
  e.g. a `DISABLEIF` on it stays on; for those `edit:` commits by
  **blurring the editor** (measured: the reliable commit for the plain
  `TEXT` textarea — a focus loss commits every editor kind, which is
  also why a "sacrificial" click elsewhere works by hand).
  A caption miss fails fast and prints the editable panel captions of
  the page; a cell whose double-click opens no editor (read-only, action
  property) fails with that diagnosis instead of typing into the void;
- `press:<key>` (e.g. `Enter`), `eval:<js>` (result lands in the report),
  `wait:<ms>`;
- `screenshot:<name>` — a screenshot **at that point of the chain** →
  `<stem>-<name>.png` (letters, digits, `.`, `_` — **no dash**: a stem
  may contain dashes, and only a dash-free name makes the file split
  unambiguously at its last dash, otherwise stem `orders` +
  `archive-menu` and stem `orders-archive` + `menu` would silently share
  one file; the run's own artifact names — `login`, `app`, `open`,
  `click`, `dblclick`, `do`, `dom`, `console`, `phase` — are reserved).
  One chain can document
  several screens — the menu opened by `rclick:`, the state after
  `press:Escape` — instead of one run per screen; the post-chain
  `verify-do.png` is still taken;
- `assert-count:<selector>=><n>` / `assert-text:<selector>=><substring>` —
  **native assertions**: exactly `n` visible matches / some visible
  match's text, **its own value, or the value of any visible
  `input`/`textarea`/`select` inside it** contains the substring
  (case-insensitive) — so a container selector (a panel, a form, a
  component root) sees what its fields show. Both poll up to 5 s (a render lagging the previous
  action isn't a failure), then fail the step — and with it the strict
  `verify` exit — with a concrete diagnosis (`3 visible match(es),
  expected 4`; the texts actually found). Prefer these over eyeballing
  `verify-do.png` for countable/textual expectations.

`-Do` interaction verbs resolve selectors to the **first VISIBLE match**
(the `assert-*` verbs consider **all** visible matches). The web client
keeps the full DOM of inactive docked tabs — toolbars included — so a
selector like `button:has-text("Zapisz")` routinely matches a hidden
duplicate first. Hidden matches are skipped automatically and reported
in the step result (`2 matched, 1 visible - using the first visible`);
when **every** match is hidden the step fails with exactly that diagnosis
(scope the selector or close the other tabs), and a selector that can't
be parsed fails fast with Playwright's own parse error. Appending
`:visible` by hand is unnecessary, though it remains valid.

```
lsfdev.ps1 verify -Click "Расписание" -Do "edit:Комментарий=>Иванов", "drag:.gantt-task-a=>.gantt-task-b", "click:button:has-text('Поставить')"
```

The chain stops at the first failed step; each step's ok/error (and every
`eval` result) is printed, and the post-chain state goes to
`verify-do.png`; each `screenshot:<name>` step reports the file it wrote
(earlier runs' custom screenshots are not wiped — only the standard set
is — so trust the step lines, not a directory listing). Non-ASCII values in `-Do` cross the same argv boundary as
`api -Script` — when calling through bash + `powershell.exe`, put Cyrillic
text in an `eval:` step or run the command via an in-process PowerShell
tool instead (see the UTF-8 pitfall in step 4). **Steps with commas or
nested quoting → `-DoFile <path>`**: a UTF-8 file with a JSON array of
steps or ONE step per line (`#` comments allowed) — a nested
`powershell -Command` collapses `-Do` array commas into one argument,
gluing steps into a single garbled selector (lsfdev warns when a step
looks glued); the file transport cannot be corrupted by quoting layers.

## Exit codes and diagnosis lines

**`verify` is strict by default: exit 0 means every requested check
passed.** Any failed check — `-OpenExpect` not found or found on the
wrong form, a WARNed open check, a failed `-Click`/`-DoubleClick`/`-Do`
step (assertions included), an unmet `-DoubleClickExpect`, a login
failure, a Playwright error — exits
**2**, so scripts and CI can trust `$LASTEXITCODE` instead of parsing
`[WARN]` lines. `-AllowWarnings` restores report-only exit 0; tool-level
errors (missing python, bad usage) exit 1 either way. Browser console
errors are reported but never flip the exit code (apps log noise there)
— but two kinds get their own diagnosis lines. **Uncaught page
exceptions get their own `[WARN] Uncaught page exception: <Name>:
<message> @ <resource>:<line>:<col>` lines** (deduplicated, `(xN)` for
repeats), listed *above* the custom-view diagnoses they usually cause:
a web resource that died while loading (a `SyntaxError`: the **whole
file never ran**, nothing it defines exists on the page) would
otherwise surface only as the `'X' is not a component` it causes
later. When the exception is located in a file named exactly after the
missing component (a resource is named after what it defines:
`…/web/init/BrokenView.js` for `'BrokenView'`) or its message names
that identifier, the report says that file died before defining it —
otherwise it only tells you to check. The resource and 1-based
position after `@` name the file — a compile-time error has no stack,
so that is the only thing that does; exceptions from web workers and
out-of-process iframes may lack the separate `@ resource:line:col`
suffix, but any stack frames they carry stay in `verify-console.txt`. And
**custom-view failures get their own
`[WARN]` diagnosis lines above the total counter** (both kinds stay
included in its count). A broken `.jsx` web resource
is served by the platform as a `console.error` stub *instead of* its
script, so the report prints `.jsx transform FAILED: … <resource>:
<Babel error + source position>` (and any render-time `Custom view
error: … '<fn>' is not a component`) plus what it means: the component
function never got defined, so every form using it renders an **empty
custom container** — the typical broken-custom-view signature; that
blank area on the screenshot is this failure, not a layout or data
problem. Fix the `.jsx` at the reported position and re-run — web
resources are picked up on the next page load, no restart. Since these
lines alone don't flip the exit code, **pair the run with an assertion
on content the view renders** (`-OpenExpect`, or `-Do
"assert-text:..."`) when a broken custom view must fail the batch.

## The watchdog and load timeouts

**A hung page cannot hang `verify`.** The whole browser run sits under
a watchdog (default 180 s; `-Timeout <s>` sets the budget). On overrun
the run is tree-killed and the report names the hung step (`open-wait:
<form> is rendering`, `do 2/5: …`) plus the browser-console tail — the
signature of a form that wedges the web client's renderer, which is an
app bug to fix, not a browser or machine problem. Exit is 1
(tool failure; `-AllowWarnings` does not soften it), artifacts written
before the hang stay on disk, and in `-Session` mode the session browser
is closed too (it held the wedged page and would poison the next call).

**A load that times out is usually explained on the web client's server
side — the report goes there for you.** Every page-load timeout is
named as a `[WARN] Load timeout - …` line — the navigation without a
`load` event, a `/login` page that never rendered its form, a direct
open that never reached `/main`, a `Loading` indicator still on screen
after 60 s — and the watchdog kill counts as one too. Each is followed
by the tail of `.lsfusion-dev/tomcat/logs/gwtlog-err.log`, the web
client's error log (log4j WARN+, also where every exception the browser
reports back is logged): **only what the run appended**, labeled as
such, or the last lines explicitly marked as older when nothing was
appended — in exactly these cases the browser console tends to be
silent while that file has the answer (measured). Local web client
only; with an explicit `-Url` to another server read *its*
`gwtlog-err.log`. The `Removing navigator session…` ERROR lines in it
are normal session cleanup, and the report says so.

## Persistent browser — `-Session`

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
effect on an already-running session. With a remote `-Url`, **repeat the
same `-ProjectDir` and `-Url` on every continuation**: a session call
without `-Url` targets the local web client again, finds the page
"elsewhere" and navigates away from the remote app. And `-User`/`-Password`
on a continuation do not re-authenticate a session that is already logged
in — check another role in a fresh (non-session) run.

## Reading a failed `-Click`, hand-written scripts, viewport, first open

**When a `-Click` misses, the output tells you why — read it before
theorizing.** A failed click is classified from the browser driver's log and
reported as one of: **not found** (no element with that visible text — the
output then prints the actual clickable captions harvested from the
failure-time page: `Clickable navigator captions: ...`, so pick from that
list instead of guessing); **intercepted** (element found and visible, but
an overlay — loading glass, sliding panel, hover popup — swallowed every
click; a forced click is attempted automatically and reported);
**disabled** (found and visible but never enabled — for native lsFusion
controls usually a server-side `DISABLEIF`/readonly/permission state);
or **not visible** (the text exists in the DOM but is CSS-hidden, e.g.
icon-only navbar entries — text-based `-Click` cannot hit those, use
`-Do 'click:<css>'` with a selector from `verify-dom.html`). Captions and row
text are locale/data-dependent — trust the printed caption list and
`verify-app.png` / `verify-click.png` over any assumption about what the
captions "should" be. `-Click`/`-DoubleClick`/`-Do` cover "did it render"
checks and interactions — and **a multi-step flow with assertions
between steps is still one `verify`**: a `-Do` chain with
`assert-text:` / `assert-count:` / `screenshot:<name>` steps, plus
`-Session` when the scenario spans several calls; a deployed or
non-devmode host is the same run with `-Url` (above). After `verify`,
the in-app browser may poke at the rendered page under the split
below. **A hand-written Playwright script is for when `verify` is
unavailable or cannot express the operation**: an invalid or
self-signed certificate, branching on page state or feeding a value
read from the page into later steps (a linear `-Do` chain cannot;
plain inspection is `eval:` plus the report), network request/response
evidence (`verify` does not capture it), or a box without a set-up
lsfusion-dev project or without Windows PowerShell. The lsfusion-eval
skill's Part 3 has the rules and a Python template (login, waits,
lsFusion selectors handled) — start from it, not from scratch, and use
the shared reference linked above for the direct-open URL.

The viewport defaults to **1920×1080** — judge layout at a realistic
size before calling it broken: on a narrow viewport dense forms
(calendars, wide grids) legitimately collapse into `+N more`
placeholders and the screenshot *looks* buggy while the app is fine.
Override with `-ViewportWidth/-ViewportHeight`, and pass `-Locale`
(e.g. `ru-RU`) when the browser-side language matters for the shot.

**The first open of a form after a `restart` takes 10–40 s** (the
server builds the form lazily; a Maven project may still be
compiling). `verify` already waits generously for it — when a run
still times out, read the reported phase and the logs before blaming
cold start, and note that `-Timeout` sets the whole-run watchdog, not
a per-step wait. Hand-written scripts must budget for this themselves
(Part 3).

## In-app browser vs `verify` — the split

The split below assumes `verify`'s own prerequisites: Windows
PowerShell, Python 3 and a set-up project. Without Windows PowerShell or
a set-up project, the fallback is the Part 3 script — subject to its own
prerequisites, which include Python: with no Python at all, neither
bundled path runs until it is installed. The pane is never the fallback;
it stays optional, after verification.

**In-app browser vs `verify` — the split.** Some sessions expose an
in-app browser as tools (Claude Desktop's Browser pane:
`mcp__Claude_Browser__*` — `navigate`, `computer`, `read_page`,
`get_page_text`, `find`, `form_input`, `read_console_messages`,
`read_network_requests`). **`verify` is the default path for checking
a form** — direct open at production viewport, assertions, artifacts
on disk, one call. The pane is a convenience for *reading* a page
that is already rendering (its text / DOM / console) and for quick
clicks — and on some machines it does not work at all, so the rule
is: **one attempt; on the first failure signature below, stop and run
`verify` — do not retry, resize, or reload your way through it.**
Measured cost of doing otherwise on one box: five wasted calls, after
which `verify` did the entire check — direct open, screenshots, DOM
checks, scrolling, a card click, typing into a search — in one run.
When the pane is absent (terminal CLI, headless runs, subagents, CI),
use `verify` — or the Part 3 script when `verify` is unavailable and the
script's own prerequisites are met.

Pane failure signatures — each means "switch to `verify` now":
- **"The tab for this application is already opened. Please check
  it"** after navigating to `<base>/eval/action?script=…` (the
  platform's `push.notification.tab.already.opened` page): the direct
  open's 302 landed on `/push-notification` and the service worker
  did not hand the action to an app tab — not registered in the pane
  profile, or the pane holds another tab on the app. Loading the base
  URL first is part of the ONE attempt, not a recovery step; this page
  is the stop signal (`verify`'s own open handles the same case with a
  built-in reload).
- **Screenshots timing out** (~5 s each measured on one box, ~30 s
  each right after the pane opens on another) while
  `navigate`/`read_page`/JS work — interaction actions are gated on
  one prior successful screenshot, so nothing interactive will run;
  stop signal.
- **A navigator entry outside the viewport** even after
  `resize_window` — and the pane's viewport is not the layout under
  test anyway.

What works in the pane, when it works (measured against 7.0-SNAPSHOT):
- **Direct form open is the same URL mechanism.** Load the app base
  URL first (that registers the service worker), then navigate to
  `<base>/eval/action?script=<SHOW ... DOCKED;>` (URL-encoded) — the
  302 → `/push-notification` → service-worker → `/main` dance works
  in the pane and the form opens exactly as with `-OpenScript`. All
  the `-OpenScript` rules above (DOCKED, namespace-qualified names,
  script errors returned as text) apply verbatim; the "already
  opened" page above is its failure mode.
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

Where the pane is NOT sufficient even when it works — use `verify`
(measured):
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
  "drag:..."` / `mouse:` steps, which interpolate the path — and for
  HTML5 drag-and-drop (kanban boards), `dnd:`, since mouse events
  never reach `dragstart`/`drop` listeners at all.
- **Evidence.** The pane leaves nothing on disk — no PNGs to attach,
  no JSON verdict, nothing re-runnable. When the user needs proof or
  a repeatable check, run `verify` even after eyeballing the pane.
- **Capture flake.** A screenshot timeout is a stop signal (see the
  signatures above): `read_page`/`get_page_text` may still answer, but
  nothing interactive runs until a capture succeeds, and waiting for
  one is exactly the loop that wasted the calls — go to `verify`.
- **No password entry.** Typing credentials in the pane is
  off-limits for the agent. Irrelevant in devmode (auto-auth, no
  login form), blocking on a non-devmode target — there `verify` / a
  Playwright script does its own login.
