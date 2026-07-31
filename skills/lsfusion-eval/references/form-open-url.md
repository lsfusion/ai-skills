# Opening a specific lsFusion form directly by URL (no navigator clicking)

Shared mechanism reference for the **lsfusion-dev** skill (`verify -OpenScript`
automates all of this against the local dev install) and the **lsfusion-eval**
skill (hand-written Playwright scripts and in-app-browser drives against any
host). Verified live on 7.0-SNAPSHOT.

## The mechanism

An interactive action called from a **browser navigation** of the web server's
Action API opens its forms in the web client. Navigating a browser tab
(Playwright `page.goto()`, or the in-app pane's `navigate`) to

```
<base>/eval/action?script=<url-encoded action script>
```

makes the platform push the action as a *notification*: the server
302-redirects the tab to `/push-notification`, the service worker hands the
action to the app, and the tab lands back on `/main` with the form open —
exactly as if the user had opened it. The payload is ordinary action code, so
it is fully parameterizable — a named form, a form with bound objects, or the
edit card of one specific object:

```lsf
SHOW Shop.items DOCKED;
FOR Shop.name(Shop.Item i) = 'Coffee beans' DO SHOW EDIT Shop.Item = i DOCKED;
```

`SHOW EDIT <Class> = <obj>` opens the class edit form (the one declared with
`EDIT <Class> OBJECT <o>`, or the auto-generated one); `SHOW <form> OBJECTS
<o> = <expr>` opens any form with objects bound.

## Rules that make it work

- **Window mode: open the form the way production opens it — `DOCKED` for
  anything reachable from the navigator and for edit cards**, as in both
  examples. In this call context a bare `SHOW` is synchronous, which defaults
  to a small **floating** window — the rendered layout (column widths, flex
  fills, collapsed containers) then does not match what a user sees. `DOCKED`
  opens the form as a tab filling the forms panel. Keep `FLOAT` (or
  `EMBEDDED`/`POPUP`) only when the form genuinely opens that way in
  production (e.g. it is shown via `DIALOG` or `SHOW … FLOAT` in the code) —
  or, best of all, call the project action that opens the form: the window
  mode (plus filters and session state) comes along for free.
- **Visit `<base>` (or `/main`) once first, in the same browser context** —
  that registers the service worker which delivers the action. In a virgin
  context a direct hit sticks on `/push-notification` (worker not yet in
  control); one reload of the stuck page recovers. Then wait for `**/main*`
  and for the form's caption/selector with a generous timeout — the first open
  after a restart lazily builds the form (10–40 s).
- **Qualify names with namespaces** (`Shop.items`, not `items`) — the script
  compiles against *all* loaded modules, so bare names that are unique in your
  module are routinely ambiguous.
- **URL-encode the script** (`urllib.parse.quote`) — this also carries
  non-ASCII text safely (percent-encoded UTF-8, no argv/code-page issues).
- **A script error returns a 500 page with the server's compile error text**
  *instead of* the redirect — if the URL never leaves `/eval/action`, read the
  body: it is the exact error. Fix and re-run; nothing to screenshot-guess.
- **Auth gates.** Devmode auto-authenticates as admin — nothing to do. On a
  deployed install, log in first (same context); the call is then gated by
  `enableUI` on top of the usual `enableAPI` rules — admin /
  `System.interpreter` access for `/eval/action`, or an `@@api`-annotated
  action via `/exec?action=...&p=...` (same redirect mechanism).

## Where this runs

- **Local dev install:** don't hand-roll it — `lsfdev.ps1 verify -OpenScript
  "..."` (or `-OpenScriptFile`) does all of the above, with a screenshot and
  an `-OpenExpect` assertion (lsfusion-dev skill, step 5).
- **Remote / deployed hosts:** a Playwright script — lsfusion-eval skill,
  Part 3; the [playwright-remote.py](playwright-remote.py) template beside
  this file already handles login and waits.
- **In-app browser pane:** the same URL works after loading the base URL once
  in the pane; assert by reading the page (`get_page_text` / `read_page`)
  rather than by pre-declared text matchers.
