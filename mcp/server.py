# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "fastmcp>=2.0.0",
# ]
# ///
"""
MCP Server for Path of Building

Provides read-only build analysis tools for AI agents via the Model Context Protocol.
Spawns a LuaJIT subprocess running PoB's headless calculation engine and exposes
build stats, skills, items, passive tree, and configuration as MCP tools.

Usage:
    uv run mcp/server.py                    # stdio transport (default)
    uv run mcp/server.py --transport http   # HTTP transport on port 8000

Requires:
    - uv (https://docs.astral.sh/uv/)
    - luajit on PATH (or set LUAJIT_PATH env var)
"""

import base64
import json
import os
import re
import subprocess
import sys
import threading
import urllib.request
import zlib
from pathlib import Path
from typing import Any

from fastmcp import FastMCP

# Resolve paths
SCRIPT_DIR = Path(__file__).parent.resolve()
PROJECT_DIR = SCRIPT_DIR.parent
SRC_DIR = PROJECT_DIR / "src"
WRAPPER_SCRIPT = SRC_DIR / "MCPWrapper.lua"

mcp = FastMCP(
    name="PathOfBuilding",
    instructions=(
        "This server provides read-only access to Path of Building, "
        "an offline build planner for Path of Exile. Use the tools to load builds, "
        "inspect stats, items, skills, passive trees, and configuration. "
        "The agent should provide optimization recommendations as text — "
        "it cannot modify builds directly."
    ),
)


class LuaJITProcess:
    """Manages a persistent LuaJIT subprocess running MCPWrapper.lua."""

    def __init__(self):
        self._process: subprocess.Popen | None = None
        self._lock = threading.Lock()

    def _get_luajit(self) -> str:
        return os.environ.get("LUAJIT_PATH", "luajit")

    def _ensure_running(self):
        if self._process is not None and self._process.poll() is None:
            return
        luajit = self._get_luajit()
        self._process = subprocess.Popen(
            [luajit, str(WRAPPER_SCRIPT)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(SRC_DIR),
            text=True,
            bufsize=1,
        )
        # Wait for the ready signal
        ready_line = self._process.stdout.readline()
        if not ready_line:
            stderr = self._process.stderr.read()
            raise RuntimeError(f"LuaJIT process failed to start: {stderr}")
        try:
            ready_msg = json.loads(ready_line)
            if not ready_msg.get("ready"):
                raise RuntimeError(f"Unexpected ready message: {ready_line}")
        except json.JSONDecodeError:
            raise RuntimeError(f"Invalid ready message: {ready_line}")

    def send_command(self, command: str, params: dict | None = None) -> Any:
        with self._lock:
            self._ensure_running()
            request = {
                "id": 1,
                "command": command,
                "params": params or {},
            }
            try:
                self._process.stdin.write(json.dumps(request) + "\n")
                self._process.stdin.flush()
                response_line = self._process.stdout.readline()
                if not response_line:
                    self._process = None
                    raise RuntimeError("LuaJIT process terminated unexpectedly")
                response = json.loads(response_line)
                if "error" in response:
                    raise ValueError(response["error"])
                return response.get("result")
            except (BrokenPipeError, OSError) as e:
                self._process = None
                raise RuntimeError(f"LuaJIT process communication error: {e}")

    def shutdown(self):
        if self._process and self._process.poll() is None:
            self._process.terminate()
            self._process.wait(timeout=5)
            self._process = None


lua = LuaJITProcess()


def _format_result(data: Any) -> str:
    """Format a result for MCP tool output."""
    if isinstance(data, str):
        return data
    return json.dumps(data, indent=2)


# --- MCP Tools ---


@mcp.tool
def load_build(file_path: str) -> str:
    """Load a Path of Building build from an XML file.

    This must be called before any other analysis tools.
    The file_path should be the absolute path to a .xml build file.
    Users typically save builds via Ctrl+S in the PoB GUI before analysis.
    """
    result = lua.send_command("load_build", {"file_path": file_path})
    return _format_result(result)


def _decode_build_code(code: str) -> str:
    """Decode a PoB build code (URL-safe base64 + zlib) into XML."""
    # Reverse URL-safe substitutions
    b64 = code.replace("-", "+").replace("_", "/")
    # Pad if needed
    b64 += "=" * (-len(b64) % 4)
    raw = base64.b64decode(b64)
    xml_bytes = zlib.decompress(raw)
    return xml_bytes.decode("utf-8")


# Build sharing sites: maps site ID (lowercase) to download URL pattern.
# %s is replaced with the build ID extracted from the URL.
_BUILD_SITES = {
    "pobbin": "https://pobb.in/pob/%s",
    "maxroll": "https://maxroll.gg/poe/api/pob/%s",
    "poeninja": "https://poe.ninja/poe1/pob/raw/%s",
    "pastebin": "https://pastebin.com/raw/%s",
    "pastebinproxy": "https://pastebinp.com/raw/%s",
    "rentry": "https://rentry.co/paste/%s/raw",
    "poedb": "https://poedb.tw/pob/%s/raw",
}

# Patterns for matching direct website URLs
_SITE_URL_PATTERNS = [
    (re.compile(r"pobb\.in/(?:pob/)?(.+)"), "pobbin"),
    (re.compile(r"maxroll\.gg/poe/pob/(.+)"), "maxroll"),
    (re.compile(r"poe\.ninja/?(?:poe1)?/pob/(?:raw/)?(\w+)"), "poeninja"),
    (re.compile(r"pastebin\.com/(?:raw/)?(\w+)"), "pastebin"),
    (re.compile(r"pastebinp\.com/(?:raw/)?(\w+)"), "pastebinproxy"),
    (re.compile(r"rentry\.co/(?:paste/)?(\w+)"), "rentry"),
    (re.compile(r"poedb\.tw/pob/(.+?)(?:/raw)?$"), "poedb"),
]


def _download_build_code(url: str) -> str:
    """Download a build code from a URL."""
    req = urllib.request.Request(url, headers={"User-Agent": "Path of Building MCP"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.read().decode("utf-8").strip()


def _resolve_build_code(input_str: str) -> str:
    """Resolve input to a raw build code string.

    Supports:
    - Raw build codes (base64 string)
    - pob:// protocol URLs (e.g., pob://pobbin/abc123)
    - Direct website URLs (e.g., https://pobb.in/abc123)
    """
    input_str = input_str.strip()

    # Handle pob:// protocol URLs → pob://siteid/buildid
    if input_str.lower().startswith("pob://") or input_str.lower().startswith("pob:\\\\"):
        path = re.sub(r"^pob:[/\\]+", "", input_str, flags=re.IGNORECASE)
        parts = path.split("/", 1) if "/" in path else path.split("\\", 1)
        if len(parts) == 2:
            site_id = parts[0].lower()
            build_id = parts[1]
            if site_id in _BUILD_SITES:
                url = _BUILD_SITES[site_id] % build_id
                return _download_build_code(url)
        # If no site matched, treat the path as an inline build code
        return path

    # Handle direct website URLs (https://pobb.in/..., etc.)
    for pattern, site_id in _SITE_URL_PATTERNS:
        m = pattern.search(input_str)
        if m:
            build_id = m.group(1).strip()
            url = _BUILD_SITES[site_id] % build_id
            return _download_build_code(url)

    # Assume raw build code
    return input_str


@mcp.tool
def load_build_code(build_code: str) -> str:
    """Load a build from a PoB build code, pob:// URL, or website URL.

    Accepts:
    - A raw build code (the base64 string users copy from PoB's export)
    - A pob:// protocol URL (e.g., pob://pobbin/abc123)
    - A direct website URL (pobb.in, maxroll, poe.ninja, pastebin, rentry, poedb)

    Args:
        build_code: The build code string, pob:// URL, or website URL.
    """
    try:
        code = _resolve_build_code(build_code)
        xml_text = _decode_build_code(code)
    except Exception as e:
        raise ValueError(f"Failed to decode build code: {e}")
    result = lua.send_command("load_build_xml", {"xml": xml_text, "name": "Imported Build"})
    return _format_result(result)


@mcp.tool
def get_build_summary() -> str:
    """Get a summary of the currently loaded build.

    Returns class, ascendancy, character level, bandit choice, and pantheon selections.
    """
    result = lua.send_command("get_build_summary")
    return _format_result(result)


@mcp.tool
def get_all_stats() -> str:
    """Get all calculated stats for the current build.

    Returns the complete mainOutput table (~150 stats) including DPS, defenses,
    attributes, charges, costs, and more. Use get_offense_stats or get_defense_stats
    for focused subsets.
    """
    result = lua.send_command("get_all_stats")
    return _format_result(result)


@mcp.tool
def get_offense_stats() -> str:
    """Get offensive stats for the current build.

    Returns: TotalDPS, CombinedDPS, AverageDamage, AverageHit, Speed, CritChance,
    CritMultiplier, HitChance, ailment DPS (Poison, Ignite, Bleed, Impale),
    ManaCost, LifeCost, ProjectileCount, AreaOfEffectMod, and more.
    """
    result = lua.send_command("get_offense_stats")
    return _format_result(result)


@mcp.tool
def get_defense_stats() -> str:
    """Get defensive stats for the current build.

    Returns: Life, EnergyShield, Mana (total and unreserved), Armour, Evasion,
    resistances (with overcap), block chance, spell suppression, EHP (effective
    hit pool), attributes (Str/Dex/Int), charges, regen rates, and leech rates.
    """
    result = lua.send_command("get_defense_stats")
    return _format_result(result)


@mcp.tool
def get_stat_breakdown(stat_key: str) -> str:
    """Get a detailed breakdown of how a specific stat is calculated.

    Args:
        stat_key: The exact stat name (e.g. "TotalDPS", "Life", "CritChance").
                  Use get_all_stats to see available stat names.

    Returns the stat value and, if available, the step-by-step calculation breakdown.
    """
    result = lua.send_command("get_stat_breakdown", {"stat_key": stat_key})
    return _format_result(result)


@mcp.tool
def list_skills() -> str:
    """List all skill socket groups in the current build.

    Returns each socket group with its gems (name, level, quality, enabled state),
    the slot it's equipped in, and whether the group is enabled.
    """
    result = lua.send_command("list_skills")
    return _format_result(result)


@mcp.tool
def list_items() -> str:
    """List all equipped items in the current build.

    Returns items organized by slot (Weapon 1, Helmet, Body Armour, etc.) with
    the item name, base type, rarity, and all modifier lines (explicit, implicit,
    enchant).
    """
    result = lua.send_command("list_items")
    return _format_result(result)


@mcp.tool
def list_passive_nodes() -> str:
    """List all allocated passive tree nodes in the current build.

    Returns allocated nodes (with name, type, keystone/notable flags),
    mastery selections, and socketed jewels.
    """
    result = lua.send_command("list_passive_nodes")
    return _format_result(result)


@mcp.tool
def get_config() -> str:
    """Get the current build configuration settings.

    Returns all config inputs: enemy settings, active buffs/debuffs, conditions,
    charge settings, flask effects, and other toggleable options that affect
    the calculation.
    """
    result = lua.send_command("get_config")
    return _format_result(result)


if __name__ == "__main__":
    transport = "stdio"
    if "--transport" in sys.argv:
        idx = sys.argv.index("--transport")
        if idx + 1 < len(sys.argv):
            transport = sys.argv[idx + 1]

    try:
        if transport == "http":
            mcp.run(transport="http", host="127.0.0.1", port=8000)
        else:
            mcp.run(transport="stdio")
    finally:
        lua.shutdown()
