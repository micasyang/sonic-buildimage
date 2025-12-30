#!/usr/bin/env python3
"""Populate /etc/device/.productname and .board_id."""
from __future__ import annotations
import json
import logging
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

HOST_MACHINE = "/host/machine.conf"
PRODUCT_NAME_PATH = "/etc/device/.productname"
BOARD_ID_PATH = "/etc/device/.board_id"
LOG_PATH = "/var/log/platform-detect.log"
RETRY_COUNT = 10
RETRY_DELAY_SEC = 1


def setup_logger() -> logging.Logger:
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    logger = logging.getLogger("platform-detect")
    logger.setLevel(logging.INFO)
    handler = logging.FileHandler(LOG_PATH)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(handler)
    return logger


PROFILE_DATA_PATH = "/usr/local/share/platform_detect/platform_profiles.json"


LOGGER = setup_logger()


def normalize(value: str) -> str:
    return value.strip().replace("-", "_").lower()


@dataclass(frozen=True)
class PlatformProfile:
    """Readable table entry for platform/board-id canonicalization."""

    name: str
    platform_aliases: List[str] = field(default_factory=list)
    board_id_aliases: Dict[str, List[str]] = field(default_factory=dict)
    description: str = ""

    def matches_platform(self, platform_value: str) -> bool:
        return platform_value == self.name or platform_value in self.platform_aliases

    def canonical_board_id(self, board_id_value: str) -> Optional[str]:
        for canonical, aliases in self.board_id_aliases.items():
            if board_id_value == canonical or board_id_value in aliases:
                return canonical
        return None


def load_profiles(path: str = PROFILE_DATA_PATH) -> List[PlatformProfile]:
    """Load platform profiles from an external JSON file."""

    if not os.path.exists(path):
        LOGGER.warning("Profile data file %s not found; no canonical mappings loaded", path)
        return []

    try:
        with open(path, "r", encoding="utf-8") as file_handle:
            entries = json.load(file_handle)
    except Exception as exc:  # pragma: no cover - defensive logging
        LOGGER.error("Failed to load profile data from %s: %s", path, exc)
        return []

    profiles: List[PlatformProfile] = []
    for entry in entries:
        try:
            profiles.append(
                PlatformProfile(
                    name=entry["name"],
                    platform_aliases=entry.get("platform_aliases", []),
                    board_id_aliases=entry.get("board_id_aliases", {}),
                    description=entry.get("description", ""),
                )
            )
        except KeyError as exc:
            LOGGER.warning("Skipping malformed profile entry (%s): %s", exc, entry)
    return profiles


PLATFORM_PROFILES: List[PlatformProfile] = load_profiles()


def canonicalize(platform_value: Optional[str], board_id_value: Optional[str]) -> Tuple[Optional[str], Optional[str]]:
    """Map detected values to canonical names using PLATFORM_PROFILES."""

    canonical_platform = platform_value
    canonical_board_id = board_id_value

    if platform_value:
        for profile in PLATFORM_PROFILES:
            if profile.matches_platform(platform_value):
                canonical_platform = profile.name
                if board_id_value:
                    board_candidate = profile.canonical_board_id(board_id_value)
                    if board_candidate:
                        canonical_board_id = board_candidate
                break
    return canonical_platform, canonical_board_id


def read_machine_conf() -> Optional[Dict[str, str]]:
    if not os.path.exists(HOST_MACHINE):
        return None
    info: Dict[str, str] = {}
    try:
        with open(HOST_MACHINE, "r", encoding="utf-8") as machine_file:
            for line in machine_file:
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                info[key.strip()] = value.strip()
    except Exception as exc:
        LOGGER.warning("Failed to read %s: %s", HOST_MACHINE, exc)
        return None
    return info


def get_machine_platform() -> str:
    info = read_machine_conf()
    if not info:
        raise RuntimeError("machine.conf not available")
    for key in ("onie_platform", "aboot_platform"):
        value = info.get(key)
        if value:
            return normalize(value)
    raise RuntimeError("platform keys missing in machine.conf")


def get_machine_board_id() -> str:
    info = read_machine_conf()
    if not info:
        raise RuntimeError("machine.conf not available")
    value = info.get("onie_board_id")
    if value:
        return normalize(value)
    raise RuntimeError("onie_board_id missing in machine.conf")


def read_fw_env(var_name: str) -> str:
    cmd = ["fw_printenv", var_name]
    LOGGER.info("Executing %s", " ".join(cmd))
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            f"fw_printenv failed for {var_name}: rc={result.returncode} stderr='{result.stderr.strip()}'"
        )
    line = result.stdout.strip()
    if not line or "=" not in line:
        raise RuntimeError(f"unexpected fw_printenv output for {var_name}: '{line}'")
    _, value = line.split("=", 1)
    value = value.strip()
    if not value:
        raise RuntimeError(f"{var_name} is empty in u-boot environment")
    return normalize(value)


def get_env_platform() -> str:
    return read_fw_env("productname")


def get_env_board_id() -> str:
    return read_fw_env("board_id")


def detect_with_retry(label: str, getters: "list[Callable[[], str]]") -> Optional[str]:
    for getter in getters:
        for attempt in range(1, RETRY_COUNT + 1):
            try:
                value = getter()
                LOGGER.info("Detected %s='%s' via %s (attempt %d)", label, value, getter.__name__, attempt)
                return value
            except Exception as exc:
                LOGGER.warning(
                    "Attempt %d for %s via %s failed: %s", attempt, label, getter.__name__, exc
                )
                time.sleep(RETRY_DELAY_SEC)
    return None


def write_value(path: str, value: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as file_handle:
        file_handle.write(f"{value}\n")
    try:
        os.sync()
    except AttributeError:
        pass
    LOGGER.info("Persisted %s to %s", value, path)


def main() -> int:
    platform_value = detect_with_retry("platform", [get_machine_platform, get_env_platform])
    board_id_value = detect_with_retry("board_id", [get_machine_board_id, get_env_board_id])

    platform_value, board_id_value = canonicalize(platform_value, board_id_value)

    rc = 0
    if platform_value:
        write_value(PRODUCT_NAME_PATH, platform_value)
    else:
        LOGGER.error("Unable to determine platform value")
        rc = 1

    if board_id_value:
        write_value(BOARD_ID_PATH, board_id_value)
    else:
        LOGGER.error("Unable to determine board_id value")
        rc = 1

    return rc


if __name__ == "__main__":
    sys.exit(main())
