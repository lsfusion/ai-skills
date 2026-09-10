"""
Reference: drive a deployed lsFusion install via Playwright.

This is a copy-and-adapt template for visually verifying a deployed lsFusion
server (any URL, local or remote, devmode ON or OFF).

Start with lsfusion-dev's `verify` (add `-Url <base> -User .. -Password ..`
for another host): it does the login, the direct form open, -Do steps,
assertions and disk artifacts in one run. Adapt this template only when that
wrapper is unavailable or cannot perform the operation - no set-up
lsfusion-dev project on this box, no Windows PowerShell, an untrusted HTTPS
certificate (this template passes ignore_https_errors=True), request /
response evidence, or programmatic branching and value-dependent steps that
a linear -Do chain cannot express. Needing screenshots, several forms, field
entry or intermediate assertions is NOT a reason - verify does those.

Prereqs:
- Python 3.9+
- `pip install "playwright>=1.51" && python -m playwright install chromium`
  (one-time; lsfusion-dev's verify installs playwright too, but an OLDER
  install needs `pip install -U "playwright>=1.51"`: open_detail_via_edit()
  uses Locator.filter(visible=True), added in 1.51)

Run:
    python playwright-remote.py
Output:
    ./screenshots/01-login.png, 02-navigator.png, ... (relative to the
    current working directory, not to this file)

The script is self-contained on purpose — adapt the URL, credentials, and
the `navigate_and_capture` body for whatever you want to verify.

Gotchas baked into this template (each one cost a debug cycle when I first
wrote it — leave them in):
- Login form uses platform-standard names `username` / `password`; the
  submit is `input[name="submit"][type="submit"]`.
- After clicking anything that opens a card, lsFusion paints a `Loading`
  overlay BEFORE the form renders. A naive `wait_for_timeout(2000)`
  screenshots the spinner; wait for the overlay to detach first.
- A double-click on a grid row is NOT "open the card": the platform decides
  per cell (editable -> in-place editor; read-only + class edit form -> the
  card; CHANGEMOUSE -> that action; CUSTOM -> whatever it renders). Open a
  card deterministically with `open_by_script()` (SHOW EDIT ... DOCKED), or
  select the row and click the form's own `Edit` toolbar action, scoped to
  that form (`open_detail_via_edit(page, form_sid=..., caption=...)`), and
  prove it with `visible_forms()` before/after.
- If a column you care about isn't on-screen (lsFusion grids scroll
  horizontally), focus the grid and press `End` a few times.
- Navigator items show a tooltip on hover (`sID:`, `Path:`) that LINGERS
  into the next screenshot. Click in empty space before each screenshot.
- UI strings are locale-dependent (en/pl/ru/...). The same install at the
  same URL may serve different languages to different users. Don't hardcode
  text matchers as the only way in — keep them as the first attempt, and
  fall back to CSS / role selectors when they break.
"""
import sys
from pathlib import Path
from urllib.parse import quote, urljoin
from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

# --- Adapt these for your target ----------------------------------------------
URL       = "https://<host>/"
USERNAME  = "admin"
PASSWORD  = ""                # platform default after fresh install
OUT_DIR   = Path("./screenshots")
VIEWPORT  = {"width": 1600, "height": 1000}
# ------------------------------------------------------------------------------

OUT_DIR.mkdir(exist_ok=True)


def shot(page, name):
    """Take a screenshot, print where it landed and how big it is."""
    path = OUT_DIR / name
    page.screenshot(path=str(path), full_page=False)
    print(f"  -> {path.name} ({path.stat().st_size // 1024} KB)")


def dismiss_tooltips(page):
    """Click in dead space so a lingering tooltip doesn't poison the next shot."""
    page.mouse.click(VIEWPORT["width"] // 2, VIEWPORT["height"] // 2)
    page.wait_for_timeout(200)


def try_click_text(page, text, exact=False, timeout=4000):
    """Click first element whose visible text contains `text`. Returns True on
    success — UI strings can be localized, so let the caller handle False."""
    try:
        page.get_by_text(text, exact=exact).first.click(timeout=timeout)
        return True
    except PWTimeout:
        return False


def login(page):
    """Standard lsFusion login form — `username` / `password` inputs and an
    `input[name="submit"]` button. If devmode is ON on the server there is no
    form and the inputs won't be found — return False so the caller can skip."""
    try:
        page.fill('input[name="username"]', USERNAME, timeout=4000)
        page.fill('input[name="password"]', PASSWORD, timeout=4000)
        page.click('input[name="submit"]', timeout=4000)
        page.wait_for_load_state("networkidle", timeout=30000)
        page.wait_for_timeout(2500)                 # SPA settle after auth
        return True
    except PWTimeout:
        return False                                # devmode ON — no form


def wait_loading(page, timeout=15000):
    """Wait for lsFusion's `Loading` overlay to detach, then for network idle
    and a final paint. The word may be localized — the try falls back to the
    fixed waits so the script still produces output (maybe of the spinner)."""
    try:
        page.wait_for_selector("text=Loading", state="detached", timeout=timeout)
    except PWTimeout:
        pass
    try:
        page.wait_for_load_state("networkidle", timeout=timeout)
    except PWTimeout:
        pass  # a live app (websocket, polling) may never go idle - not a failure
    page.wait_for_timeout(2000)  # final paint


def new_forms(before, after):
    """sIDs with MORE visible instances after than before - instance-aware,
    so a second window of a form that was already open (same sID) counts."""
    return [s for s in dict.fromkeys(after) if after.count(s) > before.count(s)]


def visible_forms(page):
    """sIDs of the forms on screen. Every form layout root carries
    lsfusion-form="<sID>" (the canonical name for named forms, _FORM_<n> for
    auto-generated EDIT/LIST forms); inactive docked forms stay in the DOM
    hidden, and a form nested inside another one (EMBEDDED) is content of its
    parent. Snapshot before and after an action to PROVE a form opened — a
    new sID is an opened form; a screenshot alone proves nothing."""
    return page.evaluate("""() => {
      const vis = el => { const r = el.getClientRects()[0];
                          const cs = getComputedStyle(el);
                          return !!r && r.width > 0.5 && r.height > 0.5 &&
                                 cs.visibility !== 'hidden' && cs.display !== 'none'; };
      const out = [];
      for (const el of document.querySelectorAll('[lsfusion-form]')) {
        if (el.parentElement && el.parentElement.closest('[lsfusion-form]')) continue;
        if (vis(el)) out.push(el.getAttribute('lsfusion-form') || '');
      }
      return out;
    }""")


def open_by_script(page, script, timeout=60000):
    """Open a form DIRECTLY: navigate to <base>/eval/action?script=<action>
    (form-open-url.md next to this file). The server pushes the action as a
    notification — 302 to /push-notification, the service worker (registered
    by the first visit of the base URL in this context) hands it to the app,
    the tab lands on /main with the form open, exactly as the user would see
    it. Parameterizable down to one object's edit card and independent of
    what any cell does on double-click:
        open_by_script(page, "FOR Shop.name(Shop.Item i) = 'Coffee beans' "
                             "DO SHOW EDIT Shop.Item = i DOCKED;")
    Use DOCKED (production layout) and namespace-qualified names. The page
    reloads, so forms opened earlier are gone; the app's beforeunload confirm
    is blocked by headless Chromium (no user gesture) — expected. A script
    error comes back as a 500 page instead of the redirect: its body is the
    compile error. Returns the sIDs of the forms on screen afterwards - an
    empty list means nothing rendered within the readiness window, so check
    it, don't just screenshot."""
    base = URL if URL.endswith("/") else URL + "/"
    page.goto(urljoin(base, "eval/action") + "?script=" + quote(script),
              wait_until="load", timeout=timeout)
    try:
        page.wait_for_url("**/main*", timeout=15000)
    except PWTimeout:
        if "/push-notification" in page.url:
            # virgin context: the worker was not yet in control — one reload
            page.reload(wait_until="load", timeout=timeout)
            page.wait_for_url("**/main*", timeout=30000)
        else:
            # still on /eval/action — the script failed, the body says why
            raise RuntimeError("open_by_script: " + page.inner_text("body")[:400])
    # the first open of a form after a restart builds it lazily (10–40 s);
    # readiness = a visible form root, not network idle (a live app may
    # never go idle)
    wait_loading(page, timeout=45000)
    try:
        page.wait_for_selector("[lsfusion-form]", state="visible", timeout=45000)
    except PWTimeout:
        pass
    return visible_forms(page)


def open_detail_via_edit(page, form_sid=None, caption="Edit", within=None):
    """Open the card of the row currently selected in a grid through the
    form's own `Edit` toolbar action (the EDIT property of that form).
    form_sid scopes the search to that form's layout root
    ([lsfusion-form="<sID>"]) so another form's button is never clicked;
    within= narrows it further to a selector INSIDE the form (a form with
    several grids has several Edit actions - the first one is not "the"
    one). caption is the action's VISIBLE, localized caption ('Edit',
    'Редактировать', 'Edytuj', ...) — read it off a screenshot, don't assume
    English; it must match EXACTLY ('Edit settings' is not 'Edit') and
    UNIQUELY among the visible controls of the scope — two matches raise
    instead of guessing. Prefer open_by_script() when the card is all you
    need: no row selection, no captions, no dependence on the grid. Returns
    the sIDs of the forms that appeared (instance-aware)."""
    before = visible_forms(page)
    scope = page.locator(f'[lsfusion-form="{form_sid}"]') if form_sid else page
    if within:
        scope = scope.locator(within)
    # role-based: native <button>s and button-like divs alike, by exact
    # accessible name - no localized caption interpolated into a selector.
    # One strict, UNINDEXED locator: its count is validated and the same
    # locator is clicked, so a button that appears between the check and the
    # click makes Playwright's strict mode refuse instead of clicking the
    # wrong one (an indexed .all()[0] would silently drift).
    # filter(visible=True) needs Playwright >= 1.51 (see Prereqs).
    btn = scope.get_by_role("button", name=caption, exact=True).filter(visible=True)
    if btn.count() == 0:
        btn = scope.get_by_text(caption, exact=True).filter(visible=True)
    n = btn.count()
    if n != 1:
        raise RuntimeError(
            f"open_detail_via_edit: {n} visible '{caption}' controls in "
            f"scope (form_sid={form_sid!r}, within={within!r}) - narrow the scope "
            "with within=<container selector> or pass the exact localized caption; "
            "nothing was clicked")
    btn.click(timeout=3000)   # strict: refuses if it no longer resolves to one
    wait_loading(page)
    opened = new_forms(before, visible_forms(page))
    if not opened:
        print(f"  !! '{caption}' clicked but no new form is on screen — wrong "
              "caption or scope? read the screenshot, don't trust the click")
    return opened


def scroll_grid_right(page, anchor_text, times=15):
    """Bring right-side grid columns into view. Pass any visible cell value
    as the anchor for the focus click."""
    try:
        page.get_by_text(anchor_text, exact=True).first.click()
        for _ in range(times):
            page.keyboard.press("End")
            page.wait_for_timeout(120)
        page.wait_for_timeout(500)
    except PWTimeout:
        pass


def navigate_and_capture():
    """Adapt this body for the verification you care about. The pattern is
    always: click a navigator entry -> wait -> screenshot. lsFusion's
    top-level tabs ('Master data', 'Inventory', ...) gate the sidebar,
    so click the right tab first."""
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context(viewport=VIEWPORT, ignore_https_errors=True)
        page = ctx.new_page()

        print(f"[1] open {URL}")
        page.goto(URL, wait_until="networkidle", timeout=30000)
        page.wait_for_timeout(1500)
        shot(page, "01-login.png")

        print(f"[2] login {USERNAME!r}")
        if login(page):
            print("  logged in")
        else:
            print("  no login form (devmode is ON?)")
        shot(page, "02-navigator.png")

        # ------- everything below is project-specific; adapt freely ----------
        print("[3] Master data -> Items")
        try_click_text(page, "Master data")
        page.wait_for_timeout(500)
        if try_click_text(page, "Items"):
            page.wait_for_timeout(2500)
            dismiss_tooltips(page)
            shot(page, "03-items-list.png")

            # Reveal right-side columns (a custom attribute added via
            # EXTEND FORM, for example) by scrolling End a few times.
            anchor_cell = "<visible row label>"  # ← any cell value you can see in the list
            scroll_grid_right(page, anchor_cell)
            shot(page, "03b-items-list-rightcols.png")

            print("[4] open one item card")
            # Route A — the list form's own Edit action, scoped to that form
            # (its sID, e.g. 'Shop.items') and its localized caption; add
            # within='<container selector>' when the form has several grids:
            page.get_by_text(anchor_cell, exact=True).first.click()
            page.wait_for_timeout(300)
            opened = open_detail_via_edit(page, form_sid="<Module.listForm>", caption="Edit")
            # Route B — no gesture at all, the card by object (parameterized):
            #   opened = open_by_script(page, "FOR Shop.name(Shop.Item i) = "
            #       "'<visible row label>' DO SHOW EDIT Shop.Item = i DOCKED;")
            print(f"  forms opened: {opened}")
            shot(page, "04-item-detail.png")
            page.keyboard.press("Escape")
            page.wait_for_timeout(800)
        # ---------------------------------------------------------------------

        browser.close()


if __name__ == "__main__":
    try:
        navigate_and_capture()
    except Exception as e:
        print(f"FAILED: {e}", file=sys.stderr)
        sys.exit(1)
    print("done")
