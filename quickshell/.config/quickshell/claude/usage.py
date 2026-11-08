#!/usr/bin/env python3
"""Claude usage for the bar (claude/ClaudeUsage.qml) and `barch claude`: what `/usage` shows in Claude Code,
read the same way it reads it, plus what this machine's agents spent.

    usage.py [--refresh]      JSON on stdout; cached for CACHE_S seconds in ~/.local/state/barch/claude-usage.json

The plan's limits come from Anthropic's OAuth usage endpoint (the one Claude Code calls for /usage), with the
access token of the Claude Code login in ~/.claude/.credentials.json: a five-hour session window, the week,
and the week's share of the top model ("Fable" today), each as a percentage with its reset time; the plan
(`subscriptionType` + `rateLimitTier`: "Max 5x"); the breakdown by surface (Claude Code, chats...); extra
usage (credits) when enabled. The token is never printed and never refreshed here: Claude Code refreshes it
whenever it runs, and this only reads. An expired token (nothing ran Claude for a long while) is reported as
such. The agents' spend is the sum of ~/.local/state/barch/claude-cost.log (every scheduled task, voice
fallback and music/video agent run writes a line: ts source usd note), today and this week.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = Path.home()
STATE = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state") / "barch"
CACHE = STATE / "claude-usage.json"
CREDS = HOME / ".claude/.credentials.json"
COST_LOG = STATE / "claude-cost.log"
URL = "https://api.anthropic.com/api/oauth/usage"
CACHE_S = 60
TIERS = {"default_claude_max_5x": "Max 5x", "default_claude_max_20x": "Max 20x", "default_claude_pro": "Pro",
         "default_claude_team": "Team", "default_claude_enterprise": "Enterprise"}


def plan_label(sub: str, tier: str) -> str:
    if tier in TIERS:
        return TIERS[tier]
    if sub:
        return sub.capitalize() + (f" ({tier})" if tier else "")
    return tier or "?"


def fetch(creds: dict) -> dict:
    req = urllib.request.Request(URL, headers={"Authorization": f"Bearer {creds['accessToken']}",
                                               "anthropic-beta": "oauth-2025-04-20", "User-Agent": "barch-claude-usage/1.0"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode())


def limit_view(x: dict) -> dict:
    kind = x.get("kind", "")
    scope = ((x.get("scope") or {}).get("model") or {}).get("display_name") or ((x.get("scope") or {}).get("surface") or {}).get("display_name")
    label = {"session": "Session", "weekly_all": "Week"}.get(kind) or scope or kind
    resets = x.get("resets_at") or ""
    try:
        left = int((datetime.fromisoformat(resets) - datetime.now(timezone.utc)).total_seconds())
    except ValueError:
        left = None
    return {"kind": kind, "label": label, "scope": scope or "", "percent": x.get("percent"), "severity": x.get("severity", ""),
            "resets_at": resets, "resets_in_s": left, "is_active": bool(x.get("is_active"))}


def agents_spend() -> dict:
    """Today's and this week's cost of the agents on this machine, from claude-cost.log (ts source usd note)."""
    out = {"today_usd": 0.0, "week_usd": 0.0, "runs_today": 0, "by_source_today": {}, "last": None}
    if not COST_LOG.exists():
        return out
    now = datetime.now()
    day0 = now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    week0 = (now - timedelta(days=now.weekday())).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    try:
        lines = COST_LOG.read_text(errors="replace").splitlines()[-5000:]
    except OSError:
        return out
    for line in lines:
        parts = line.split(" ", 3)
        if len(parts) < 3:
            continue
        try:
            ts, usd = float(parts[0]), float(parts[2])
        except ValueError:
            continue
        src = parts[1]
        if ts >= week0:
            out["week_usd"] += usd
        if ts >= day0:
            out["today_usd"] += usd
            out["runs_today"] += 1
            out["by_source_today"][src] = round(out["by_source_today"].get(src, 0.0) + usd, 4)
        out["last"] = {"t": ts, "source": src, "usd": usd, "note": parts[3] if len(parts) > 3 else ""}
    out["today_usd"], out["week_usd"] = round(out["today_usd"], 4), round(out["week_usd"], 4)
    return out


def build() -> dict:
    now = time.time()
    out: dict = {"ok": False, "at": now, "error": "", "plan": {}, "token": {}, "limits": [], "session": None, "week": None,
                 "scoped": [], "breakdown": [], "extra_usage": None, "agents": agents_spend()}
    if not CREDS.exists():
        out["error"] = "no Claude Code login (~/.claude/.credentials.json missing)"
        return out
    try:
        creds = json.loads(CREDS.read_text()).get("claudeAiOauth") or {}
    except (OSError, json.JSONDecodeError) as e:
        out["error"] = f"credentials unreadable: {e}"
        return out
    sub, tier = creds.get("subscriptionType", ""), creds.get("rateLimitTier", "")
    out["plan"] = {"type": sub, "tier": tier, "label": plan_label(sub, tier)}
    exp = float(creds.get("expiresAt") or 0) / 1000
    out["token"] = {"expires_at": exp, "expired": bool(exp) and exp < now}
    if not creds.get("accessToken"):
        out["error"] = "no access token in the Claude Code login"
        return out
    try:
        d = fetch(creds)
    except urllib.error.HTTPError as e:
        out["error"] = ("the token expired: run claude once to refresh it" if e.code in (401, 403)
                        else f"usage endpoint: HTTP {e.code}")
        return out
    except Exception as e:  # noqa: BLE001 - offline, DNS, timeout
        out["error"] = f"usage endpoint: {type(e).__name__}: {e}"
        return out
    limits = [limit_view(x) for x in d.get("limits") or [] if isinstance(x, dict)]
    if not limits:   # older shape: five_hour / seven_day only
        for kind, key in (("session", "five_hour"), ("weekly_all", "seven_day")):
            v = d.get(key) or {}
            if v:
                limits.append(limit_view({"kind": kind, "percent": v.get("utilization"), "resets_at": v.get("resets_at")}))
    shares = {s.get("limit_index"): s for s in d.get("weekly_scoped_shares") or [] if isinstance(s, dict)}
    for i, lim in enumerate(limits):
        if i in shares:
            lim["used_percent_of_weekly"] = shares[i].get("used_percent_of_weekly")
            lim["allowance_percent_of_weekly"] = shares[i].get("allowance_percent_of_weekly")
    out["limits"] = limits
    out["session"] = next((x for x in limits if x["kind"] == "session"), None)
    out["week"] = next((x for x in limits if x["kind"] == "weekly_all"), None)
    out["scoped"] = [x for x in limits if x["kind"] not in ("session", "weekly_all")]
    out["breakdown"] = [{"name": r.get("display_name") or r.get("key"), "percent": r.get("percent")}
                        for r in ((d.get("seven_day_breakdown") or {}).get("rows") or []) if r.get("percent")]
    eu = d.get("extra_usage") or {}
    out["extra_usage"] = {"enabled": bool(eu.get("is_enabled")), "used": eu.get("used_credits"), "limit": eu.get("monthly_limit"),
                          "currency": eu.get("currency", ""), "utilization": eu.get("utilization")} if eu else None
    out["ok"] = True
    return out


def main(argv: list[str]) -> int:
    refresh = "--refresh" in argv
    if not refresh and CACHE.exists():
        try:
            cached = json.loads(CACHE.read_text())
            if cached.get("ok") and time.time() - float(cached.get("at") or 0) < CACHE_S:
                cached["agents"] = agents_spend()
                print(json.dumps(cached, ensure_ascii=False))
                return 0
        except (OSError, json.JSONDecodeError, ValueError):
            pass
    out = build()
    if out["ok"]:
        try:
            CACHE.parent.mkdir(parents=True, exist_ok=True)
            tmp = CACHE.with_suffix(".tmp")
            tmp.write_text(json.dumps(out, ensure_ascii=False))
            tmp.replace(CACHE)
        except OSError:
            pass
    print(json.dumps(out, ensure_ascii=False))
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
