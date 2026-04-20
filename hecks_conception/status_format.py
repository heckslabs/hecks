#!/usr/bin/env python3
# status_format.py — renders Miette's status report from heki JSON streams.
#
# Usage:
#   python3 status_format.py <info_dir> <mindstream_alive> <greeting_alive> \
#                            <aggregates_count> <capabilities_count> [--no-color]
#
# Reads each <info_dir>/*.heki via `hecks-life heki read` through subprocess,
# extracts the fields documented in status.sh, and prints a labeled, colored
# report. Honors NO_COLOR env var or --no-color flag.
#
# Subcommand `musings` lists musing.heki with optional --source filter.

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HECKS = os.environ.get(
    "HECKS_LIFE",
    str(Path(__file__).resolve().parent.parent / "hecks_life/target/release/hecks-life"),
)


def color_enabled(flag_no_color):
    if flag_no_color:
        return False
    if os.environ.get("NO_COLOR"):
        return False
    return sys.stdout.isatty() or os.environ.get("HECKS_FORCE_COLOR") == "1"


def paint(text, code, on):
    return f"\x1b[{code}m{text}\x1b[0m" if on else text


def read_heki(info_dir, name):
    path = Path(info_dir) / f"{name}.heki"
    if not path.exists():
        return {}
    try:
        out = subprocess.run(
            [HECKS, "heki", "read", str(path)],
            capture_output=True, text=True, check=False,
        )
        data = json.loads(out.stdout or "{}")
        return data if isinstance(data, dict) else {}
    except (json.JSONDecodeError, FileNotFoundError):
        return {}


def latest(records):
    if not records:
        return {}
    def key(item):
        return item[1].get("updated_at") or item[1].get("created_at") or ""
    return sorted(records.items(), key=key)[-1][1]


def age_days(born_iso):
    if not born_iso:
        return "—"
    try:
        dt = datetime.fromisoformat(born_iso.replace("Z", "+00:00"))
        delta = datetime.now(timezone.utc) - dt
        return f"{delta.days}d"
    except (ValueError, TypeError):
        return "—"


def fmt_section(title, rows, on):
    header = paint(f"─── {title} ───", "1;36", on)
    lines = [header]
    for label, value in rows:
        lbl = paint(f"{label}:", "1;33", on)
        lines.append(f"  {lbl} {value}")
    return "\n".join(lines)


def render(info_dir, mindstream_alive, greeting_alive, agg_n, cap_n, on):
    identity = latest(read_heki(info_dir, "identity"))
    consciousness = latest(read_heki(info_dir, "consciousness"))
    heartbeat = latest(read_heki(info_dir, "heartbeat"))
    tick = latest(read_heki(info_dir, "tick"))
    mood = latest(read_heki(info_dir, "mood"))
    dream = latest(read_heki(info_dir, "dream_state"))
    convo_records = read_heki(info_dir, "conversation")
    last_turn = latest(convo_records)

    musings = len(read_heki(info_dir, "musing"))
    conversations = len(convo_records)
    signals = len(read_heki(info_dir, "signal"))
    synapses = len(read_heki(info_dir, "synapse"))
    memories = len(read_heki(info_dir, "memory"))

    sleep_cycle = consciousness.get("sleep_cycle", "—")
    sleep_total = consciousness.get("sleep_total", "—")
    sleep_progress = f"{sleep_cycle}/{sleep_total}"

    sections = [
        fmt_section("Identity", [
            ("name", identity.get("first_words") or identity.get("name", "—")),
            ("born_at", identity.get("born_at", "—")),
            ("age", age_days(identity.get("birthday") or identity.get("created_at"))),
        ], on),
        fmt_section("Consciousness", [
            ("state", consciousness.get("state", "—")),
            ("sleep_stage", consciousness.get("sleep_stage") or "—"),
            ("sleep_progress", sleep_progress),
            ("sleep_summary", consciousness.get("sleep_summary") or "—"),
        ], on),
        fmt_section("Vitals", [
            ("fatigue", heartbeat.get("fatigue", "—")),
            ("fatigue_state", heartbeat.get("fatigue_state", "—")),
            ("pulse_rate", heartbeat.get("pulse_rate", "—")),
            ("flow_rate", heartbeat.get("flow_rate", "—")),
            ("pulses_since_sleep", heartbeat.get("pulses_since_sleep", "—")),
            ("cycle", tick.get("cycle", tick.get("beats", 0)) or 0),
        ], on),
        fmt_section("Mood", [
            ("current_state", mood.get("current_state", "—")),
            ("creativity_level", mood.get("creativity_level", "—")),
            ("precision_level", mood.get("precision_level", "—")),
        ], on),
        fmt_section("Memory", [
            ("musings", musings),
            ("conversations", conversations),
            ("signals", signals),
            ("synapses", synapses),
            ("memories", memories),
        ], on),
        fmt_section("Recent activity", [
            ("last_dream_at", dream.get("updated_at") or dream.get("created_at") or "—"),
            ("last_dream", _dream_text(dream)),
            ("last_turn_at", last_turn.get("updated_at") or last_turn.get("created_at") or "—"),
            ("last_turn", _turn_text(last_turn)),
        ], on),
        fmt_section("Bluebooks", [
            ("aggregates", agg_n),
            ("capabilities", cap_n),
        ], on),
        fmt_section("Daemons", [
            ("mindstream", "alive" if mindstream_alive == "1" else "down"),
            ("greeting", "alive" if greeting_alive == "1" else "down"),
        ], on),
    ]
    print("\n".join(sections))


def _dream_text(dream):
    imgs = dream.get("dream_images")
    if isinstance(imgs, list) and imgs:
        return imgs[0]
    return dream.get("text") or "—"


def _turn_text(turn):
    if not turn:
        return "—"
    speaker = turn.get("speaker", "?")
    said = turn.get("said") or turn.get("text") or ""
    return f"{speaker}: {said}" if said else speaker


def musings_cmd(info_dir, source_filter, on):
    records = read_heki(info_dir, "musing")
    header = paint("─── Musings ───", "1;36", on)
    print(header)
    items = list(records.values())
    if source_filter:
        items = [r for r in items if r.get("source") == source_filter]
    items.sort(key=lambda r: r.get("updated_at") or r.get("created_at") or "")
    for r in items:
        ts = r.get("updated_at") or r.get("created_at") or "—"
        src = r.get("source") or "—"
        idea = r.get("idea") or r.get("conceived_as") or "—"
        print(f"  {paint(ts, '2', on)} [{src}] {idea}")
    if not items:
        print("  (none)")


def main():
    argv = sys.argv[1:]
    no_color = "--no-color" in argv
    argv = [a for a in argv if a != "--no-color"]

    if argv and argv[0] == "musings":
        info_dir = os.environ.get("HECKS_INFO") or argv[1] if len(argv) > 1 else "information"
        source = None
        for a in argv[1:]:
            if a.startswith("--source="):
                source = a.split("=", 1)[1]
        musings_cmd(info_dir, source, color_enabled(no_color))
        return

    info_dir, mindstream, greeting, agg_n, cap_n = argv[:5]
    render(info_dir, mindstream, greeting, int(agg_n), int(cap_n), color_enabled(no_color))


if __name__ == "__main__":
    main()
