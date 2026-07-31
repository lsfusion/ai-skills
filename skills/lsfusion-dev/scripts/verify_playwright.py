#!/usr/bin/env python3
"""Playwright-based visual verification of the lsFusion web client.

Drives a headless Chromium: screenshots the landing / login page, attempts to
log in with the supplied credentials, screenshots the authenticated UI, dumps
the final DOM and the browser console, then writes everything to
``--output-dir``.

A JSON summary is printed on stdout so the calling PowerShell script can
report on it. Used by lsfdev.ps1's `verify` command.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from urllib.parse import quote, urljoin

try:
    from playwright.sync_api import (
        sync_playwright,
        Error as PWError,
        TimeoutError as PWTimeout,
    )
except ImportError:
    print(json.dumps({"error": "playwright module is not installed"}))
    sys.exit(2)


# Buttons tried in order to submit the login form. The lsFusion web client
# typically renders a single visible button on the login screen; the fallback
# selectors and an Enter-press cover translated captions and variations.
SUBMIT_SELECTORS = [
    'button[type="submit"]:visible',
    'input[type="submit"]:visible',
    'button:visible',
]

# Console [error] lines that are environmental noise from headless Chromium, not
# faults in the lsFusion app. They are still written to verify-console.txt for
# transparency, but excluded from the error count so verify doesn't cry wolf.
BENIGN_CONSOLE_SUBSTRINGS = (
    # Chrome refuses the Push API in incognito (headless uses an incognito-like
    # context); emitted on every run regardless of the app. https://crbug.com/41124656
    "does not support the Push API in incognito",
    # Navigating away from the app (e.g. to the /eval/action URL of
    # --open-script-file) triggers the SPA's beforeunload confirm, which
    # headless Chromium blocks for lack of a user gesture. Expected.
    "beforeunload' confirmation panel",
)


def _split_pos(spec: str):
    """Split 'selector@x,y' into (selector, {'x':..,'y':..}) — offset from the
    element's top-left corner. Plain 'selector' returns (selector, None). The
    LAST '@' followed by two numbers wins, so attribute selectors containing
    '@' stay intact."""
    m = re.match(r"^(.+)@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)$", spec.strip())
    if m and m.group(1).strip():
        return m.group(1).strip(), {"x": float(m.group(2)), "y": float(m.group(3))}
    return spec.strip(), None


def _resolve_visible(page, sel: str, timeout_ms: int = 15000):
    """Resolve a --do selector to its first VISIBLE match.

    ``locator(sel).first`` acts on the first match in DOM order, hidden or
    not — and the lsFusion web client keeps full duplicate toolbars/forms in
    the DOM for every docked-but-inactive tab, so a selector like
    ``button:has-text("Save")`` routinely matches an invisible copy first
    and the click times out with no hint. ``.locator("visible=true")`` is
    Playwright's FILTERING engine (measured: filters the matched set itself
    — including visibility:hidden — rather than descending into children),
    so the visible subset is computed with no match cap and no per-element
    round-trips. Returns ``(locator, note)`` where note reports skipped
    hidden duplicates (``"3 matched, 1 visible - using the first visible"``).
    Raises ValueError when matches exist but every one is hidden, or when
    nothing matches; a selector that cannot be parsed re-raises Playwright's
    own error (three strikes, so transient mid-navigation evaluation
    failures don't) — the parse message beats a misleading
    "matched nothing" after a silent 15 s wait.
    """
    loc = page.locator(sel)
    vis = loc.locator("visible=true")
    deadline = time.time() + timeout_ms / 1000
    n = 0
    bad = 0
    while True:
        try:
            n = loc.count()
            if n:
                nv = vis.count()
                if nv:
                    note = ""
                    if n > 1:
                        note = f"{n} matched, {nv} visible - using the first visible"
                    return vis.first, note
            bad = 0
        except PWError:
            bad += 1
            if bad >= 3:
                raise
        if time.time() >= deadline:
            break
        page.wait_for_timeout(250)
    if n:
        raise ValueError(
            f"{sel!r} matched {n} element(s) but none is visible - likely "
            "hidden duplicates (e.g. toolbars/forms of other docked tabs "
            "kept in the DOM); scope the selector (append :visible, or "
            "prefix a container) or close the other tabs")
    raise ValueError(f"{sel!r} matched nothing within {timeout_ms} ms")


def _any_visible(loc) -> bool:
    """True when at least one of the locator's matches is visible.
    Uses the visible=true filtering engine — no match cap."""
    try:
        return loc.locator("visible=true").count() > 0
    except PWError:
        return False


# --open-expect fallback: text inside <input>/<textarea>/<select> is an
# element VALUE, not a text node, so text locators never see it — a healthy
# settings form full of inputs used to report "NOT found" on the very value
# it displayed. Checks visible form controls' values (and the selected
# option's label) for a case-insensitive substring match. Visibility mirrors
# Playwright's: a real box AND not visibility:hidden (which keeps its layout
# rect, so a rect check alone would pass hidden inputs of inactive forms).
_INPUT_VALUE_JS = """
(needle) => {
  const n = (needle || '').toLowerCase();
  const vis = el => { const r = el.getClientRects()[0];
                      const cs = getComputedStyle(el);
                      return !!r && r.width > 0.5 && r.height > 0.5 &&
                             cs.visibility !== 'hidden' && cs.display !== 'none'; };
  for (const el of document.querySelectorAll('input, textarea, select')) {
    if (!vis(el)) continue;
    let v = '' + (el.value == null ? '' : el.value);
    if (el.tagName === 'SELECT' && el.selectedOptions && el.selectedOptions.length)
      v = v + ' ' + (el.selectedOptions[0].label || '');
    if (v.toLowerCase().includes(n)) return true;
  }
  return false;
}
"""


def _wait_expect(page, expect: str, timeout_ms: int = 45000) -> str:
    """Wait for --open-expect text as visible text OR a visible input's
    value. Returns 'text' / 'input-value' / '' (not found)."""
    deadline = time.time() + timeout_ms / 1000
    while True:
        if _any_visible(page.get_by_text(expect)):
            return "text"
        try:
            if page.evaluate(_INPUT_VALUE_JS, expect):
                return "input-value"
        except PWError:
            pass
        if time.time() >= deadline:
            return ""
        page.wait_for_timeout(800)


# edit:<caption>=><value> target lookup. The platform's own wiring makes the
# caption → cell hop exact: every panel caption is a .panel-property-label
# whose for= attribute is the id of its value cell
# (PropertyPanelRenderer.initCaption sets both). Whitespace-normalized exact
# match first, then substring; visible labels only.
_PANEL_CELL_JS = """
(caption) => {
  const norm = s => (s || '').replace(/\\s+/g, ' ').trim();
  const target = norm(caption);
  const vis = el => { const r = el.getClientRects()[0];
                      const cs = getComputedStyle(el);
                      return !!r && r.width > 0.5 && r.height > 0.5 &&
                             cs.visibility !== 'hidden' && cs.display !== 'none'; };
  const labels = [...document.querySelectorAll('.panel-property-label')].filter(vis);
  const hit = labels.find(l => norm(l.textContent) === target)
           || labels.find(l => norm(l.textContent).includes(target));
  if (!hit) return null;
  const id = hit.getAttribute('for');
  return id ? document.getElementById(id) : null;
}
"""

# Failure-time diagnostics for edit:: the captions that CAN be targeted.
_PANEL_CAPTIONS_JS = """
() => {
  const norm = s => (s || '').replace(/\\s+/g, ' ').trim();
  const vis = el => { const r = el.getClientRects()[0];
                      const cs = getComputedStyle(el);
                      return !!r && r.width > 0.5 && r.height > 0.5 &&
                             cs.visibility !== 'hidden' && cs.display !== 'none'; };
  return [...new Set([...document.querySelectorAll('.panel-property-label')]
      .filter(vis).map(l => norm(l.textContent)).filter(Boolean))];
}
"""

# dnd:<from>=><to> — the HTML5 drag-and-drop PROTOCOL, as opposed to drag:'s
# raw mouse gesture. Components built on dragstart/dragover/drop (kanban
# boards, sortable lists, drop zones — anything draggable="true") never see
# a mouse-event drag: a native drag suppresses mousemove delivery, so such
# components speak DragEvent only. The whole sequence shares ONE live
# DataTransfer, so whatever the component's dragstart handler setData()s is
# readable in its drop handler — the part ad-hoc dispatches get wrong.
# pointerdown/mousedown fire first because SortableJS-style libraries arm
# the drag (set draggable, bind handlers) on mousedown; the trailing
# pointerup/mouseup releases that arm (synthetic dispatch never generates a
# click). Returns diagnostics: whether dragover was preventDefault()ed — a
# real browser fires drop ONLY then, so false means a live user drag would
# not drop here — and the DataTransfer types the dragstart handler set.
_DND_JS = """
async ([src, dst, sx, sy, dx, dy]) => {
  const settle = ms => new Promise(r => setTimeout(r, ms));
  const dt = new DataTransfer();
  const drag = (el, type, x, y) => {
    const ev = new DragEvent(type, {bubbles: true, cancelable: true,
                                    composed: true, view: window,
                                    clientX: x, clientY: y, dataTransfer: dt});
    el.dispatchEvent(ev);
    return ev.defaultPrevented;
  };
  const mouse = (el, ctor, type, x, y, buttons) =>
    el.dispatchEvent(new ctor(type, {bubbles: true, cancelable: true,
                                     composed: true, view: window,
                                     clientX: x, clientY: y,
                                     button: 0, buttons: buttons}));
  mouse(src, PointerEvent, 'pointerdown', sx, sy, 1);
  mouse(src, MouseEvent, 'mousedown', sx, sy, 1);
  await settle(50);
  drag(src, 'dragstart', sx, sy);
  await settle(50);
  drag(src, 'drag', sx, sy);
  drag(dst, 'dragenter', dx, dy);
  let prevented = drag(dst, 'dragover', dx, dy);
  await settle(50);
  prevented = drag(dst, 'dragover', dx, dy) || prevented;
  const types = [...dt.types];
  drag(dst, 'drop', dx, dy);
  drag(src, 'dragend', dx, dy);
  mouse(dst, PointerEvent, 'pointerup', dx, dy, 0);
  mouse(dst, MouseEvent, 'mouseup', dx, dy, 0);
  return {prevented: prevented, types: types};
}
"""


def _classify_click_error(msg: str):
    """Classify a failed Playwright click from its timeout message.

    The message embeds the whole actionability call log, which distinguishes
    three very different situations that used to be reported identically:
    the text matched nothing ('not_found'), the element was found but another
    element swallowed the pointer ('intercepted' — loading glass, sliding
    panel, hover popup), or the element exists with its text CSS-hidden
    ('not_visible' — e.g. an icon-only navbar entry, whose caption lives in
    textContent but not on screen). Returns (reason, blocked_by) where
    blocked_by is the intercepting element's printed form when known."""
    if "locator resolved to" not in msg:
        return "not_found", ""
    if "intercepts pointer events" in msg:
        hits = re.findall(r"-\s+(<.+>)\s+intercepts pointer events", msg)
        return "intercepted", (hits[-1] if hits else "")
    if "element is not visible" in msg:
        return "not_visible", ""
    return "actionability", ""


# Captions an agent can actually target with --click, harvested from the live
# page the moment a click fails. A caption counts as clickable-by-text only
# if the node a text locator would resolve — the INNERMOST element carrying
# the caption — has a real on-screen box: icon-only navbar entries keep the
# caption in the DOM inside a zero-sized/hidden div (measured: 'Administration'
# in the system navbar), so get_by_text() resolves them and the click then
# dies on "element is not visible". Listing those under icon_only explains
# that failure instead of leaving it a mystery.
_NAV_CAPTIONS_JS = """
() => {
  const acc = {visible: [], icon_only: []};
  for (const a of document.querySelectorAll('a.navbar-text')) {
    const caption = (a.textContent || '').replace(/\\s+/g, ' ').trim();
    if (!caption) continue;
    let el = a;
    for (const n of a.querySelectorAll('*')) {
      if (!n.children.length &&
          (n.textContent || '').replace(/\\s+/g, ' ').trim() === caption) {
        el = n;
        break;
      }
    }
    const r = el.getClientRects()[0];
    const cs = getComputedStyle(el);
    const vis = !!r && r.width > 0.5 && r.height > 0.5 &&
                cs.visibility !== 'hidden' && cs.display !== 'none';
    (vis ? acc.visible : acc.icon_only).push(caption);
  }
  const visible = [...new Set(acc.visible)];
  return {visible: visible,
          icon_only: [...new Set(acc.icon_only)].filter(t => !visible.includes(t))};
}
"""


def _collect_navigator(page):
    """Visible / icon-only navigator captions from the live page ({} lists on
    any evaluation error — never let diagnostics kill the run)."""
    try:
        got = page.evaluate(_NAV_CAPTIONS_JS)
        if isinstance(got, dict):
            return {"visible": [str(t) for t in (got.get("visible") or [])],
                    "icon_only": [str(t) for t in (got.get("icon_only") or [])]}
    except PWError:
        pass
    return {"visible": [], "icon_only": []}


def _acquire_session(p, port: int, args, out_dir: Path):
    """Connect to (or spawn) a persistent headless Chromium on a CDP port.

    The browser is spawned DETACHED, so it outlives this script: the page —
    navigation state, the open form, JS globals — persists between verify
    invocations. lsfdev kills it via the pw-session.pid file (verify
    -EndSession, or any stop/restart). Returns (browser, page, navigated_hint)
    where navigated_hint says whether the page was newly created."""
    endpoint = f"http://127.0.0.1:{port}"

    def _alive() -> bool:
        try:
            urllib.request.urlopen(f"{endpoint}/json/version", timeout=1).read()
            return True
        except OSError:
            return False

    if not _alive():
        exe = p.chromium.executable_path
        profile = out_dir / "pw-session-profile"
        flags = (getattr(subprocess, "DETACHED_PROCESS", 0)
                 | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
        proc = subprocess.Popen(
            [exe, "--headless=new", f"--remote-debugging-port={port}",
             "--remote-debugging-address=127.0.0.1",
             f"--user-data-dir={profile}",
             "--no-first-run", "--no-default-browser-check",
             f"--window-size={args.viewport_width},{args.viewport_height}",
             "about:blank"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=flags, start_new_session=True)
        (out_dir / "pw-session.pid").write_text(str(proc.pid), encoding="ascii")
        deadline = time.time() + 15
        while time.time() < deadline and not _alive():
            time.sleep(0.3)
        if not _alive():
            raise PWError(f"spawned session browser did not open CDP port {port}")

    browser = p.chromium.connect_over_cdp(endpoint)
    # Reuse the spawn's default context; creating a fresh context here would
    # get cleared again on disconnect (Playwright closes contexts IT created).
    ctx = browser.contexts[0] if browser.contexts else browser.new_context()
    page = None
    base = args.url.split("#")[0].rstrip("/")
    for pg in ctx.pages:
        if pg.url.split("#")[0].rstrip("/").startswith(base):
            page = pg
            break
    fresh = page is None
    if fresh:
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
    try:
        page.set_viewport_size({"width": args.viewport_width,
                                "height": args.viewport_height})
    except PWError:
        pass
    # Disable the HTTP cache for as long as this invocation is attached: the
    # persistent profile (unlike a throwaway context) has a real disk cache,
    # and platform statics (/static/**, GWT *.cache.js) are served cacheable
    # for a day+. Devmode app resources are no-store anyway, but this makes
    # session runs match throwaway runs in caching semantics, so a stale
    # asset can never masquerade as an app bug. The flag is per CDP session
    # and drops on detach - re-applied here on every attach, which covers
    # every window in which navigations happen.
    try:
        cdp = ctx.new_cdp_session(page)
        cdp.send("Network.enable")
        cdp.send("Network.setCacheDisabled", {"cacheDisabled": True})
    except PWError:
        pass
    return browser, page, fresh


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="")
    ap.add_argument("--timeout", type=int, default=30000,
                    help="navigation timeout in ms")
    ap.add_argument("--open-script-file", default="",
                    help="path to a UTF-8 file with an lsFusion action script "
                         "(e.g. \"SHOW myForm DOCKED;\" - DOCKED renders the "
                         "form as a tab like in production); after landing, "
                         "navigate to <base>/eval/action?script=... - the "
                         "platform routes the interactive action back into "
                         "the web client and the form opens without touching "
                         "the navigator")
    ap.add_argument("--open-expect", default="",
                    help="with --open-script-file: wait for this text before "
                         "the screenshot - matched as visible text OR as a "
                         "visible input's value (form fields hold text in "
                         "the value attribute, not in a text node)")
    ap.add_argument("--click", default="",
                    help="after landing, click element(s) by visible text and "
                         "screenshot the result; chain with '>' for tab-then-"
                         "entry navigation, e.g. \"Master data > Items\"")
    ap.add_argument("--double-click", default="",
                    help="after the click-through, double-click a grid row by "
                         "visible text to open its edit card, then screenshot "
                         "it; e.g. \"Coffee beans\"")
    ap.add_argument("--do", dest="do_actions", action="append", default=[],
                    help="generic interaction step, run in order AFTER the "
                         "--click/--double-click navigation; repeatable. "
                         "Forms: click:<selector>, dblclick:<selector>, "
                         "hover:<selector>, drag:<selector>=><selector> "
                         "(raw mouse gesture: mousedown/mousemove/mouseup - "
                         "drag-to-draw UIs), dnd:<selector>=><selector> "
                         "(HTML5 drag-and-drop: DragEvents sharing one live "
                         "DataTransfer - kanban/sortable components listening "
                         "dragstart/drop; a component speaks one protocol or "
                         "the other), mouse:down|up|move@x,y[,steps], "
                         "fill:<selector>=><value>, type:<selector>=><value>, "
                         "edit:<panel caption or selector>=><value> (lsFusion "
                         "in-place editor: dblclick the cell, type, Enter), "
                         "press:<key>, eval:<js>, wait:<ms>. <selector> is any "
                         "Playwright selector (css, text=..., :has-text(...)), "
                         "which is what reaches buttons/inputs inside CUSTOM "
                         "(React) components that the text-based --click "
                         "cannot hit; selectors resolve to the first VISIBLE "
                         "match (hidden docked-tab duplicates are skipped and "
                         "reported); hover/drag/dnd/click selectors accept an "
                         "@x,y offset from the element's top-left corner")
    ap.add_argument("--do-file", default="",
                    help="UTF-8 file with a JSON array of --do steps. The "
                         "robust transport for steps carrying quotes/spaces "
                         "(JS, attribute selectors): PowerShell 5.1's native "
                         "argv quoting corrupts some quote/space patterns, a "
                         "file cannot be corrupted. Used by lsfdev.ps1 -Do")
    ap.add_argument("--session-port", type=int, default=0,
                    help="reuse (or spawn) a persistent headless Chromium on "
                         "this CDP port instead of launching a throwaway "
                         "browser: the page - navigation state, open form, JS "
                         "globals - survives between invocations. 0 = off")
    ap.add_argument("--reload", action="store_true",
                    help="session mode: navigate to the target URL even when "
                         "the page is already on the app. A page load is what "
                         "picks up JS/CSS edits in devmode (resources are "
                         "served no-store under a content-hash ?version=, so "
                         "an ordinary reload always fetches fresh bytes) - but "
                         "it also boots a new server-side navigator, closing "
                         "open forms. No-op without --session-port (a "
                         "throwaway browser always navigates).")
    ap.add_argument("--viewport-width", type=int, default=1920)
    ap.add_argument("--viewport-height", type=int, default=1080)
    ap.add_argument("--locale", default="",
                    help="browser context locale, e.g. ru-RU (affects browser-"
                         "side language negotiation)")
    args = ap.parse_args()

    if args.do_file:
        loaded = json.loads(Path(args.do_file).read_text(encoding="utf-8-sig"))
        if isinstance(loaded, str):
            loaded = [loaded]
        args.do_actions = [str(s) for s in loaded] + args.do_actions

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    login_png    = out_dir / "verify-login.png"
    app_png      = out_dir / "verify-app.png"
    open_png     = out_dir / "verify-open.png"
    click_png    = out_dir / "verify-click.png"
    dblclick_png = out_dir / "verify-dblclick.png"
    do_png       = out_dir / "verify-do.png"
    dom_path     = out_dir / "verify-dom.html"
    console_path = out_dir / "verify-console.txt"

    # Wipe previous artefacts so callers can rely on file presence.
    for p in (login_png, app_png, open_png, click_png, dblclick_png, do_png, dom_path, console_path):
        if p.exists():
            p.unlink()

    open_script = ""
    if args.open_script_file:
        try:
            open_script = Path(args.open_script_file).read_text(encoding="utf-8-sig").strip()
        except OSError as e:
            print(json.dumps({"error": f"cannot read --open-script-file: {e}"}))
            return 2

    result = {
        "url": args.url,
        "title": "",
        "logged_in": False,
        "login_attempted": False,
        "console_errors": 0,
        "error": None,
        "open": {
            "requested": bool(open_script),
            "script": open_script,
            "landed_url": "",
            "reloaded": False,
            "expect": args.open_expect.strip(),
            "expect_found": False,
            "expect_where": "",   # text | input-value
            "error": None,
        },
        "click": {
            "requested": bool(args.click.strip()),
            "clicked": [],
            "error": None,
            "failed_segment": "",
            "reason": None,        # not_found | intercepted | not_visible | actionability
            "blocked_by": "",      # intercepting element (reason == intercepted)
            "forced": [],          # segments that needed click(force=True)
            "available": None,     # {visible: [...], icon_only: [...]} on failure
        },
        "double_click": {
            "requested": bool(args.double_click.strip()),
            "target": "",
            "error": None,
            "reason": None,
            "blocked_by": "",
            "forced": False,
        },
        "do": {
            "requested": bool(args.do_actions),
            "steps": [],
            "error": None,
        },
        "session": {
            "requested": bool(args.session_port),
            "navigated": True,
        },
        "artifacts": {
            "login_screenshot":    str(login_png),
            "app_screenshot":      str(app_png),
            "open_screenshot":     str(open_png),
            "click_screenshot":    str(click_png),
            "dblclick_screenshot": str(dblclick_png),
            "do_screenshot":       str(do_png),
            "dom":                 str(dom_path),
            "console":             str(console_path),
        },
    }
    console_lines: list[str] = []
    # Set when a click/double-click failure dumps the DOM: the caption list in
    # the report points at verify-dom.html as the FAILURE-TIME DOM, so the
    # end-of-run dump must not clobber it with post -Do/-DoubleClick state.
    dom_failure_dumped = False

    try:
        with sync_playwright() as p:
            page = None
            if args.session_port:
                # Persistent-session mode: attach to the long-lived browser
                # (spawning it on first use). NOTE: --locale has no effect
                # here - the context already exists.
                browser, page, _ = _acquire_session(p, args.session_port,
                                                    args, out_dir)
            else:
                browser = p.chromium.launch(headless=True)
            try:
                if page is None:
                    # 1920x1080 default: narrower viewports (e.g. 1366x900) make
                    # dense forms (calendars, wide grids) collapse into "+N more"
                    # placeholders and the screenshot looks broken when the app is
                    # fine. Override with --viewport-width/--viewport-height.
                    ctx_kwargs = {
                        "viewport": {"width": args.viewport_width,
                                     "height": args.viewport_height},
                    }
                    if args.locale.strip():
                        ctx_kwargs["locale"] = args.locale.strip()
                    context = browser.new_context(**ctx_kwargs)
                    page = context.new_page()
                page.on("console", lambda m: console_lines.append(f"[{m.type}] {m.text}"))

                # In session mode a page that is already anywhere on the app is
                # continued as-is - no reload, so the open form / JS state from
                # the previous invocation survives and -Do steps pick up where
                # the last call left off. "On the app" means the base URL
                # itself OR /main under it: the web client stays at the base
                # URL after the welcome-file forward, but lands on /main after
                # an --open-script-file run - both are the live SPA, and a
                # goto() would boot a new server-side navigator and close every
                # open form. Anything else (about:blank of a fresh spawn,
                # /login, a stuck /eval/action error page, a foreign site) is
                # not a continuable app page and is navigated away from.
                # --reload forces the navigation (that is how JS/CSS edits are
                # picked up; devmode serves them fresh on every page load).
                def _on_app_page(cur: str, base: str) -> bool:
                    cur = cur.split("#")[0]
                    if not cur.startswith(base):
                        return False
                    rest = cur[len(base):].lstrip("/")
                    return (rest == "" or rest.startswith("?")
                            or rest.split("?")[0].rstrip("/") == "main")

                already_there = bool(
                    args.session_port
                    and not args.reload
                    and _on_app_page(page.url, args.url.split("#")[0].rstrip("/")))
                if already_there:
                    result["session"]["navigated"] = False
                else:
                    try:
                        page.goto(args.url, wait_until="load", timeout=args.timeout)
                    except PWError as e:
                        result["error"] = f"navigation failed: {e}"
                        return _finish(result, console_lines, console_path)

                    # Give the SPA a moment to settle before the first screenshot.
                    try:
                        page.wait_for_load_state("networkidle", timeout=10000)
                    except PWTimeout:
                        pass

                result["title"] = page.title()
                page.screenshot(path=str(login_png))

                # If a password field is visible we treat the page as a login
                # form and try to authenticate; otherwise we skip straight to
                # the second screenshot (already-authenticated / non-login page).
                if page.locator('input[type="password"]:visible').count() > 0:
                    result["login_attempted"] = True
                    try:
                        text_in = page.locator('input[type="text"]:visible').first
                        text_in.wait_for(timeout=5000)
                        text_in.fill(args.user)
                        if args.password:
                            page.locator('input[type="password"]:visible').first.fill(args.password)

                        clicked = False
                        for sel in SUBMIT_SELECTORS:
                            try:
                                page.locator(sel).first.click(timeout=2000)
                                clicked = True
                                break
                            except PWError:
                                continue
                        if not clicked:
                            text_in.press("Enter")

                        try:
                            page.wait_for_load_state("networkidle", timeout=15000)
                        except PWTimeout:
                            pass
                        # Even with networkidle, the SPA may still be wiring up
                        # the navigator UI - give it a small extra beat.
                        time.sleep(2)

                        still_login = page.locator('input[type="password"]:visible').count() > 0
                        result["logged_in"] = not still_login
                    except PWError as e:
                        result["error"] = f"login flow failed: {e}"

                page.screenshot(path=str(app_png))

                # Optional direct form open. Navigating the tab to
                # <base>/eval/action?script=<SHOW ...> runs the script as an
                # interactive action: the platform pushes a notification,
                # 302-redirects to /push-notification, and the service worker
                # (registered by the app page we just landed on) navigates the
                # tab back to /main where the pending action executes and the
                # form opens - no navigator clicking, and the script can bind
                # objects (e.g. FOR ... DO SHOW EDIT Class = o). If the tab
                # sticks on /push-notification (service worker not yet in
                # control - happens in a virgin profile), one reload fixes it:
                # the first visit activated the worker, the reloaded page is
                # controlled.
                if result["open"]["requested"]:
                    base = args.url if args.url.endswith("/") else args.url + "/"
                    eval_url = urljoin(base, "eval/action") + "?script=" + quote(open_script)
                    try:
                        page.goto(eval_url, wait_until="load", timeout=args.timeout)
                        try:
                            page.wait_for_url("**/main*", timeout=15000)
                        except PWTimeout:
                            if "/push-notification" in page.url:
                                result["open"]["reloaded"] = True
                                page.reload(wait_until="load", timeout=args.timeout)
                                page.wait_for_url("**/main*", timeout=30000)
                            else:
                                # still on /eval/action - the script failed;
                                # let the outer handler capture the error body
                                raise
                        # Same generous settle as the click-through: the first
                        # open of a form after a restart is lazy and slow.
                        try:
                            page.wait_for_selector("text=Loading", state="detached", timeout=60000)
                        except PWTimeout:
                            pass
                        try:
                            page.wait_for_load_state("networkidle", timeout=30000)
                        except PWTimeout:
                            pass
                        page.wait_for_timeout(2500)
                        if result["open"]["expect"]:
                            # Visible text first, input VALUES as a fallback:
                            # "15" sitting in a settings-form field is an
                            # input value, not a text node, and must not
                            # report NOT-found on a healthy form.
                            where = _wait_expect(page, result["open"]["expect"])
                            result["open"]["expect_found"] = bool(where)
                            result["open"]["expect_where"] = where
                    except (PWTimeout, PWError) as e:
                        if "/eval/action" in page.url:
                            # No redirect happened: the script failed and the
                            # response body is the server error text.
                            body = ""
                            try:
                                body = page.inner_text("body")[:600]
                            except PWError:
                                pass
                            result["open"]["error"] = f"script error: {body or e}"
                        elif "/push-notification" in page.url:
                            result["open"]["error"] = (
                                "stuck on /push-notification even after a reload - "
                                "the service worker did not deliver the action to the app")
                        else:
                            result["open"]["error"] = f"open flow failed: {e}"
                    result["open"]["landed_url"] = page.url
                    page.screenshot(path=str(open_png))

                # Optional click-through: navigate to a specific form by the
                # visible text of navigator entries ('>' chains tab -> entry),
                # with generous waits - the FIRST open of a form after a
                # restart takes 10-40 s while the server lazily builds it.
                if result["click"]["requested"]:
                    segments = [s.strip() for s in args.click.split(">") if s.strip()]
                    seg = ""
                    try:
                        for seg in segments:
                            # Exact match first. Only a not_found falls back to
                            # the substring locator (captions carry counters /
                            # whitespace); once a locator RESOLVED an element,
                            # classification and the force fallback stay on
                            # that same locator — a substring retry could hit a
                            # different element that merely contains the text.
                            clicked = False
                            forced = False
                            reason, blocked_by = "", ""
                            last_err = None
                            for exact in (True, False):
                                loc = page.get_by_text(seg, exact=exact).first
                                try:
                                    loc.click(timeout=10000)
                                    clicked = True
                                    break
                                except (PWTimeout, PWError) as e:
                                    last_err = e
                                    reason, blocked_by = _classify_click_error(str(e))
                                    if reason == "not_found":
                                        continue
                                    if reason == "intercepted":
                                        # Element found and visible, but
                                        # something (loading glass, sliding
                                        # panel, hover popup) sat on top
                                        # through the whole retry window. Last
                                        # resort: force the click — skips the
                                        # hit-target check only. It may be a
                                        # no-op if the overlay really swallows
                                        # events, so the caller is told the
                                        # click was forced and should trust
                                        # the screenshot, not the click report.
                                        try:
                                            loc.click(timeout=3000, force=True)
                                            clicked = True
                                            forced = True
                                        except (PWTimeout, PWError) as e2:
                                            last_err = e2
                                    break
                            if not clicked:
                                result["click"]["failed_segment"] = seg
                                result["click"]["reason"] = reason
                                result["click"]["blocked_by"] = blocked_by
                                raise last_err
                            if forced:
                                result["click"]["forced"].append(seg)
                            result["click"]["clicked"].append(seg)
                            page.wait_for_timeout(700)
                            # A navigator click can fire a server round-trip
                            # (folder select, lazy form build) whose loading
                            # overlay would intercept the NEXT segment's click.
                            # Give it a bounded settle before moving on.
                            try:
                                page.wait_for_load_state("networkidle", timeout=3000)
                            except PWTimeout:
                                pass
                        # The 'Loading' overlay may be localized - treat the
                        # wait as best-effort, then settle on networkidle.
                        try:
                            page.wait_for_selector("text=Loading", state="detached", timeout=60000)
                        except PWTimeout:
                            pass
                        try:
                            page.wait_for_load_state("networkidle", timeout=30000)
                        except PWTimeout:
                            pass
                        page.wait_for_timeout(2500)
                    except (PWTimeout, PWError) as e:
                        result["click"]["error"] = f"click on {seg!r} failed: {e}"
                        if result["click"]["reason"] is None:
                            result["click"]["reason"], result["click"]["blocked_by"] = \
                                _classify_click_error(str(e))
                        # Failure-time captions are the ground truth for "what
                        # CAN be clicked" - hand them to the caller so a wrong
                        # caption guess dies here, not after a PNG round-trip.
                        result["click"]["available"] = _collect_navigator(page)
                        try:
                            dom_path.write_text(page.content(), encoding="utf-8")
                            dom_failure_dumped = True
                        except PWError:
                            pass
                    page.screenshot(path=str(click_png))

                # Optional double-click: open a grid row's edit card by the
                # visible text of any cell in that row, then screenshot it. Runs
                # after the click-through, so -Click opens the list form and
                # -DoubleClick opens a specific card from it. The first card
                # open is lazy - reuse the same generous waits as the click-
                # through.
                if result["double_click"]["requested"]:
                    dbl = args.double_click.strip()
                    try:
                        # Same locator discipline as the click-through: exact
                        # first, substring only when the exact text matched
                        # NOTHING (cell text carries surrounding whitespace),
                        # classification and the force fallback act on the
                        # locator that actually resolved.
                        done = False
                        last_err = None
                        reason, blocked_by = "", ""
                        for exact in (True, False):
                            loc = page.get_by_text(dbl, exact=exact).first
                            try:
                                loc.dblclick(timeout=10000)
                                done = True
                                break
                            except (PWTimeout, PWError) as e:
                                last_err = e
                                reason, blocked_by = _classify_click_error(str(e))
                                if reason == "not_found":
                                    continue
                                if reason == "intercepted":
                                    try:
                                        loc.dblclick(timeout=3000, force=True)
                                        done = True
                                        result["double_click"]["forced"] = True
                                    except (PWTimeout, PWError) as e2:
                                        # keep the interception classification;
                                        # the force error text alone would
                                        # re-classify as not_found.
                                        last_err = e2
                                break
                        if not done:
                            result["double_click"]["reason"] = reason
                            result["double_click"]["blocked_by"] = blocked_by
                            raise last_err
                        result["double_click"]["target"] = dbl
                        page.wait_for_timeout(700)
                        try:
                            page.wait_for_selector("text=Loading", state="detached", timeout=60000)
                        except PWTimeout:
                            pass
                        try:
                            page.wait_for_load_state("networkidle", timeout=30000)
                        except PWTimeout:
                            pass
                        page.wait_for_timeout(2500)
                    except (PWTimeout, PWError) as e:
                        result["double_click"]["error"] = f"double-click on {dbl!r} failed: {e}"
                        if result["double_click"]["reason"] is None:
                            result["double_click"]["reason"], result["double_click"]["blocked_by"] = \
                                _classify_click_error(str(e))
                        if not dom_failure_dumped:
                            try:
                                dom_path.write_text(page.content(), encoding="utf-8")
                                dom_failure_dumped = True
                            except PWError:
                                pass
                    page.screenshot(path=str(dblclick_png))

                # Optional generic interaction steps (--do, repeatable): the
                # escape hatch for anything the text-based navigation above
                # cannot reach - buttons/inputs inside CUSTOM (React)
                # components, filters, dialogs. Each step is "verb:rest" with
                # any Playwright selector; steps run in order and the chain
                # stops at the first failure (later steps usually depend on
                # earlier ones). A screenshot is taken after the chain either
                # way.
                if result["do"]["requested"]:
                    # Last known pointer position (viewport coords). Needed to
                    # interpolate mouse:move / drag paths ourselves: a single
                    # CDP move with steps=N gets COALESCED into 1-2 DOM
                    # mousemove events whenever the page's main thread is busy,
                    # which starves drag-to-draw handlers (Gantt links etc.) of
                    # the intermediate points they need. Dispatching each
                    # waypoint with a small settle guarantees DOM delivery.
                    pointer = {"x": None, "y": None}

                    def _loc_point(loc, pos):
                        box = loc.bounding_box()
                        if not box:
                            return None
                        return (box["x"] + (pos["x"] if pos else box["width"] / 2),
                                box["y"] + (pos["y"] if pos else box["height"] / 2))

                    def _glide(tx: float, ty: float, steps: int = 12):
                        sx, sy = pointer["x"], pointer["y"]
                        if sx is None or steps <= 1:
                            page.mouse.move(tx, ty)
                            page.wait_for_timeout(60)
                        else:
                            for i in range(1, steps + 1):
                                page.mouse.move(sx + (tx - sx) * i / steps,
                                                sy + (ty - sy) * i / steps)
                                page.wait_for_timeout(25)
                        pointer["x"], pointer["y"] = tx, ty

                    for raw in args.do_actions:
                        step = {"action": raw, "ok": False, "detail": ""}
                        result["do"]["steps"].append(step)
                        try:
                            verb, _, rest = raw.partition(":")
                            verb = verb.strip().lower()
                            if verb in ("click", "dblclick", "hover"):
                                sel, pos = _split_pos(rest)
                                loc, note = _resolve_visible(page, sel)
                                if note:
                                    step["detail"] = note
                                kw = {"timeout": 15000}
                                if pos:
                                    kw["position"] = pos
                                if verb == "click":
                                    loc.click(**kw)
                                elif verb == "dblclick":
                                    loc.dblclick(**kw)
                                else:
                                    loc.hover(**kw)
                                try:
                                    pt = _loc_point(loc, pos)
                                    if pt:
                                        pointer["x"], pointer["y"] = pt
                                except PWError:
                                    pass
                                if verb != "hover":
                                    page.wait_for_timeout(500)
                            elif verb == "drag":
                                # Real mouse gesture - mousedown, intermediate
                                # mousemoves, mouseup - which is what
                                # drag-to-draw UIs (Gantt dependency links,
                                # resize handles) listen for; an HTML5
                                # drag-and-drop emulation would never reach
                                # their mousemove handlers.
                                if "=>" not in rest:
                                    raise ValueError(
                                        "drag needs 'drag:<from>=><to>' "
                                        "(selectors, optional @x,y offsets)")
                                src, dst = rest.split("=>", 1)
                                ssel, spos = _split_pos(src)
                                dsel, dpos = _split_pos(dst)
                                sloc, snote = _resolve_visible(page, ssel)
                                dloc, dnote = _resolve_visible(page, dsel)
                                notes = [x for x in (snote, dnote) if x]
                                if notes:
                                    step["detail"] = "; ".join(notes)
                                dloc.scroll_into_view_if_needed(timeout=15000)
                                skw = {"timeout": 15000}
                                if spos:
                                    skw["position"] = spos
                                sloc.hover(**skw)
                                spt = _loc_point(sloc, spos)
                                if spt:
                                    pointer["x"], pointer["y"] = spt
                                page.wait_for_timeout(100)
                                page.mouse.down()
                                page.wait_for_timeout(100)
                                dpt = _loc_point(dloc, dpos)
                                if not dpt:
                                    page.mouse.up()
                                    raise ValueError(
                                        f"drag target {dsel!r} has no bounding box")
                                _glide(dpt[0], dpt[1], steps=12)
                                page.wait_for_timeout(100)
                                page.mouse.up()
                                page.wait_for_timeout(500)
                            elif verb == "dnd":
                                # The HTML5 drag-and-drop protocol - real
                                # DragEvents sharing one live DataTransfer -
                                # for kanban boards / sortable lists / drop
                                # zones listening dragstart/dragover/drop.
                                # drag: above speaks the OTHER protocol (raw
                                # mouse events); a component understands one
                                # or the other, so when drag: visibly does
                                # nothing on a draggable UI, use this.
                                if "=>" not in rest:
                                    raise ValueError(
                                        "dnd needs 'dnd:<from>=><to>' "
                                        "(selectors, optional @x,y offsets)")
                                src, dst = rest.split("=>", 1)
                                ssel, spos = _split_pos(src)
                                dsel, dpos = _split_pos(dst)
                                sloc, snote = _resolve_visible(page, ssel)
                                dloc, dnote = _resolve_visible(page, dsel)
                                notes = [x for x in (snote, dnote) if x]
                                sloc.scroll_into_view_if_needed(timeout=15000)
                                dloc.scroll_into_view_if_needed(timeout=15000)
                                spt = _loc_point(sloc, spos)
                                dpt = _loc_point(dloc, dpos)
                                if not spt:
                                    raise ValueError(
                                        f"dnd source {ssel!r} has no bounding box")
                                if not dpt:
                                    raise ValueError(
                                        f"dnd target {dsel!r} has no bounding box")
                                res = page.evaluate(
                                    _DND_JS,
                                    [sloc.element_handle(timeout=15000),
                                     dloc.element_handle(timeout=15000),
                                     spt[0], spt[1], dpt[0], dpt[1]])
                                detail = (
                                    "html5 dnd dispatched; dataTransfer types="
                                    + (str(res["types"]) if res["types"]
                                       else "[] (dragstart handler set no data)"))
                                if not res["prevented"]:
                                    detail += (
                                        "; dragover was NOT preventDefault()ed"
                                        " - a real browser would refuse this"
                                        " drop (target may not be a drop zone)")
                                notes.append(detail)
                                step["detail"] = "; ".join(notes)
                                page.wait_for_timeout(500)
                            elif verb == "mouse":
                                # Raw primitives for fully manual gestures:
                                # mouse:move@x,y[,steps], mouse:down[@x,y],
                                # mouse:up[@x,y] (viewport coordinates; down/up
                                # with @x,y move there first). Settles after
                                # each primitive keep hand-rolled sequences
                                # reliable (see the coalescing note above).
                                action, _, coords = rest.partition("@")
                                action = action.strip().lower()
                                nums = ([c.strip() for c in coords.split(",") if c.strip()]
                                        if coords else [])
                                if action == "move":
                                    if len(nums) < 2:
                                        raise ValueError("mouse:move needs @x,y[,steps]")
                                    steps = int(float(nums[2])) if len(nums) > 2 else 12
                                    _glide(float(nums[0]), float(nums[1]),
                                           steps=max(1, steps))
                                elif action in ("down", "up"):
                                    if len(nums) >= 2:
                                        page.mouse.move(float(nums[0]), float(nums[1]))
                                        pointer["x"], pointer["y"] = float(nums[0]), float(nums[1])
                                        page.wait_for_timeout(100)
                                    getattr(page.mouse, action)()
                                else:
                                    raise ValueError(
                                        "mouse supports down / up / move@x,y[,steps]")
                                page.wait_for_timeout(100)
                            elif verb in ("fill", "type"):
                                # Selector/value split: prefer the unambiguous
                                # '=>'; fall back to the LAST '=' (CSS attribute
                                # selectors like [name="x"] contain '=' too).
                                if "=>" in rest:
                                    sel, _, value = rest.partition("=>")
                                else:
                                    sel, _, value = rest.rpartition("=")
                                sel = sel.strip()
                                if not sel:
                                    raise ValueError(
                                        "no selector in fill/type step - use "
                                        "fill:<selector>=><value>")
                                loc, note = _resolve_visible(page, sel)
                                if note:
                                    step["detail"] = note
                                if verb == "fill":
                                    loc.fill(value)
                                else:
                                    # 'type' presses real keys - for React-style
                                    # inputs that ignore programmatic value sets.
                                    loc.click(timeout=15000)
                                    if hasattr(loc, "press_sequentially"):
                                        loc.press_sequentially(value, delay=30)
                                    else:  # older Playwright
                                        loc.type(value, delay=30)
                            elif verb == "edit":
                                # Platform-level in-place edit:
                                #   edit:<panel caption>=><value>
                                # (or a Playwright selector of the cell). The
                                # lsFusion in-place editor has NO <input> until
                                # the cell is focused, so fill:/type: cannot
                                # reach it and a blind dblclick@x,y is
                                # viewport-fragile. Recipe: find the value cell
                                # (caption → its label's for= id, the
                                # platform's own wiring), dblclick to open the
                                # editor, select-all, type, Enter.
                                if "=>" not in rest:
                                    raise ValueError(
                                        "edit needs 'edit:<caption or "
                                        "selector>=><value>'")
                                tgt, _, value = rest.partition("=>")
                                tgt = tgt.strip()
                                if not tgt:
                                    raise ValueError(
                                        "no caption/selector in edit step - "
                                        "use edit:<caption>=><value>")
                                cell = None
                                try:
                                    h = page.evaluate_handle(_PANEL_CELL_JS, tgt)
                                    cell = h.as_element()
                                except PWError:
                                    cell = None
                                if cell is None:
                                    # Not a known panel caption - try it as a
                                    # selector (grid cells, custom components).
                                    try:
                                        cell, note = _resolve_visible(
                                            page, tgt, timeout_ms=3000)
                                        if note:
                                            step["detail"] = note
                                    except (PWError, ValueError):
                                        caps = []
                                        try:
                                            caps = page.evaluate(_PANEL_CAPTIONS_JS)
                                        except PWError:
                                            pass
                                        raise ValueError(
                                            f"no panel cell with caption {tgt!r} "
                                            "(and it does not resolve as a "
                                            "selector). Editable panel captions "
                                            "on this page: "
                                            + (", ".join(caps) if caps else "(none)"))
                                else:
                                    try:
                                        cell.scroll_into_view_if_needed(timeout=5000)
                                    except PWError:
                                        pass
                                # Open the editor; one retry - right after a
                                # form open the first dblclick can land while
                                # the cell is still wiring up.
                                editor = None
                                for _ in range(2):
                                    cell.dblclick(timeout=15000)
                                    page.wait_for_timeout(400)
                                    editor = page.evaluate(
                                        "() => { const a = document.activeElement;"
                                        " if (!a) return null;"
                                        " const t = a.tagName.toLowerCase();"
                                        " if (t === 'input' || t === 'textarea'"
                                        "     || t === 'select') return t;"
                                        " if (a.isContentEditable)"
                                        "   return 'contenteditable';"
                                        " return null; }")
                                    if editor:
                                        break
                                    page.wait_for_timeout(800)
                                if not editor:
                                    raise ValueError(
                                        "double-click did not open an in-place "
                                        "editor (read-only cell? an action "
                                        "property? wrong cell?) - nothing was "
                                        "typed")
                                # Replace, not append: select-all first. In a
                                # contenteditable Ctrl+A selects the editable
                                # root's content, same effect as in an input;
                                # only <select> (keyboard option matching)
                                # must skip it.
                                if editor != "select":
                                    page.keyboard.press("Control+a")
                                page.keyboard.type(value, delay=30)
                                page.keyboard.press("Enter")
                                page.wait_for_timeout(400)
                                prev = step["detail"]
                                step["detail"] = (
                                    (prev + "; " if prev else "")
                                    + f"edited via <{editor}> in-place editor")
                            elif verb == "press":
                                page.keyboard.press(rest.strip())
                            elif verb == "eval":
                                # Expression or '() => {...}' function body; the
                                # value comes back in the step detail.
                                step["detail"] = repr(page.evaluate(rest))
                            elif verb == "wait":
                                page.wait_for_timeout(int(rest.strip() or "500"))
                            else:
                                raise ValueError(
                                    f"unknown verb {verb!r} - use click/dblclick/"
                                    "hover/drag/dnd/mouse/fill/type/edit/press/"
                                    "eval/wait")
                            step["ok"] = True
                        except (PWTimeout, PWError, ValueError) as e:
                            step["detail"] = str(e).split("\n")[0]
                            result["do"]["error"] = f"step {raw!r} failed"
                            break
                    try:
                        page.wait_for_load_state("networkidle", timeout=15000)
                    except PWTimeout:
                        pass
                    page.wait_for_timeout(800)
                    page.screenshot(path=str(do_png))

                if not dom_failure_dumped:
                    dom_path.write_text(page.content(), encoding="utf-8")

            finally:
                # For a session (connect_over_cdp) browser this only
                # DISCONNECTS - the spawned Chromium keeps running with the
                # page intact, ready for the next invocation. A throwaway
                # (launched) browser is actually closed.
                browser.close()
    except PWError as e:
        result["error"] = f"playwright error: {e}"

    return _finish(result, console_lines, console_path)


def _finish(result: dict, console_lines: list[str], console_path: Path) -> int:
    console_path.write_text("\n".join(console_lines), encoding="utf-8")
    result["console_errors"] = sum(
        1 for l in console_lines
        if l.startswith("[error]")
        and not any(b in l for b in BENIGN_CONSOLE_SUBSTRINGS)
    )
    print(json.dumps(result, indent=2))
    return 0 if not result["error"] else 1


if __name__ == "__main__":
    sys.exit(main())
