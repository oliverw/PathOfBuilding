# Architectural Patterns

## Class/OOP System

Path of Building uses a custom class system defined in [Common.lua:58-159](src/Modules/Common.lua#L58-L159).

### Defining classes

```lua
-- newClass(className, [parentClass, ...], constructorFn)
local MyControlClass = newClass("MyControl", "Control", "ControlHost", function(self, args)
    self.Control(anchor, x, y, w, h)   -- Call parent constructors explicitly
    self.ControlHost()
end)
```

- Classes are registered in `common.classes` and instantiated via `new("ClassName", ...)`
- Multiple inheritance is supported; parent methods are resolved via `__index` metamethods
- Child constructors must explicitly call each parent constructor (see pattern above)
- Classes are lazily loaded via `getClass()` — a class file is only loaded when first referenced

### Common inheritance chains

- **UI controls**: `Control` → `ButtonControl`, `EditControl`, `CheckBoxControl`, etc.
- **Containers**: `ControlHost` manages a collection of child `Control` instances
- **Multi-parent**: Many controls inherit both `Control` and `ControlHost` (e.g. tabs), some also inherit `UndoHandler` and `TooltipHost`
- **Mod storage**: `ModStore` → `ModDB` (name-indexed) and `ModList` (flat array)

## Module Loading

The application bootstraps through a chain defined in [Launch.lua](src/Launch.lua):

1. C++ engine calls `launch:OnInit()`, `launch:OnFrame()`, input handlers
2. `LoadModule("Modules/Main")` creates the global `main` ControlHost
3. Main loads `Data`, `Build`, `BuildList`, and other modules on demand
4. `PLoadModule(path)` provides protected loading with error handling

Key globals established at startup:
- `launch` — C++ callback receiver ([Launch.lua](src/Launch.lua))
- `main` — application root ControlHost ([Main.lua](src/Modules/Main.lua))
- `data` — game data singleton ([Data.lua](src/Modules/Data.lua))
- `common` — utility library and class registry ([Common.lua](src/Modules/Common.lua))

## UI Control Hierarchy

### Base control ([Control.lua](src/Classes/Control.lua))
- Anchor-based positioning: `{point, otherControl, otherPoint, offsetX, offsetY}`
- Property system: `GetProperty(name)` returns a value or calls a function dynamically
- `IsShown()`, `IsEnabled()`, `GetSize()` — virtual methods overridden by subclasses

### Control host ([ControlHost.lua](src/Classes/ControlHost.lua))
- Manages child controls collection
- Routes input through `ProcessControlsInput(inputEvents, viewPort)`
- Handles focus management via `SelectControl(control)`

### Event/callback pattern
- No event bus — controls use direct callbacks passed to constructors:
  - `ButtonControl`: `onClick()`
  - `EditControl`: `changeFunc(newText)`
  - `DropDownControl`: `selFunc(index, value)`
- Lifecycle: `OnKeyDown/OnKeyUp/OnChar`, `OnFocusGained/OnFocusLost`, `Draw(viewPort)`

### Tab system
- Each build tab (`CalcsTab`, `ItemsTab`, `SkillsTab`, `TreeTab`, `ConfigTab`) inherits from `Control` + `ControlHost`
- Tabs are registered in [Build.lua](src/Modules/Build.lua) and switched via `viewMode`
- `CalcsTab` uses sections: `self:NewSection(priority, name, numCols, color, data, refreshFunc)`

## Modifier (Mod) System

Three-layer architecture for game stat modifiers:

### ModStore ([ModStore.lua](src/Classes/ModStore.lua)) — base class
- Properties: `parent` (parent DB for inheritance), `actor`, `multipliers`, `conditions`
- Core methods: `AddMod()`, `ScaleAddMod()`, `NewMod()`
- Magic metatables auto-create `multiplierName["X"]` → `"Multiplier:X"` and `conditionName["X"]` → `"Condition:X"`

### ModDB ([ModDB.lua](src/Classes/ModDB.lua)) — name-indexed storage
- Stores mods by name: `self.mods[modName] = {mod1, mod2, ...}`
- Query methods: `SumInternal()`, `MoreInternal()` with flag/keyword/source filtering
- Used for player, enemy, and minion stat databases

### ModList ([ModList.lua](src/Classes/ModList.lua)) — flat array
- Simpler flat list of mods, used for temporary/skill-specific modifiers

### Mod structure
Mods follow a consistent structure:
```lua
{ name = "FireDamage", type = "INC"|"MORE"|"BASE"|"FLAG", value = 50,
  flags = ModFlag.Fire, keywordFlags = KeywordFlag.Hit, source = "Item:ring1" }
```
Types: `BASE` (flat addition), `INC` (additive percentage), `MORE` (multiplicative percentage), `FLAG` (boolean)

## Calculation Pipeline

Orchestrated by [Calcs.lua](src/Modules/Calcs.lua), the pipeline stages are:

1. **CalcSetup** — build `env` object with player/enemy/minion ModDBs, apply tree nodes, items, skills
2. **CalcActiveSkill** — resolve skill gems, supports, and active skill properties
3. **CalcDefence** — armor, evasion, resistances, life/ES, block, dodge
4. **CalcOffence** — damage types, conversion chains, hit/DoT DPS, crit, penetration
5. **CalcTriggers** — triggered effects (CoC, CwDT, etc.)
6. **CalcPerform** — final output: attack speed, cast speed, total DPS

### Environment object (`env`)
The central data container passed through the pipeline:
```lua
env = {
    build, mode, player = {modDB, itemList, output, ...},
    enemy = {modDB, output, ...}, minion = {modDB, output, ...},
    skillsTab, allocNodes, radiusJewelList, auxSkillList
}
```

### Caching
- `getNodeCalculator()` — cached calculator for passive tree node diffs
- `getMiscCalculator()` — cached calculator for item/gem changes
- `build.buildFlag = true` signals recalculation is needed

## State Management

[Build.lua](src/Modules/Build.lua) is the central state manager:

- **Persisted state** (XML serialization): character level, bandit, pantheon, allocated nodes, equipped items, skill gems, config options
- **Runtime state**: `modFlag` (dirty flag), `unsaved`, `outputRevision` (cache invalidation)
- **Dirty propagation**: changes set `self.buildFlag = true`, checked each frame to trigger recalculation

## Data Loading

[Data.lua](src/Modules/Data.lua) loads game data as Lua modules:

- `LoadModule("Data/Global")`, `LoadModule("Data/Gems")`, etc.
- Auto-generated files (marked `-- This file is automatically generated, do not edit!`) live in [src/Data/](src/Data/)
- Generated by export scripts in [src/Export/Scripts/](src/Export/Scripts/) from GGPK game files
- Key data files: `ModCache.lua` (2.2 MB), `ModItem.lua` (4.0 MB), `Gems.lua` (374 KB)

## Performance Patterns

Used consistently across hot paths:

- **Local caching of globals**: `local pairs = pairs; local m_max = math.max` at module top to avoid global lookups
- **Coroutine yielding**: `pairsYield()` breaks long iterations across frames to prevent UI freezes
- **JIT tuning**: `jit.opt.start('maxtrace=4000','maxmcode=8192')` in [Launch.lua](src/Launch.lua)
- **GC tuning**: `collectgarbage("setpause", 400)` to reduce GC frequency

## ModParser Pattern

[ModParser.lua](src/Modules/ModParser.lua) (628 KB) is the largest single module:

- Parses human-readable mod text into structured mod objects
- Generates [ModCache.lua](src/Data/ModCache.lua) — a cached version of all parsed mods
- Must be regenerated (Ctrl+F5 in dev mode) when mod parsing logic changes
- CI validates ModCache hasn't changed unexpectedly
