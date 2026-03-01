# Path of Building MCP Server

Control Path of Building from AI agents via the [Model Context Protocol](https://modelcontextprotocol.io/).

## Prerequisites

- [uv](https://docs.astral.sh/uv/) (Python package manager)
- Path of Building running with MCP enabled (Settings > Enable MCP server)

## Setup

### Claude Code

```bash
claude mcp add pathofbuilding -- uv run --directory /path/to/PathOfBuilding/mcp pob-mcp
```

### Claude Desktop

Add to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "pathofbuilding": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/PathOfBuilding/mcp", "pob-mcp"]
    }
  }
}
```

### Other MCP clients

The server uses stdio transport. Run with:

```bash
cd mcp && uv run pob-mcp
```

## Enabling MCP in Path of Building

1. Open Path of Building
2. Click the settings/options button (gear icon)
3. Check **Enable MCP server**
4. Restart Path of Building

The MCP server runs inside the PoB process and communicates via file-based IPC in `~/.pob-mcp/`.

## Available Tools

### Read

| Tool | Description |
|------|-------------|
| `get_build_summary` | Class, ascendancy, level, bandits, pantheon |
| `get_all_stats` | Full calculated stats dump (~150 values) |
| `get_offense_stats` | DPS, crit, speed, hit chance, ailment DPS |
| `get_defense_stats` | Life, ES, armour, evasion, resistances, block |
| `list_skills` | All socket groups with gems, levels, quality |
| `list_items` | Equipped items and item list |
| `list_passive_nodes` | Allocated nodes, jewels, masteries |
| `get_config` | Configuration options (buffs, enemy, conditions) |

### Write

| Tool | Description |
|------|-------------|
| `set_config` | Set config values (charges, buffs, boss type, etc.) |
| `add_item` | Add item from raw text, optionally equip to slot |
| `equip_item` | Equip an existing item to a slot |
| `remove_item` | Unequip item from a slot |
| `alloc_node` | Allocate a passive tree node |
| `dealloc_node` | Deallocate a passive tree node |
| `add_gem` | Add gem to a socket group |
| `remove_gem` | Remove gem from a socket group |
| `set_gem_level` | Change gem level, quality, or quality type |
| `set_main_skill` | Set the active skill group |
| `save_build` | Save the build to file |

All write tools trigger recalculation and return updated stats.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `POB_IPC_DIR` | `~/.pob-mcp` | Override the IPC directory path |
