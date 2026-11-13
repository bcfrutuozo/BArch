"""agent/events.py: the rules engine (matching, hysteresis, cooldown, placeholders) and lint_rules.

Nothing runs for real: rules.json, the state file and the database live in a temporary folder and
Rules._run only records the commands it would run.

    python3 -m unittest discover -s agent/tests
"""
import json
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import events  # noqa: E402

REAL_RULES = Path(__file__).resolve().parents[1] / "rules.json"


class Engine(unittest.TestCase):
    """A Rules instance over a rules.json of the test's own."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.saved = {k: getattr(events, k) for k in ("RULES_FILE", "STATE_FILE", "EVENTS_DIR")}
        events.RULES_FILE = d / "rules.json"
        events.EVENTS_DIR = d / "events"
        events.STATE_FILE = d / "events" / "state.json"
        self.store = events.Store(d / "metrics.db")
        events.log = lambda *a: None

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(events, k, v)
        self.store.db.close()
        self.tmp.cleanup()

    def engine(self, *rules):
        events.RULES_FILE.write_text(json.dumps({"rules": list(rules)}))
        r = events.Rules(self.store)
        self.ran = []
        r._run = lambda cmd, env, timeout=120: self.ran.append((cmd, env)) or 0
        return r

    def shell_lines(self):
        return [cmd[2] for cmd, _ in self.ran if cmd[:2] == ["sh", "-c"]]


class Matching(Engine):
    def test_event_name_and_field_regexes(self):
        r = self.engine({"id": "game", "when": {"event": "window.open", "class": "^steam_app_"}, "do": ["true"]})
        self.assertEqual([x["id"] for x in r.on_event("window.open", {"class": "steam_app_570"}, dry=True)], ["game"])
        self.assertEqual(r.on_event("window.open", {"class": "foot"}, dry=True), [])
        self.assertEqual(r.on_event("window.close", {"class": "steam_app_570"}, dry=True), [])

    def test_regex_is_case_insensitive_and_missing_field_is_empty(self):
        r = self.engine({"id": "x", "when": {"event": "e", "title": "spotify"}})
        self.assertTrue(r.on_event("e", {"title": "Spotify Premium"}, dry=True))
        self.assertFalse(r.on_event("e", {}, dry=True))

    def test_disabled_rule_never_matches(self):
        r = self.engine({"id": "x", "enabled": False, "when": {"event": "e"}})
        self.assertEqual(r.on_event("e", {}, dry=True), [])

    def test_dry_run_runs_nothing(self):
        r = self.engine({"id": "x", "when": {"event": "e"}, "do": ["touch /tmp/never"], "notify": "hi"})
        r.on_event("e", {}, dry=True)
        self.assertEqual(self.ran, [])


class Hysteresis(Engine):
    def test_above_fires_once_and_rearms_below_clear(self):
        r = self.engine({"id": "disk", "when": {"metric": "disk.root.pct", "above": 90, "clear": 85},
                         "do": ["echo {value}"], "cooldown": 0})
        for v in (80, 91, 95, 88):          # crosses once; 88 is above clear, still disarmed
            r.on_sample("disk.root.pct", v)
        self.assertEqual(self.shell_lines(), ["echo 91"])
        r.on_sample("disk.root.pct", 84)    # back under clear: armed again
        r.on_sample("disk.root.pct", 92)
        self.assertEqual(self.shell_lines(), ["echo 91", "echo 92"])

    def test_below_with_clear(self):
        r = self.engine({"id": "pods", "when": {"metric": "pods.left", "below": 20, "clear": 30},
                         "do": ["echo {value} {threshold}"], "cooldown": 0})
        for v in (50, 15, 10, 25, 31, 12):
            r.on_sample("pods.left", v)
        self.assertEqual(self.shell_lines(), ["echo 15 20", "echo 12 20"])

    def test_without_clear_the_threshold_rearms(self):
        r = self.engine({"id": "t", "when": {"metric": "cpu.temp", "above": 90}, "do": ["true"], "cooldown": 0})
        for v in (91, 90, 91):
            r.on_sample("cpu.temp", v)
        self.assertEqual(len(self.ran), 2)

    def test_other_metrics_are_ignored(self):
        r = self.engine({"id": "t", "when": {"metric": "cpu.temp", "above": 90}, "do": ["true"]})
        r.on_sample("gpu.temp", 99)
        self.assertEqual(self.ran, [])

    def test_disarmed_state_survives_a_restart(self):
        rule = {"id": "t", "when": {"metric": "cpu.temp", "above": 90}, "do": ["true"], "cooldown": 0}
        self.engine(rule).on_sample("cpu.temp", 95)
        again = self.engine(rule)           # a new daemon reads state.json
        again.on_sample("cpu.temp", 96)
        self.assertEqual(len(self.ran), 0)


class Firing(Engine):
    def test_cooldown_blocks_a_second_fire_but_not_a_manual_one(self):
        r = self.engine({"id": "x", "when": {"event": "e"}, "do": ["true"], "cooldown": "1h"})
        r.on_event("e", {})
        self.assertEqual(r.fire(r.rules[0], {"event": "e"}), {"rule": "x", "skipped": "cooldown"})
        self.assertNotIn("skipped", r.fire(r.rules[0], {"event": "e"}, manual=True))
        self.assertEqual(len(self.shell_lines()), 2)

    def test_stop_on_error_by_default(self):
        r = self.engine({"id": "x", "when": {"event": "e"}, "do": ["false", "true"]})
        r._run = lambda cmd, env, timeout=120: self.ran.append((cmd, env)) or (1 if cmd[-1] == "false" else 0)
        rec = r.fire(r.rules[0], {"event": "e"})
        self.assertEqual((rec["ok"], rec["failed"], len(self.ran)), (False, ["false"], 1))

    def test_ask_only_notifies_with_a_run_button(self):
        r = self.engine({"id": "x", "when": {"event": "e"}, "do": ["rm -rf ~/x"], "ask": "Clean {what}?"})
        rec = r.fire(r.rules[0], {"event": "e", "what": "cache"})
        self.assertTrue(rec["asked"])
        self.assertEqual(self.shell_lines(), [])
        cmd = self.ran[0][0]
        self.assertEqual(cmd[1:4], ["notify", "x", "Clean cache?"])
        self.assertTrue(cmd[-1].startswith("Run=") and cmd[-1].endswith("rules fire x"))

    def test_fields_reach_the_command_as_event_variables(self):
        r = self.engine({"id": "x", "when": {"event": "e"}, "do": ["true"]})
        r.fire(r.rules[0], {"event": "e", "class": "foot", "pct": 91.0})
        env = self.ran[0][1]
        self.assertEqual((env["EVENT_CLASS"], env["EVENT_PCT"], env["EVENT_EVENT"]), ("foot", "91", "e"))

    def test_fire_is_logged_as_an_event(self):
        r = self.engine({"id": "x", "when": {"event": "e"}, "do": ["true"]})
        r.fire(r.rules[0], {"event": "e", "a": "1"})
        last = self.store.last_event("rule:x")
        self.assertEqual((last["data"]["a"], last["data"]["ok"]), ("1", True))


class Placeholders(Engine):
    HOSTILE = "x'; echo pwned; echo '$(echo sub)`echo tick`\"\n"

    def test_values_are_shell_quoted_in_commands(self):
        r = self.engine({"id": "x", "when": {"event": "e"}, "do": ["echo {title}"]})
        line = r.expand("echo {title}", {"title": self.HOSTILE}, quote=True)
        self.assertEqual(shlex.split(line), ["echo", self.HOSTILE])

    def test_a_hostile_title_stays_one_argument_in_a_real_shell(self):
        r = self.engine({})
        line = r.expand("printf %s {title}", {"title": self.HOSTILE}, quote=True)
        out = subprocess.run(["sh", "-c", line], capture_output=True, text=True, timeout=5).stdout
        self.assertEqual(out, self.HOSTILE)

    def test_notify_text_is_not_quoted(self):
        r = self.engine({})
        self.assertEqual(r.expand("Disk at {value}%", {"value": 91.5}, quote=False), "Disk at 91.5%")

    def test_unknown_placeholder_is_empty(self):
        self.assertEqual(self.engine({}).expand("a{nope}b", {}, quote=False), "ab")


def rules(*rs, **top):
    return {"rules": list(rs), **top}


class Lint(unittest.TestCase):
    def test_the_real_rules_json_is_clean(self):
        self.assertEqual(events.lint_rules(json.loads(REAL_RULES.read_text())), [])

    def test_placeholder_inside_quotes(self):
        for cmd in ("echo '{title}'", 'notify-send "Window {title} opened"', "sh -c 'x {a}' {b}"):
            p = events.lint_rules(rules({"id": "q", "when": {"event": "e"}, "do": [cmd]}))
            self.assertEqual(len(p), 1, cmd)
            self.assertIn("inside quotes", p[0])

    def test_bare_and_glued_placeholders_are_fine(self):
        for cmd in ("echo {title}", "systemd-run --unit barch-music-cover-{id} -- barch music cover-ask {id}",
                    "echo \\'{x}", "printf '%s\\n' {x}", "echo \"$HOME\" {x}"):
            self.assertEqual(events.lint_rules(rules({"id": "q", "when": {"event": "e"}, "do": [cmd]})), [], cmd)

    def test_schema_problems(self):
        cases = [
            ({"id": "a", "when": {"event": "e", "metric": "m"}}, "exactly one of event or metric"),
            ({"id": "a", "when": {"metric": "m"}}, "exactly one of above or below"),
            ({"id": "a", "when": {"metric": "m", "above": "90"}}, "must be numbers"),
            ({"id": "a", "when": {"metric": "m", "above": 90, "clear": 95}}, "never re-arm"),
            ({"id": "a", "when": {"metric": "m", "below": 20, "clear": 10}}, "never re-arm"),
            ({"id": "a", "when": {"event": "e", "class": "(["}}, "not a regex"),
            ({"id": "a", "when": {"event": "e"}, "do": "true"}, "list of strings"),
            ({"id": "a", "when": {"event": "e"}, "cooldown": "soon"}, "not a duration"),
            ({"id": "a", "when": {"event": "e"}, "enabled": "yes"}, "true or false"),
            ({"id": "a", "when": {"event": "e"}, "notfy": "typo"}, "unknown key 'notfy'"),
        ]
        for rule, msg in cases:
            p = events.lint_rules(rules(rule))
            self.assertTrue(any(msg in x for x in p), (rule, p))

    def test_duplicate_and_missing_ids(self):
        p = events.lint_rules(rules({"id": "a", "when": {"event": "e"}}, {"id": "a", "when": {"event": "e"}}, {"when": {}}))
        self.assertIn("a: duplicate id", p)
        self.assertIn("rule #2: no id", p)


if __name__ == "__main__":
    unittest.main()
