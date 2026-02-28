# Path of Building MCP Server

An MCP (Model Context Protocol) server that gives AI agents read-only access to Path of Building's calculation engine for build analysis and optimization recommendations.

## Prerequisites

- **[uv](https://docs.astral.sh/uv/)** — Python package runner (handles Python and dependencies automatically)
- **LuaJIT** — must be on your PATH (or set `LUAJIT_PATH` env var)

### Installing uv

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### Installing LuaJIT

- **Fedora/RHEL**: `sudo dnf install luajit`
- **Ubuntu/Debian**: `sudo apt install luajit`
- **Arch**: `sudo pacman -S luajit`
- **macOS**: `brew install luajit`
- **Windows**: Use the bundled `runtime/` from Path of Building, or install via [LuaJIT releases](https://luajit.org/download.html)

### Installing lua-utf8 (optional)

The MCP wrapper includes a built-in stub for `lua-utf8`, but for full Unicode support you can install it via luarocks:

```bash
luarocks install luautf8
```

## Usage

### With Claude Code (stdio transport)

```bash
claude mcp add pathofbuilding -- uv run /path/to/PathOfBuilding/mcp/server.py
```

Or manually add to your Claude Code MCP settings (`~/.claude/settings.json`):

```json
{
  "mcpServers": {
    "pathofbuilding": {
      "command": "uv",
      "args": ["run", "/path/to/PathOfBuilding/mcp/server.py"],
      "env": {}
    }
  }
}
```

### With Claude Desktop

Add to your Claude Desktop config (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "pathofbuilding": {
      "command": "uv",
      "args": ["run", "/path/to/PathOfBuilding/mcp/server.py"]
    }
  }
}
```

### Standalone (HTTP transport)

```bash
uv run mcp/server.py --transport http
# Server starts on http://127.0.0.1:8000
```

## Available Tools

| Tool | Description |
|------|-------------|
| `load_build` | Load a build from an XML file path |
| `load_build_code` | Load a build from a build code, `pob://` URL, or website URL |
| `get_build_summary` | Class, ascendancy, level, bandit, pantheon |
| `get_all_stats` | Full calculated stats (~150 values) |
| `get_offense_stats` | DPS, crit, speed, ailment damage |
| `get_defense_stats` | Life, ES, armour, evasion, resists, EHP |
| `get_stat_breakdown` | Detailed calculation breakdown for a stat |
| `list_skills` | All socket groups with gem details |
| `list_items` | Equipped items with mod lines |
| `list_passive_nodes` | Allocated nodes, masteries, jewels |
| `get_config` | Build configuration and toggle states |

## Workflow

### From the GUI
1. Open your build in Path of Building GUI
2. Save your build (Ctrl+S)
3. Ask the AI agent to `load_build` with the file path
4. The agent reads your saved build file and provides recommendations
5. Apply changes in the GUI, save, and ask again

### From a build code or URL
1. Provide any of: a raw build code, a `pob://` URL, or a website link (pobb.in, maxroll, poe.ninja, pastebin, rentry, poedb)
2. Ask the AI agent to `load_build_code` with it
3. The agent downloads (if needed), decodes, and analyzes the build

## Architecture

```
AI Agent <--MCP (stdio/HTTP)--> Python Server <--stdin/stdout JSON--> LuaJIT (PoB headless engine)
```

The Python server manages a persistent LuaJIT subprocess running PoB's calculation engine in headless mode. The GUI is completely unaffected.
