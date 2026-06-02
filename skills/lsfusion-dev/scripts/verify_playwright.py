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
import sys
import time
from pathlib import Path

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
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="")
    ap.add_argument("--timeout", type=int, default=30000,
                    help="navigation timeout in ms")
    args = ap.parse_args()

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    login_png    = out_dir / "verify-login.png"
    app_png      = out_dir / "verify-app.png"
    dom_path     = out_dir / "verify-dom.html"
    console_path = out_dir / "verify-console.txt"

    # Wipe previous artefacts so callers can rely on file presence.
    for p in (login_png, app_png, dom_path, console_path):
        if p.exists():
            p.unlink()

    result = {
        "url": args.url,
        "title": "",
        "logged_in": False,
        "login_attempted": False,
        "console_errors": 0,
        "error": None,
        "artifacts": {
            "login_screenshot": str(login_png),
            "app_screenshot":   str(app_png),
            "dom":              str(dom_path),
            "console":          str(console_path),
        },
    }
    console_lines: list[str] = []

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            try:
                context = browser.new_context(viewport={"width": 1366, "height": 900})
                page = context.new_page()
                page.on("console", lambda m: console_lines.append(f"[{m.type}] {m.text}"))

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
                dom_path.write_text(page.content(), encoding="utf-8")

            finally:
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
