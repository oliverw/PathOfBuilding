"""MCP Server for Path of Building.

Communicates with PoB via file-based IPC (works across Wine/Linux and native Windows).
Run with: uv run pob-mcp
"""

import json
import os
import time
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

mcp = FastMCP(
    "Path of Building",
    instructions=(
        "This server connects to a running Path of Building instance. "
        "Use the tools to read and modify build data. "
        "Write operations automatically trigger recalculation and return updated stats."
    ),
)


IPC_DIR = Path(os.environ.get("POB_IPC_DIR", Path.home() / ".pob-mcp"))
REQUEST_FILE = IPC_DIR / "mcp_request.json"
RESPONSE_FILE = IPC_DIR / "mcp_response.json"

POLL_INTERVAL = 0.02  # 20ms between polls
TIMEOUT = 10.0  # Max wait for response


def send_command(command: str, params: dict[str, Any] | None = None) -> Any:
    """Send a command to PoB via file IPC and wait for the response."""
    # Clean up any stale response file
    if RESPONSE_FILE.exists():
        RESPONSE_FILE.unlink()

    # Write request
    request = {"command": command, "id": 1}
    if params:
        request["params"] = params

    # Write atomically: write to tmp, then rename
    tmp_file = REQUEST_FILE.with_suffix(".tmp")
    tmp_file.write_text(json.dumps(request))
    tmp_file.rename(REQUEST_FILE)

    # Poll for response
    start = time.monotonic()
    while time.monotonic() - start < TIMEOUT:
        if RESPONSE_FILE.exists():
            try:
                content = RESPONSE_FILE.read_text()
                RESPONSE_FILE.unlink(missing_ok=True)
                response = json.loads(content)
                if "error" in response and response["error"]:
                    raise RuntimeError(response["error"])
                return response.get("result")
            except json.JSONDecodeError:
                # Response file might be partially written, retry
                time.sleep(POLL_INTERVAL)
                continue
        time.sleep(POLL_INTERVAL)

    # Timeout - clean up
    REQUEST_FILE.unlink(missing_ok=True)
    raise RuntimeError(
        "Timeout waiting for PoB response. Is Path of Building running with MCP enabled?"
    )


# ──────────────────────────────────────────────
# Read Tools
# ──────────────────────────────────────────────


@mcp.tool()
def get_build_summary() -> dict:
    """Get build overview: class, ascendancy, level, bandits, pantheon."""
    return send_command("get_build_summary")


@mcp.tool()
def get_all_stats() -> dict:
    """Get every calculated stat from the build (mainOutput dump). Returns ~150 numeric values."""
    return send_command("get_all_stats")


@mcp.tool()
def get_offense_stats() -> dict:
    """Get offensive stats: DPS, crit, speed, hit chance, ailment DPS, costs."""
    return send_command("get_offense_stats")


@mcp.tool()
def get_defense_stats() -> dict:
    """Get defensive stats: life, ES, armour, evasion, resistances, block, suppress."""
    return send_command("get_defense_stats")


@mcp.tool()
def list_skills() -> dict:
    """List all socket groups with their gems, levels, quality, and enabled state."""
    return send_command("list_skills")


@mcp.tool()
def list_items() -> dict:
    """List all equipped items by slot and all items in the item list."""
    return send_command("list_items")


@mcp.tool()
def list_passive_nodes() -> dict:
    """List all allocated passive nodes, jewels, and mastery selections."""
    return send_command("list_passive_nodes")


@mcp.tool()
def get_config() -> dict:
    """Get all configuration options (buffs, enemy settings, conditions)."""
    return send_command("get_config")


# ──────────────────────────────────────────────
# Write Tools
# ──────────────────────────────────────────────


@mcp.tool()
def set_config(values: dict[str, Any]) -> dict:
    """Set configuration values. Returns updated stats after recalculation.

    Example values: {"usePowerCharges": true, "enemyIsBoss": "Pinnacle", "conditionLowLife": true}

    Common config keys:
    - usePowerCharges, useFrenzyCharges, useEnduranceCharges (bool)
    - buffOnslaught, buffPhasing, buffFortify (bool)
    - conditionFullLife, conditionLowLife, conditionMoving (bool)
    - conditionUsingFlask (bool)
    - enemyIsBoss: "None" / "Boss" / "Pinnacle"
    - enemyPhysicalReduction, enemyFireResist, enemyColdResist, enemyLightningResist, enemyChaosResist (number)
    - bandit: "None" / "Oak" / "Kraityn" / "Alira"
    """
    return send_command("set_config", {"values": values})


@mcp.tool()
def add_item(raw_text: str, slot: str | None = None) -> dict:
    """Add an item from raw text (PoB format) and optionally equip it.

    The raw_text should be in standard PoB item format, e.g.:
    "Rarity: UNIQUE\\nHeadhunter\\nLeather Belt\\n..."

    Valid slots: Weapon 1, Weapon 2, Helmet, Body Armour, Gloves, Boots,
    Amulet, Ring 1, Ring 2, Ring 3, Belt, Flask 1-5, Graft 1-2.

    Returns updated stats after recalculation.
    """
    params = {"rawText": raw_text}
    if slot:
        params["slot"] = slot
    return send_command("add_item", params)


@mcp.tool()
def equip_item(item_id: int, slot: str) -> dict:
    """Equip an existing item (by ID) to a slot. Returns updated stats."""
    return send_command("equip_item", {"itemId": item_id, "slot": slot})


@mcp.tool()
def remove_item(slot: str) -> dict:
    """Unequip the item from a slot. Returns updated stats."""
    return send_command("remove_item", {"slot": slot})


@mcp.tool()
def alloc_node(node_id: int) -> dict:
    """Allocate a passive tree node. Automatically paths to it. Returns updated stats."""
    return send_command("alloc_node", {"nodeId": node_id})


@mcp.tool()
def dealloc_node(node_id: int) -> dict:
    """Deallocate a passive tree node (and dependent nodes). Returns updated stats."""
    return send_command("dealloc_node", {"nodeId": node_id})


@mcp.tool()
def add_gem(group_index: int, gem_name: str, level: int = 20, quality: int = 0, quality_id: str = "Default") -> dict:
    """Add a gem to a socket group (1-indexed). Returns updated stats.

    quality_id can be "Default", "Alternate1", "Alternate2", or "Alternate3".
    """
    return send_command(
        "add_gem",
        {
            "groupIndex": group_index,
            "gemName": gem_name,
            "level": level,
            "quality": quality,
            "qualityId": quality_id,
        },
    )


@mcp.tool()
def remove_gem(group_index: int, gem_index: int) -> dict:
    """Remove a gem from a socket group (both 1-indexed). Returns updated stats."""
    return send_command("remove_gem", {"groupIndex": group_index, "gemIndex": gem_index})


@mcp.tool()
def set_gem_level(
    group_index: int,
    gem_index: int,
    level: int | None = None,
    quality: int | None = None,
    quality_id: str | None = None,
) -> dict:
    """Change gem level, quality, or quality type (both indices 1-indexed). Returns updated stats."""
    params: dict[str, Any] = {"groupIndex": group_index, "gemIndex": gem_index}
    if level is not None:
        params["level"] = level
    if quality is not None:
        params["quality"] = quality
    if quality_id is not None:
        params["qualityId"] = quality_id
    return send_command("set_gem_level", params)


@mcp.tool()
def set_main_skill(group_index: int) -> dict:
    """Set the main active skill group (1-indexed). Returns updated stats."""
    return send_command("set_main_skill", {"groupIndex": group_index})


@mcp.tool()
def save_build() -> dict:
    """Save the current build to its file."""
    return send_command("save_build")


def main():
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
