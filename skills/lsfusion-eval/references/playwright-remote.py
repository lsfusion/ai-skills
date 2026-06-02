"""
Reference: drive a deployed lsFusion install via Playwright.

This is a copy-and-adapt template for visually verifying a deployed lsFusion
server (any URL, local or remote, devmode ON or OFF). Use it when:

- the lsfusion-dev `verify` command isn't enough — it's local-only and takes
  a single landing screenshot;
- you need to prove to a human (not just yourself) that a feature looks
  right end-to-end on the deployed app — screenshots of the actual rendered
  UI are unambiguous in a way that API counts are not.

Prereqs:
- Python 3.9+
- `pip install playwright && python -m playwright install chromium`
  (one-time; lsfusion-dev's verify does the same install if you ran it before)

Run:
    python playwright-remote.py
Output:
    ./screenshots/01-login.png, 02-navigator.png, ...

The script is self-contained on purpose — adapt the URL, credentials, and
the `navigate_and_capture` body for whatever you want to verify.

Gotchas baked into this template (each one cost a debug cycle when I first
wrote it — leave them in):
- Login form uses platform-standard names `username` / `password`; the
  submit is `input[name="submit"][type="submit"]`.
- After clicking anything that opens a card, lsFusion paints a `Loading`
  overlay BEFORE the form renders. A naive `wait_for_timeout(2000)`
  screenshots the spinner; wait for the overlay to detach first.
- Grid rows do NOT open the detail card on double-click. Click the row to
  select it, then click the `Edit` toolbar button at the bottom-right.
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


def open_detail_via_edit(page):
    """Open the detail card for whatever row is currently selected in a grid.
    lsFusion does NOT respond to double-click — the canonical action is the
    'Edit' button in the form's bottom toolbar. Waits for the 'Loading'
    overlay to detach before returning."""
    # Try button selectors first (more specific), then a text fallback
    clicked = False
    for sel in ['button:has-text("Edit")', 'div[role="button"]:has-text("Edit")']:
        btn = page.locator(sel).first
        if btn.count() > 0:
            btn.click(timeout=3000)
            clicked = True
            break
    if not clicked:
        page.get_by_text("Edit", exact=True).last.click(timeout=3000)

    # Wait for the loading overlay to vanish. The text 'Loading' may itself
    # be localized — wrap in a try and fall back to a generous fixed wait.
    try:
        page.wait_for_selector("text=Loading", state="detached", timeout=15000)
    except PWTimeout:
        pass
    page.wait_for_load_state("networkidle", timeout=15000)
    page.wait_for_timeout(2000)  # final paint


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
            page.get_by_text(anchor_cell, exact=True).first.click()
            page.wait_for_timeout(300)
            open_detail_via_edit(page)
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
