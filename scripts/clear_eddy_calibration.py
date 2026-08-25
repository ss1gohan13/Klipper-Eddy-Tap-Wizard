#!/usr/bin/env python3
"""
Clear Eddy calibration values written by Klipper's SAVE_CONFIG.

This script intentionally edits ONLY the SAVE_CONFIG-generated block in the
main Klipper config file. It does not touch the normal user configuration.

Default config:
    ~/printer_data/config/printer.cfg

Usage:
    clear_eddy_calibration.py --probe eddy
    clear_eddy_calibration.py --probe eddy --dry-run
    clear_eddy_calibration.py --probe eddy --config /path/to/printer.cfg
"""

from __future__ import annotations

import argparse
import configparser
import io
import os
from pathlib import Path
import shutil
import sys
import tempfile
from datetime import datetime

AUTOSAVE_HEADER = """
#*# <---------------------- SAVE_CONFIG ---------------------->
#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.
#*#
"""

PROBE_OPTIONS = (
    "reg_drive_current",
    "calibrate",
    "tap_threshold",
    "tap_z_offset",
)

TEMP_OPTIONS = (
    "calibration_temp",
    "drift_calibration",
    "drift_calibration_min_temp",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Remove saved Eddy calibration data from Klipper SAVE_CONFIG."
    )
    parser.add_argument(
        "--probe",
        required=True,
        help="Eddy probe name, for example: eddy",
    )
    parser.add_argument(
        "--config",
        default=os.path.expanduser("~/printer_data/config/printer.cfg"),
        help="Main Klipper config file containing the SAVE_CONFIG block.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be removed without modifying the config.",
    )
    return parser.parse_args()


def split_autosave(data: str) -> tuple[str, str]:
    """Return (regular_config, decoded_autosave_ini)."""
    pos = data.find(AUTOSAVE_HEADER)
    if pos < 0:
        return data, ""

    regular_data = data[:pos]
    autosave_data = data[pos + len(AUTOSAVE_HEADER):].strip()

    # Match Klipper's safety expectations for the SAVE_CONFIG block.
    if "\n#*# " in regular_data or AUTOSAVE_HEADER in autosave_data:
        raise RuntimeError(
            "The SAVE_CONFIG block appears corrupted or duplicated; refusing to edit."
        )

    decoded = [""]
    if autosave_data:
        for line in autosave_data.split("\n"):
            if not line.startswith("#*#"):
                raise RuntimeError(
                    "Unexpected data below SAVE_CONFIG header; refusing to edit."
                )
            if len(line) >= 4 and not line.startswith("#*# "):
                raise RuntimeError(
                    "Malformed SAVE_CONFIG line; refusing to edit."
                )
            decoded.append(line[4:] if len(line) >= 4 else "")
    decoded.append("")
    return regular_data, "\n".join(decoded)


def parse_autosave_ini(data: str) -> configparser.RawConfigParser:
    parser = configparser.RawConfigParser(
        strict=False,
        inline_comment_prefixes=(";", "#"),
        interpolation=None,
    )
    if data.strip():
        parser.read_string(data)
    return parser


def build_autosave_block(parser: configparser.RawConfigParser) -> str:
    """Serialize using the same #*# style used by Klipper SAVE_CONFIG."""
    if not parser.sections():
        return ""

    sio = io.StringIO()
    parser.write(sio)
    autosave_data = sio.getvalue().strip()

    lines = [("#*# " + line).strip() for line in autosave_data.split("\n")]
    lines.insert(0, "\n" + AUTOSAVE_HEADER.rstrip())
    lines.append("")
    return "\n".join(lines)


def remove_options(
    parser: configparser.RawConfigParser,
    section: str,
    options: tuple[str, ...],
) -> list[str]:
    removed: list[str] = []

    if not parser.has_section(section):
        return removed

    for option in options:
        if parser.has_option(section, option):
            parser.remove_option(section, option)
            removed.append(option)

    # SAVE_CONFIG sections exist only to hold generated options. If all options
    # in this autosave section are gone, remove the empty section as well.
    if not parser.options(section):
        parser.remove_section(section)

    return removed


def make_backup(config_path: Path) -> Path:
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_dir = config_path.parent / "eddy_wizard_backups" / stamp
    backup_dir.mkdir(parents=True, exist_ok=False)
    backup_path = backup_dir / "printer.cfg.before_eddy_calibration_reset"
    shutil.copy2(config_path, backup_path)
    return backup_path


def atomic_write(path: Path, data: str) -> None:
    stat = path.stat()
    tmp_name = None

    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=path.parent,
            prefix=".eddy-reset-",
            delete=False,
        ) as tmp:
            tmp_name = tmp.name
            tmp.write(data)
            tmp.flush()
            os.fsync(tmp.fileno())

        os.chmod(tmp_name, stat.st_mode)
        os.replace(tmp_name, path)
        tmp_name = None
    finally:
        if tmp_name is not None:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass


def main() -> int:
    args = parse_args()
    probe = args.probe.strip()
    config_path = Path(args.config).expanduser().resolve()

    if not probe:
        print("[FAIL] Probe name is empty.", file=sys.stderr)
        return 2

    if not config_path.is_file():
        print(f"[FAIL] Klipper config not found: {config_path}", file=sys.stderr)
        return 2

    data = config_path.read_text(encoding="utf-8")
    regular_data, autosave_ini = split_autosave(data)

    if not autosave_ini.strip():
        print("[INFO] No Klipper SAVE_CONFIG data was found.")
        print("[INFO] No Eddy calibration values were removed.")
        return 0

    parser = parse_autosave_ini(autosave_ini)

    probe_section = f"probe_eddy_current {probe}"
    temp_section = f"temperature_probe {probe}"

    removed_probe = remove_options(parser, probe_section, PROBE_OPTIONS)
    removed_temp = remove_options(parser, temp_section, TEMP_OPTIONS)

    removed = (
        [(probe_section, key) for key in removed_probe]
        + [(temp_section, key) for key in removed_temp]
    )

    print(f"[INFO] Eddy reset target: {probe}")
    print(f"[INFO] Main config: {config_path}")

    if not removed:
        print("[INFO] No matching Eddy SAVE_CONFIG calibration values were found.")
        return 0

    print("[INFO] Calibration values selected for removal:")
    for section, key in removed:
        print(f"       [{section}] {key}")

    if args.dry_run:
        print("[ OK ] Dry run complete. No files were modified.")
        return 0

    backup_path = make_backup(config_path)

    new_autosave = build_autosave_block(parser)
    if new_autosave:
        new_data = regular_data.rstrip() + new_autosave
    else:
        new_data = regular_data.rstrip() + "\n"

    atomic_write(config_path, new_data)

    # Re-read and verify that none of the requested saved values remain.
    verify_data = config_path.read_text(encoding="utf-8")
    _, verify_autosave_ini = split_autosave(verify_data)
    verify_parser = parse_autosave_ini(verify_autosave_ini)

    remaining = []
    for section, options in (
        (probe_section, PROBE_OPTIONS),
        (temp_section, TEMP_OPTIONS),
    ):
        if verify_parser.has_section(section):
            for option in options:
                if verify_parser.has_option(section, option):
                    remaining.append(f"[{section}] {option}")

    if remaining:
        print("[FAIL] Verification failed. Values still present:", file=sys.stderr)
        for item in remaining:
            print(f"       {item}", file=sys.stderr)
        print(f"[INFO] Backup: {backup_path}", file=sys.stderr)
        return 3

    print(f"[ OK ] Eddy SAVE_CONFIG calibration data cleared.")
    print(f"[ OK ] Backup created: {backup_path}")
    print("[INFO] Restart Klipper before beginning a new Eddy calibration.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        raise SystemExit(1)
