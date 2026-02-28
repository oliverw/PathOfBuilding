-- MCP Wrapper for Path of Building
-- Extends HeadlessWrapper with a stdin/stdout JSON command REPL
-- for read-only build analysis via the Model Context Protocol.

-- Add runtime/lua to path before loading anything (needed for xml, dkjson, etc.)
package.path = package.path .. ";../runtime/lua/?.lua;../runtime/lua/?/init.lua"

-- Redirect print and ConPrintf to stderr BEFORE loading HeadlessWrapper,
-- so that startup messages (e.g. "Loading main script...") don't pollute
-- the stdout JSON protocol used for MCP communication.
local _real_print = print
function print(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	io.stderr:write(table.concat(parts, "\t") .. "\n")
	io.stderr:flush()
end

-- Additional stubs not covered by HeadlessWrapper
function GetVirtualScreenSize()
	return 1920, 1080
end

-- Stub lua-utf8 if not available (only used for UI text and number formatting)
if not pcall(require, "lua-utf8") then
	package.preload["lua-utf8"] = function()
		return {
			reverse = string.reverse,
			gsub = string.gsub,
			find = string.find,
			sub = string.sub,
			match = string.match,
			next = function(s, i, offset)
				if offset and offset < 0 then
					return (i or 1) + offset
				else
					return (i or 1) + (offset or 1)
				end
			end,
		}
	end
end

-- Load the headless wrapper (sets up stubs, loads Launch.lua, initializes)
dofile("HeadlessWrapper.lua")

-- Re-override ConPrintf after HeadlessWrapper defines it, ensuring it goes to stderr
function ConPrintf(fmt, ...)
	io.stderr:write(string.format(fmt, ...) .. "\n")
	io.stderr:flush()
end

local json = require("dkjson")

-- Helpers

local function respond(id, result)
	local msg = json.encode({ id = id, result = result })
	io.stdout:write(msg .. "\n")
	io.stdout:flush()
end

local function respondError(id, message)
	local msg = json.encode({ id = id, error = message })
	io.stdout:write(msg .. "\n")
	io.stdout:flush()
end

local function requireBuild(id)
	if not build or not build.calcsTab or not build.calcsTab.mainOutput then
		respondError(id, "No build loaded. Use load_build first.")
		return false
	end
	return true
end

local function serializeTable(tbl, maxDepth, depth)
	depth = depth or 0
	maxDepth = maxDepth or 2
	if depth > maxDepth then return tostring(tbl) end

	local result = {}
	for k, v in pairs(tbl) do
		local key = tostring(k)
		if type(v) == "table" then
			if depth < maxDepth then
				result[key] = serializeTable(v, maxDepth, depth + 1)
			else
				result[key] = tostring(v)
			end
		elseif type(v) == "number" then
			-- Round to avoid floating point noise
			if v == math.floor(v) then
				result[key] = v
			else
				result[key] = tonumber(string.format("%.4f", v))
			end
		elseif type(v) == "string" or type(v) == "boolean" then
			result[key] = v
		end
		-- Skip functions, userdata, etc.
	end
	return result
end

-- Command handlers

local commands = {}

function commands.load_build(params)
	local filePath = params.file_path
	if not filePath then
		return nil, "file_path is required"
	end
	local fileHnd, errMsg = io.open(filePath, "r")
	if not fileHnd then
		return nil, "Cannot open file: " .. (errMsg or filePath)
	end
	local xmlText = fileHnd:read("*a")
	fileHnd:close()

	loadBuildFromXML(xmlText, filePath:match("([^/\\]+)%.%w+$") or "build")
	-- Run a couple of frames to ensure calculations complete
	runCallback("OnFrame")

	return { success = true, message = "Build loaded from " .. filePath }
end

function commands.load_build_xml(params)
	local xmlText = params.xml
	if not xmlText then
		return nil, "xml is required"
	end
	local name = params.name or "Imported Build"

	loadBuildFromXML(xmlText, name)
	runCallback("OnFrame")

	return { success = true, message = "Build loaded from XML string" }
end

function commands.get_build_summary(params)
	if not build then return nil, "No build loaded" end
	local spec = build.spec
	return {
		className = spec and spec.curClassName or "Unknown",
		ascendClassName = spec and spec.curAscendClassName or "None",
		level = build.characterLevel,
		bandit = build.configTab and build.configTab.input and build.configTab.input.bandit or "None",
		pantheonMajorGod = build.pantheonMajorGod or "None",
		pantheonMinorGod = build.pantheonMinorGod or "None",
	}
end

function commands.get_all_stats(params)
	if not build or not build.calcsTab then return nil, "No build loaded" end
	return serializeTable(build.calcsTab.mainOutput, 1)
end

function commands.get_offense_stats(params)
	if not build or not build.calcsTab then return nil, "No build loaded" end
	local out = build.calcsTab.mainOutput
	local stats = {}
	local offenseKeys = {
		"TotalDPS", "TotalDot", "CombinedDPS", "AverageDamage", "AverageBurstDamage",
		"AverageHit", "Speed", "CritChance", "CritMultiplier", "HitChance",
		"TotalMin", "TotalMax",
		"PoisonDPS", "IgniteDPS", "BleedDPS", "ImpaleDPS",
		"CausticGroundDPS", "BurningGroundDPS", "DecayDPS",
		"Cooldown", "ManaCost", "LifeCost",
		"ProjectileCount", "AreaOfEffectMod",
	}
	for _, key in ipairs(offenseKeys) do
		if out[key] ~= nil then
			stats[key] = out[key]
		end
	end
	return stats
end

function commands.get_defense_stats(params)
	if not build or not build.calcsTab then return nil, "No build loaded" end
	local out = build.calcsTab.mainOutput
	local stats = {}
	local defenseKeys = {
		"Life", "LifeUnreserved", "LifeRegen", "LifeRegenPercent",
		"LifeLeechGainRate", "LifeLeechGainPerHit",
		"Mana", "ManaUnreserved", "ManaRegen",
		"EnergyShield", "EnergyShieldRegen", "EnergyShieldLeechGainRate",
		"Ward",
		"Armour", "PhysicalDamageReduction",
		"Evasion", "MeleeEvadeChance", "ProjectileEvadeChance",
		"EffectiveBlockChance", "EffectiveSpellBlockChance",
		"EffectiveSpellSuppressionChance",
		"FireResist", "ColdResist", "LightningResist", "ChaosResist",
		"FireResistOverCap", "ColdResistOverCap", "LightningResistOverCap", "ChaosResistOverCap",
		"TotalEHP",
		"PowerCharges", "PowerChargesMax",
		"FrenzyCharges", "FrenzyChargesMax",
		"EnduranceCharges", "EnduranceChargesMax",
		"Str", "Dex", "Int",
	}
	for _, key in ipairs(defenseKeys) do
		if out[key] ~= nil then
			stats[key] = out[key]
		end
	end
	return stats
end

function commands.get_stat_breakdown(params)
	if not build or not build.calcsTab then return nil, "No build loaded" end
	local statKey = params.stat_key
	if not statKey then
		return nil, "stat_key is required"
	end

	local out = build.calcsTab.mainOutput
	local value = out[statKey]
	if value == nil then
		return nil, "Unknown stat: " .. statKey
	end

	-- Also check for breakdown data if available
	local breakdown = nil
	if build.calcsTab.mainEnv and build.calcsTab.mainEnv.player
	   and build.calcsTab.mainEnv.player.breakdown
	   and build.calcsTab.mainEnv.player.breakdown[statKey] then
		local raw = build.calcsTab.mainEnv.player.breakdown[statKey]
		if type(raw) == "table" then
			breakdown = serializeTable(raw, 2)
		end
	end

	return {
		stat = statKey,
		value = value,
		breakdown = breakdown,
	}
end

function commands.list_skills(params)
	if not build or not build.skillsTab then return nil, "No build loaded" end
	local groups = {}
	for i, group in ipairs(build.skillsTab.socketGroupList) do
		local gems = {}
		for j, gem in ipairs(group.gemList) do
			local gemInfo = {
				nameSpec = gem.nameSpec or "Unknown",
				level = gem.level,
				quality = gem.quality,
				enabled = gem.enabled ~= false,
				skillId = gem.skillId,
			}
			if gem.qualityId and type(gem.qualityId) == "table" and gem.qualityId.id then
				gemInfo.qualityType = gem.qualityId.id
			elseif gem.qualityId and type(gem.qualityId) == "string" then
				gemInfo.qualityType = gem.qualityId
			end
			gems[#gems + 1] = gemInfo
		end
		groups[#groups + 1] = {
			index = i,
			label = group.displayLabel or group.label or "",
			slot = group.slot or "",
			enabled = group.enabled ~= false,
			gems = gems,
		}
	end
	return groups
end

function commands.list_items(params)
	if not build or not build.itemsTab then return nil, "No build loaded" end
	local itemsTab = build.itemsTab
	local equipped = {}

	for slotName, slot in pairs(itemsTab.slots) do
		local itemId = slot.selItemId
		if itemId and itemId > 0 then
			local item = itemsTab.items[itemId]
			if item then
				local mods = {}
				if item.explicitModLines then
					for _, modLine in ipairs(item.explicitModLines) do
						if modLine.line then
							mods[#mods + 1] = modLine.line
						end
					end
				end
				local implicits = {}
				if item.implicitModLines then
					for _, modLine in ipairs(item.implicitModLines) do
						if modLine.line then
							implicits[#implicits + 1] = modLine.line
						end
					end
				end
				local enchants = {}
				if item.enchantModLines then
					for _, modLine in ipairs(item.enchantModLines) do
						if modLine.line then
							enchants[#enchants + 1] = modLine.line
						end
					end
				end
				equipped[slotName] = {
					name = item.name or "Unknown",
					baseName = item.baseName or "",
					rarity = item.rarity or "NORMAL",
					mods = mods,
					implicits = implicits,
					enchants = enchants,
				}
			end
		end
	end
	return equipped
end

function commands.list_passive_nodes(params)
	if not build or not build.spec then return nil, "No build loaded" end
	local spec = build.spec
	local nodes = {}
	for nodeId, node in pairs(spec.allocNodes) do
		nodes[#nodes + 1] = {
			id = nodeId,
			name = node.name or "Unknown",
			type = node.type or "",
			isKeystone = node.isKeystone or false,
			isNotable = node.isNotable or false,
		}
	end

	local masteries = {}
	if spec.masterySelections then
		for masteryId, effectId in pairs(spec.masterySelections) do
			masteries[#masteries + 1] = {
				masteryNodeId = masteryId,
				effectId = effectId,
			}
		end
	end

	local jewels = {}
	if spec.jewels then
		for socketId, jewelData in pairs(spec.jewels) do
			if type(jewelData) == "table" then
				jewels[#jewels + 1] = {
					socketNodeId = socketId,
					itemId = jewelData.id,
					name = jewelData.title or jewelData.name or "Unknown",
				}
			elseif type(jewelData) == "number" and jewelData > 0 then
				local item = build.itemsTab and build.itemsTab.items[jewelData]
				jewels[#jewels + 1] = {
					socketNodeId = socketId,
					itemId = jewelData,
					name = item and item.name or "Unknown",
				}
			end
		end
	end

	return {
		totalNodes = #nodes,
		nodes = nodes,
		masteries = masteries,
		jewels = jewels,
	}
end

function commands.get_config(params)
	if not build or not build.configTab then return nil, "No build loaded" end
	local input = build.configTab.input
	if not input then return nil, "No config data" end
	-- Serialize the config inputs (booleans, numbers, strings)
	local config = {}
	for k, v in pairs(input) do
		if type(v) == "boolean" or type(v) == "number" or type(v) == "string" then
			config[k] = v
		end
	end
	return config
end

-- Main REPL loop

-- Signal ready
io.stdout:write(json.encode({ ready = true }) .. "\n")
io.stdout:flush()

while true do
	local line = io.stdin:read("*l")
	if not line then break end

	local ok, request = pcall(json.decode, line)
	if not ok or type(request) ~= "table" then
		respondError(nil, "Invalid JSON")
	else
		local id = request.id
		local cmd = request.command
		local params = request.params or {}

		if not cmd then
			respondError(id, "Missing 'command' field")
		elseif not commands[cmd] then
			respondError(id, "Unknown command: " .. tostring(cmd))
		else
			local okCall, result, err = pcall(commands[cmd], params)
			if not okCall then
				respondError(id, "Internal error: " .. tostring(result))
			elseif err then
				respondError(id, err)
			else
				respond(id, result)
			end
		end
	end
end
