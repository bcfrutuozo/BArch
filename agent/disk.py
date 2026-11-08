#!/usr/bin/env python3
"""agent/disk.py: the local disks' health, from what barch-disk-health (root, hourly) dumped.

    barch disk status [--json]      the snapshot: every disk's SMART, every btrfs' error counters and
                                    last scrub, and the problems in one list
    python3 agent/disk.py problems  the problems alone (JSON list), for the bar's health check

The root script (`/usr/local/bin/barch-disk-health`, system/) writes
~/.local/state/barch/disk/health.json with the raw `smartctl -j`, `btrfs device stats` and
`btrfs scrub status -R` of each device; everything here is the parsing of that file. `summarize()`,
`metrics()` and `changes()` are pure and covered by agent/tests/test_disk.py; barch-events samples
them into metrics (smart.<disk>.*, btrfs.<fs>.*), events (disk.smart, disk.selftest, btrfs.errors,
btrfs.scrub) and the rules of agent/rules.json. smartd (failures) and btrfs-scrub-report (the
monthly scrub) keep notifying on their own; this adds the history and the lines before failure.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

HOME = Path(os.environ.get("HOME", "~")).expanduser()
HEALTH = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "barch/disk/health.json"
STALE_S = 3 * 3600          # the timer is hourly; older than this means it stopped running
SCRUB_MAX_DAYS = 45         # btrfs-scrub@-.timer is monthly (plus up to a week of random delay)
HOT_C = 70                  # an NVMe throttles around 80 °C; the rule in rules.json uses this too
BTRFS_COUNTERS = ("write_io_errs", "read_io_errs", "flush_io_errs", "corruption_errs", "generation_errs")
SCRUB_ERRORS = ("read_errors", "csum_errors", "verify_errors", "super_errors", "uncorrectable_errors", "corrected_errors")


def load(path: Path = HEALTH) -> dict | None:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _num(v, default=None):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def disk_name(dev: str) -> str:
    """/dev/nvme0 → nvme0, /dev/sda → sda."""
    return Path(dev).name


def fs_label(mount: str) -> str:
    return "root" if mount == "/" else Path(mount).name


def parse_scrub(text: str) -> dict:
    """`btrfs scrub status -R <mnt>`: the header lines ("Status:  finished") and the raw counters
    ("\\tcsum_errors: 0"). Pure text parsing; an empty text (never scrubbed, not root) gives {}."""
    out: dict = {}
    for line in (text or "").splitlines():
        m = re.match(r"^\s*([A-Za-z_ ]+?):\s*(.*)$", line)
        if not m:
            continue
        key, val = m.group(1).strip(), m.group(2).strip()
        if key.lower() == "scrub started":
            try:
                out["started"] = int(datetime.strptime(val, "%a %b %d %H:%M:%S %Y").timestamp())
            except ValueError:
                pass
        elif key.lower() == "status":
            out["status"] = val.lower()
        elif key.lower() == "duration":
            h, mi, s = (val.split(":") + ["0", "0"])[:3]
            out["duration_s"] = _num(h, 0) * 3600 + _num(mi, 0) * 60 + _num(s, 0)
        elif key.lower() == "error summary":
            out["summary"] = val
        elif re.fullmatch(r"[a-z_]+", key):
            n = _num(val)
            if n is not None:
                out[key] = int(n)
    if out:
        out["errors"] = sum(int(out.get(k, 0)) for k in SCRUB_ERRORS)
    return out


def summarize(raw: dict | None, now: float | None = None) -> dict:
    """The dump as the snapshot everything else reads. Pure: no I/O."""
    now = time.time() if now is None else now
    snap: dict = {"at": int((raw or {}).get("at") or 0), "disks": [], "btrfs": [], "problems": []}
    if not raw:
        snap["problems"].append("disk health never collected: install barch-disk-health (system/, needs sudo) and enable its timer")
        return snap
    snap["age_s"] = int(now - snap["at"])
    if snap["age_s"] > STALE_S:
        snap["problems"].append(f"disk health not collected for {snap['age_s'] // 3600} h: barch-disk-health.timer")
    for dev, s in sorted((raw.get("smart") or {}).items()):
        d: dict = {"dev": dev, "name": disk_name(dev), "model": s.get("model_name") or s.get("model_family") or "",
                   "passed": (s.get("smart_status") or {}).get("passed")}
        nv = s.get("nvme_smart_health_information_log") or {}
        if not nv and not s.get("ata_smart_attributes") and not s.get("smart_status"):
            # smartctl answered without the health data (not root, a device it cannot talk to)
            d["kind"] = "unknown"
            snap["problems"].append(f"{d['name']}: smartctl gave no SMART data (barch-disk-health has to run as root)")
            snap["disks"].append(d)
            continue
        if nv:
            d.update(kind="nvme", temp=_num(nv.get("temperature")), spare_pct=_num(nv.get("available_spare")),
                     wear_pct=_num(nv.get("percentage_used")), media_errors=int(_num(nv.get("media_errors"), 0)),
                     err_log=int(_num(nv.get("num_err_log_entries"), 0)), unsafe_shutdowns=int(_num(nv.get("unsafe_shutdowns"), 0)),
                     critical_warning=int(_num(nv.get("critical_warning"), 0)),
                     power_on_h=int(_num(nv.get("power_on_hours"), 0)),
                     written_tb=round(_num(nv.get("data_units_written"), 0) * 512000 / 1e12, 2))
        else:
            d["kind"] = "ata"
            d["temp"] = _num(((s.get("temperature") or {}).get("current")))
            attrs = {a.get("name"): a for a in ((s.get("ata_smart_attributes") or {}).get("table") or [])}

            def rawv(name):
                return int(_num(((attrs.get(name) or {}).get("raw") or {}).get("value"), 0))
            d.update(reallocated=rawv("Reallocated_Sector_Ct"), pending=rawv("Current_Pending_Sector"),
                     uncorrectable=rawv("Offline_Uncorrectable"), power_on_h=rawv("Power_On_Hours"),
                     wear_pct=_num(((attrs.get("Percent_Lifetime_Remain") or attrs.get("Wear_Leveling_Count") or {}).get("value"))))
            if d["wear_pct"] is not None:
                d["wear_pct"] = 100 - d["wear_pct"]      # those attributes count down from 100
            d["media_errors"] = d["reallocated"] + d["pending"] + d["uncorrectable"]
            d["critical_warning"] = 0
        tests = ((s.get("nvme_self_test_log") or {}).get("table") or (s.get("ata_smart_self_test_log") or {}).get("standard", {}).get("table") or [])
        last = tests[0] if tests else None
        if last:
            # NVMe: self_test_result {value, string}, 0 = passed; ATA: status {value, string, passed}
            st = last.get("self_test_result") or last.get("status") or {}
            passed = bool(st["passed"]) if "passed" in st else int(_num(st.get("value"), 0)) == 0
            d["selftest"] = {"passed": passed, "text": st.get("string", ""),
                             "power_on_h": int(_num(last.get("power_on_hours") or last.get("lifetime_hours"), 0))}
        if d["passed"] is False:
            snap["problems"].append(f"{d['name']}: SMART says the disk is failing")
        if d.get("critical_warning"):
            snap["problems"].append(f"{d['name']}: NVMe critical warning 0x{d['critical_warning']:02x}")
        if d.get("media_errors"):
            snap["problems"].append(f"{d['name']}: {d['media_errors']} media errors")
        if d.get("spare_pct") is not None and d["spare_pct"] < 50:
            snap["problems"].append(f"{d['name']}: spare blocks at {d['spare_pct']:.0f}%")
        if d.get("wear_pct") is not None and d["wear_pct"] >= 90:
            snap["problems"].append(f"{d['name']}: {d['wear_pct']:.0f}% of the rated endurance used")
        if d.get("temp") is not None and d["temp"] >= HOT_C:
            snap["problems"].append(f"{d['name']}: {d['temp']:.0f} °C")
        if d.get("selftest") and not d["selftest"]["passed"]:
            snap["problems"].append(f"{d['name']}: the last self-test failed ({d['selftest']['text']})")
        snap["disks"].append(d)
    for mount, b in sorted((raw.get("btrfs") or {}).items()):
        f: dict = {"mount": mount, "label": fs_label(mount), "uuid": b.get("uuid") or "", "devices": [], "errors": 0}
        for ds in ((b.get("stats") or {}).get("device-stats") or []):
            dd = {"device": ds.get("device", "")}
            for k in BTRFS_COUNTERS:
                dd[k] = int(_num(ds.get(k), 0))
            f["devices"].append(dd)
            f["errors"] += sum(dd[k] for k in BTRFS_COUNTERS)
        sc = parse_scrub(b.get("scrub") or "")
        f["scrub"] = sc
        if sc.get("started"):
            f["scrub_age_d"] = round((now - sc["started"]) / 86400, 1)
        if f["errors"]:
            snap["problems"].append(f"btrfs {f['label']}: {f['errors']} I/O or corruption errors counted (btrfs device stats {mount})")
        if sc.get("errors"):
            snap["problems"].append(f"btrfs {f['label']}: the last scrub found {sc['errors']} errors"
                                    + (f", {sc.get('uncorrectable_errors', 0)} uncorrectable" if sc.get("uncorrectable_errors") else ""))
        elif sc.get("status") in ("aborted", "interrupted"):
            snap["problems"].append(f"btrfs {f['label']}: the last scrub was {sc['status']}")
        if sc and f.get("scrub_age_d", 0) > SCRUB_MAX_DAYS:
            snap["problems"].append(f"btrfs {f['label']}: no scrub for {f['scrub_age_d']:.0f} days (btrfs-scrub@-.timer)")
        elif not sc and "scrub" in b:
            snap["problems"].append(f"btrfs {f['label']}: never scrubbed (sudo systemctl start btrfs-scrub@-.service)")
        snap["btrfs"].append(f)
    return snap


def metrics(s: dict) -> list[tuple[str, float]]:
    """smart.<disk>.temp / wear.pct / spare.pct / media_errors / err_log / unsafe_shutdowns / written_tb,
    btrfs.<fs>.errors / scrub.age_d / scrub.errors. Nothing for a snapshot without a dump."""
    rows: list[tuple[str, float]] = []

    def add(name, value):
        if value is not None:
            rows.append((name, float(value)))
    for d in s.get("disks", []):
        p = f"smart.{d['name']}."
        add(p + "temp", d.get("temp"))
        add(p + "wear.pct", d.get("wear_pct"))
        add(p + "spare.pct", d.get("spare_pct"))
        add(p + "media_errors", d.get("media_errors"))
        add(p + "err_log", d.get("err_log"))
        add(p + "unsafe_shutdowns", d.get("unsafe_shutdowns"))
        add(p + "written_tb", d.get("written_tb"))
    for f in s.get("btrfs", []):
        p = f"btrfs.{f['label']}."
        add(p + "errors", f.get("errors"))
        add(p + "scrub.age_d", f.get("scrub_age_d"))
        if f.get("scrub"):
            add(p + "scrub.errors", f["scrub"].get("errors", 0))
    return rows


def changes(s: dict, st: dict, now: float, scrub_max_days: float = SCRUB_MAX_DAYS) -> list[tuple[str, dict]]:
    """What the snapshot holds that `st` (kept by the caller between samples) has not reported yet,
    as (event, data) pairs, each with a one-line `text`:

      disk.smart     disk, model, text        SMART failing, a critical warning, or media errors that grew
      disk.selftest  disk, text               the newest self-test failed (once per test)
      btrfs.errors   fs, mount, text          a btrfs error counter grew (I/O, corruption, generation)
      btrfs.scrub    fs, mount, status, text  a scrub finished with errors or was aborted (once per run),
                                              or none ran for scrub_max_days (again every week)
    """
    out: list[tuple[str, dict]] = []
    disks = st.setdefault("disks", {})
    for d in s.get("disks", []):
        prev = disks.get(d["name"]) or {}
        cur = {"passed": d.get("passed"), "critical_warning": d.get("critical_warning", 0),
               "media_errors": d.get("media_errors", 0), "selftest_h": (d.get("selftest") or {}).get("power_on_h")}
        reasons = []
        if d.get("passed") is False and prev.get("passed") is not False:
            reasons.append("SMART says it is failing")
        if cur["critical_warning"] and cur["critical_warning"] != prev.get("critical_warning", 0):
            reasons.append(f"critical warning 0x{cur['critical_warning']:02x}")
        if prev and cur["media_errors"] > prev.get("media_errors", 0):
            reasons.append(f"media errors {prev.get('media_errors', 0)} → {cur['media_errors']}")
        if reasons:
            out.append(("disk.smart", {"disk": d["name"], "model": d.get("model", ""),
                                       "text": f"Disco {d['name']} ({d.get('model', '')}): " + ", ".join(reasons)}))
        stest = d.get("selftest")
        if stest and not stest["passed"] and stest.get("power_on_h") != prev.get("selftest_h"):
            out.append(("disk.selftest", {"disk": d["name"], "text": f"Disco {d['name']}: o último self-test falhou ({stest['text']})"}))
        disks[d["name"]] = cur
    fss = st.setdefault("btrfs", {})
    for f in s.get("btrfs", []):
        prev = fss.get(f["label"]) or {}
        sc = f.get("scrub") or {}
        cur = {"errors": f.get("errors", 0), "scrub_started": sc.get("started"), "overdue_said": prev.get("overdue_said", 0)}
        if prev and cur["errors"] > prev.get("errors", 0):
            out.append(("btrfs.errors", {"fs": f["label"], "mount": f["mount"],
                                         "text": f"btrfs {f['label']}: contadores de erro subiram de {prev.get('errors', 0)} para {cur['errors']}"}))
        if sc.get("started") and sc.get("started") != prev.get("scrub_started"):
            if sc.get("errors"):
                out.append(("btrfs.scrub", {"fs": f["label"], "mount": f["mount"], "status": sc.get("status", ""),
                                            "text": f"btrfs {f['label']}: o scrub encontrou {sc['errors']} erros"
                                                    + (f", {sc.get('uncorrectable_errors')} incorrigíveis" if sc.get("uncorrectable_errors") else "")}))
            elif sc.get("status") in ("aborted", "interrupted"):
                out.append(("btrfs.scrub", {"fs": f["label"], "mount": f["mount"], "status": sc["status"],
                                            "text": f"btrfs {f['label']}: o scrub foi interrompido ({sc['status']})"}))
        age = f.get("scrub_age_d")
        if age is not None and age > scrub_max_days and now - cur["overdue_said"] > 7 * 86400:
            cur["overdue_said"] = now
            out.append(("btrfs.scrub", {"fs": f["label"], "mount": f["mount"], "status": "overdue",
                                        "text": f"btrfs {f['label']}: sem scrub há {age:.0f} dias"}))
        fss[f["label"]] = cur
    return out


def text(s: dict) -> str:
    lines = []
    if s.get("at"):
        lines.append(f"collected {datetime.fromtimestamp(s['at']):%Y-%m-%d %H:%M}" + (f" ({s.get('age_s', 0) // 60} min ago)" if "age_s" in s else ""))
    for d in s.get("disks", []):
        bits = [f"SMART {'ok' if d.get('passed') else 'FAILING' if d.get('passed') is False else '?'}"]
        if d.get("temp") is not None:
            bits.append(f"{d['temp']:.0f} °C")
        if d.get("wear_pct") is not None:
            bits.append(f"wear {d['wear_pct']:.0f}%")
        if d.get("spare_pct") is not None:
            bits.append(f"spare {d['spare_pct']:.0f}%")
        bits.append(f"media errors {d.get('media_errors', 0)}")
        if d.get("kind") == "nvme":
            bits.append(f"error log {d.get('err_log', 0)} · unsafe shutdowns {d.get('unsafe_shutdowns', 0)} · {d.get('written_tb', 0)} TB written")
        bits.append(f"{d.get('power_on_h', 0)} h on")
        if d.get("selftest"):
            bits.append(f"self-test {'ok' if d['selftest']['passed'] else 'FAILED'} ({d['selftest']['text']})")
        lines.append(f"{d['name']}: {d.get('model', '')} · " + " · ".join(bits))
    for f in s.get("btrfs", []):
        sc = f.get("scrub") or {}
        scrub = "never" if not sc else (f"{sc.get('status', '?')} {datetime.fromtimestamp(sc['started']):%Y-%m-%d}" if sc.get("started") else sc.get("status", "?")) \
            + (f", {sc.get('errors', 0)} errors" if sc else "")
        lines.append(f"btrfs {f['label']} ({f['mount']}): {f.get('errors', 0)} errors counted · scrub {scrub}")
    lines.append("problems: " + ("none" if not s.get("problems") else "; ".join(s["problems"])))
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    sub = argv[0] if argv else "status"
    as_json = "--json" in argv
    s = summarize(load())
    if sub == "status":
        print(json.dumps(s, ensure_ascii=False, indent=2) if as_json else text(s))
        return 0 if not s["problems"] else 1
    if sub == "problems":
        print(json.dumps(s["problems"], ensure_ascii=False))
        return 0
    if sub == "metrics":
        print(json.dumps(metrics(s)))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
