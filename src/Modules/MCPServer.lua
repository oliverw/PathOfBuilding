-- MCP Server for Path of Building
-- File-based IPC server that exposes build data and controls to AI agents
-- Runs inside the GUI process, polled every frame via main.onFrameFuncs
--
-- Protocol: Python writes a JSON request to mcp_request.json, Lua polls for it
-- each frame, processes the command, writes mcp_response.json, deletes the request.
-- An mcp_lock file is used to prevent races.

local MCPServer = {}

local dkjson = require("dkjson")

local t_insert = table.insert
local t_remove = table.remove

local LOG_FILE = "mcp.log"

local function log(fmt, ...)
	local msg = string.format(fmt, ...)
	ConPrintf("%s", msg)
	local f = io.open(LOG_FILE, "a")
	if f then
		f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. msg .. "\n")
		f:close()
	end
end

local function isWine()
	-- Wine maps the Linux root filesystem to Z:\
	-- If GetScriptPath() starts with "Z:" we're running under Wine
	local scriptPath = GetScriptPath()
	return scriptPath and scriptPath:sub(1, 2):upper() == "Z:"
end

local function getIPCDir()
	if isWine() then
		-- Under Wine: read the real Linux HOME from /etc/passwd or use Z: + known path
		-- Wine exposes Linux HOME but may rewrite it to Windows format
		-- The most reliable approach: use Z: prefix with the HOME value
		local home = os.getenv("HOME")
		if home then
			-- HOME might be "/home/oliver" (Unix) or "C:\users\oliver" (Wine-rewritten)
			if home:match("^/") then
				return "Z:" .. home .. "/.pob-mcp/"
			end
			-- HOME is Windows-style under Wine — try to find real home from USERPROFILE or /etc/passwd
		end
		-- Try reading /etc/passwd via Z: drive to find the real home
		local user = os.getenv("USER") or os.getenv("USERNAME")
		if user then
			local f = io.open("Z:/etc/passwd", "r")
			if f then
				for line in f:lines() do
					local u, h = line:match("^([^:]+):[^:]*:[^:]*:[^:]*:[^:]*:([^:]+)")
					if u == user then
						f:close()
						return "Z:" .. h .. "/.pob-mcp/"
					end
				end
				f:close()
			end
		end
		-- Last resort: extract from GetScriptPath() which starts with Z:/home/user/...
		local linuxHome = GetScriptPath():match("^(Z:/home/[^/]+)")
		if linuxHome then
			return linuxHome .. "/.pob-mcp/"
		end
	end
	-- Native Linux
	local home = os.getenv("HOME")
	if home and home:match("^/") then
		return home .. "/.pob-mcp/"
	end
	-- Native Windows
	local userProfile = os.getenv("USERPROFILE")
	if userProfile then
		return userProfile .. "\\.pob-mcp\\"
	end
	-- Fallback to script directory
	return GetScriptPath() .. "/"
end

function MCPServer:Start()
	self.ipcDir = getIPCDir()
	MakeDir(self.ipcDir)
	self.requestFile = self.ipcDir .. "mcp_request.json"
	self.responseFile = self.ipcDir .. "mcp_response.json"
	self.lockFile = self.ipcDir .. "mcp_lock"
	-- Clean up stale files from previous runs
	os.remove(self.requestFile)
	os.remove(self.responseFile)
	os.remove(self.lockFile)
	-- Register frame callback
	main.onFrameFuncs["MCPServer"] = function() self:OnFrame() end
	log("MCP Server: Started (file IPC in %s)", self.ipcDir)
	return true
end

function MCPServer:Stop()
	main.onFrameFuncs["MCPServer"] = nil
	if self.ipcDir then
		os.remove(self.requestFile)
		os.remove(self.responseFile)
		os.remove(self.lockFile)
	end
	log("MCP Server: Stopped")
end

function MCPServer:OnFrame()
	-- Check if a request file exists
	local f = io.open(self.requestFile, "r")
	if not f then return end
	local content = f:read("*a")
	f:close()
	-- Delete request file immediately to signal we've consumed it
	os.remove(self.requestFile)
	if not content or #content == 0 then return end

	-- Process the request
	local ok, request = pcall(dkjson.decode, content)
	if not ok or type(request) ~= "table" then
		self:WriteResponse(nil, "Invalid JSON")
		return
	end

	local cmd = request.command
	local params = request.params or {}
	local id = request.id

	local handler = self.handlers[cmd]
	if not handler then
		self:WriteResponse(id, "Unknown command: " .. tostring(cmd))
		return
	end

	local okCall, result, err = pcall(handler, self, params)
	if not okCall then
		self:WriteResponse(id, "Error: " .. tostring(result))
		return
	end
	if err then
		self:WriteResponse(id, err)
		return
	end
	self:WriteResponse(id, nil, result)
end

function MCPServer:WriteResponse(id, err, result)
	local response = { id = id }
	if err then
		response.error = err
	else
		response.result = result
	end
	local json = dkjson.encode(response)
	-- Write to a temp file first, then rename for atomicity
	local tmpFile = self.responseFile .. ".tmp"
	local f = io.open(tmpFile, "w")
	if f then
		f:write(json)
		f:close()
		os.rename(tmpFile, self.responseFile)
	end
end

-- Helper: get the active build object, or nil + error
function MCPServer:GetBuild()
	if not main or main.mode ~= "BUILD" then
		return nil, "No build loaded"
	end
	return main.modes["BUILD"]
end

-- Helper: trigger recalculation and return summary stats
function MCPServer:RecalcAndSummary(build)
	-- Directly recalculate instead of going through OnFrame to avoid re-entrancy
	wipeGlobalCache()
	build.outputRevision = build.outputRevision + 1
	build.calcsTab:BuildOutput()
	build:RefreshStatList()
	build.buildFlag = false
	return self:BuildQuickStats(build)
end

function MCPServer:BuildQuickStats(build)
	local out = build.calcsTab.mainOutput
	if not out then return {} end
	return {
		TotalDPS = out.TotalDPS,
		CombinedDPS = out.CombinedDPS,
		Life = out.Life,
		EnergyShield = out.EnergyShield,
		Ward = out.Ward,
		Armour = out.Armour,
		Evasion = out.Evasion,
	}
end

--------------------------------------------------------------------
-- Command Handlers
--------------------------------------------------------------------
MCPServer.handlers = {}

-- get_build_summary: Class, ascendancy, level, bandits, pantheon
MCPServer.handlers["get_build_summary"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	local spec = build.spec
	local configInput = build.configTab.configSets[build.configTab.activeConfigSetId].input
	return {
		className = spec.curClassName,
		ascendClassName = spec.curAscendClassName,
		secondaryAscendClassName = spec.curSecondaryAscendClassName,
		level = build.characterLevel,
		bandit = configInput["bandit"] or "None",
		pantheonMajorGod = configInput["pantheonMajorGod"],
		pantheonMinorGod = configInput["pantheonMinorGod"],
		characterName = build.buildName,
	}
end

-- get_all_stats: Full mainOutput dump
MCPServer.handlers["get_all_stats"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	local out = build.calcsTab.mainOutput
	if not out then return nil, "No calc output available" end
	local result = {}
	for k, v in pairs(out) do
		if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
			result[k] = v
		end
	end
	return result
end

-- get_offense_stats: DPS, crit, speed, ailment breakdown
MCPServer.handlers["get_offense_stats"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	local out = build.calcsTab.mainOutput
	if not out then return nil, "No calc output available" end
	return {
		TotalDPS = out.TotalDPS,
		CombinedDPS = out.CombinedDPS,
		FullDPS = out.FullDPS,
		AverageDamage = out.AverageDamage,
		Speed = out.Speed,
		HitSpeed = out.HitSpeed,
		CritChance = out.CritChance,
		CritMultiplier = out.CritMultiplier,
		HitChance = out.HitChance,
		TotalDot = out.TotalDot,
		BleedDPS = out.BleedDPS,
		IgniteDPS = out.IgniteDPS,
		PoisonDPS = out.PoisonDPS,
		Impale = out.ImpaleHit,
		WithBleedDPS = out.WithBleedDPS,
		WithPoisonDPS = out.WithPoisonDPS,
		WithIgniteDPS = out.WithIgniteDPS,
		ManaCost = out.ManaCost,
		ManaPercentCost = out.ManaPercentCost,
		LifeCost = out.LifeCost,
	}
end

-- get_defense_stats: Life, ES, armour, evasion, resists, block, suppress
MCPServer.handlers["get_defense_stats"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	local out = build.calcsTab.mainOutput
	if not out then return nil, "No calc output available" end
	return {
		Life = out.Life,
		LifeUnreserved = out.LifeUnreserved,
		LifeRegen = out.LifeRegen,
		LifeLeechRate = out.LifeLeechRate,
		EnergyShield = out.EnergyShield,
		EnergyShieldRegen = out.EnergyShieldRegen,
		EnergyShieldLeechRate = out.EnergyShieldLeechRate,
		Mana = out.Mana,
		ManaUnreserved = out.ManaUnreserved,
		ManaRegen = out.ManaRegen,
		Ward = out.Ward,
		Armour = out.Armour,
		Evasion = out.Evasion,
		BlockChance = out.BlockChance,
		SpellBlockChance = out.SpellBlockChance,
		SpellSuppressionChance = out.SpellSuppressionChance,
		FireResist = out.FireResist,
		FireResistOverCap = out.FireResistOverCap,
		ColdResist = out.ColdResist,
		ColdResistOverCap = out.ColdResistOverCap,
		LightningResist = out.LightningResist,
		LightningResistOverCap = out.LightningResistOverCap,
		ChaosResist = out.ChaosResist,
		ChaosResistOverCap = out.ChaosResistOverCap,
		PhysicalDamageReduction = out.PhysicalDamageReduction,
	}
end

-- list_skills: All socket groups with gems
MCPServer.handlers["list_skills"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	local result = {}
	for i, group in ipairs(build.skillsTab.socketGroupList) do
		local gems = {}
		for j, gem in ipairs(group.gemList) do
			t_insert(gems, {
				name = gem.nameSpec or (gem.gemData and gem.gemData.name) or "Unknown",
				level = gem.level,
				quality = gem.quality,
				qualityId = gem.qualityId,
				enabled = gem.enabled,
				gemId = gem.gemId,
				skillId = gem.skillId,
			})
		end
		t_insert(result, {
			index = i,
			label = group.label or "",
			enabled = group.enabled,
			slot = group.slot,
			mainActiveSkill = group.mainActiveSkill,
			includeInFullDPS = group.includeInFullDPS,
			gems = gems,
		})
	end
	return { mainSocketGroup = build.mainSocketGroup, socketGroups = result }
end

-- list_items: Equipped items per slot
MCPServer.handlers["list_items"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	local equipped = {}
	for _, slotName in ipairs(build.itemsTab.slotOrder) do
		local slot = build.itemsTab.slots[slotName]
		if slot and slot.selItemId and slot.selItemId > 0 then
			local item = build.itemsTab.items[slot.selItemId]
			if item then
				equipped[slotName] = {
					id = item.id,
					name = item.title or item.name or "Unknown",
					baseName = item.baseName,
					type = item.type,
					rarity = item.rarity,
					rawLines = item.rawLines,
				}
			end
		end
	end
	-- Also list all items in the item list
	local allItems = {}
	for _, id in ipairs(build.itemsTab.itemOrderList) do
		local item = build.itemsTab.items[id]
		if item then
			t_insert(allItems, {
				id = item.id,
				name = item.title or item.name or "Unknown",
				baseName = item.baseName,
				type = item.type,
				rarity = item.rarity,
			})
		end
	end
	return { equipped = equipped, allItems = allItems }
end

-- list_passive_nodes: Allocated nodes, jewels, masteries
MCPServer.handlers["list_passive_nodes"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	local nodes = {}
	for id, node in pairs(build.spec.allocNodes) do
		t_insert(nodes, {
			id = id,
			name = node.dn,
			type = node.type,
			ascendancyName = node.ascendancyName,
			isKeystone = node.isKeystone,
			isNotable = node.isNotable,
			isMastery = node.isMastery,
		})
	end
	local jewels = {}
	for nodeId, itemId in pairs(build.spec.jewels) do
		if itemId and itemId > 0 then
			local item = build.itemsTab.items[itemId]
			jewels[tostring(nodeId)] = {
				itemId = itemId,
				name = item and (item.title or item.name) or "Unknown",
			}
		end
	end
	local masteries = {}
	for nodeId, effectId in pairs(build.spec.masterySelections) do
		masteries[tostring(nodeId)] = effectId
	end
	return {
		allocatedNodes = nodes,
		totalPoints = build.spec.allocNodes and #nodes or 0,
		jewels = jewels,
		masteries = masteries,
	}
end

-- get_config: Current configuration state
MCPServer.handlers["get_config"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	local input = build.configTab.configSets[build.configTab.activeConfigSetId].input
	local result = {}
	for k, v in pairs(input) do
		if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
			result[k] = v
		end
	end
	return result
end

--------------------------------------------------------------------
-- Write Handlers
--------------------------------------------------------------------

-- set_config: Set config values
MCPServer.handlers["set_config"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	if not params.values or type(params.values) ~= "table" then
		return nil, "params.values must be a table of key-value pairs"
	end
	local input = build.configTab.configSets[build.configTab.activeConfigSetId].input
	for k, v in pairs(params.values) do
		input[k] = v
	end
	build.configTab:BuildModList()
	return self:RecalcAndSummary(build)
end

-- add_item: Add item from raw text and optionally equip to slot
MCPServer.handlers["add_item"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	if not params.rawText or type(params.rawText) ~= "string" then
		return nil, "params.rawText is required"
	end
	local newItem = new("Item", params.rawText)
	if not newItem.base then
		return nil, "Failed to parse item — invalid or unrecognized base type"
	end
	newItem:NormaliseQuality()
	build.itemsTab:AddItem(newItem, true)
	if params.slot then
		local slot = build.itemsTab.slots[params.slot]
		if not slot then
			return nil, "Unknown slot: " .. tostring(params.slot)
		end
		slot:SetSelItemId(newItem.id)
		build.itemsTab:PopulateSlots()
	end
	build.itemsTab:AddUndoState()
	return self:RecalcAndSummary(build), nil
end

-- equip_item: Equip existing item to a slot
MCPServer.handlers["equip_item"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	if not params.itemId or not params.slot then
		return nil, "params.itemId and params.slot are required"
	end
	local item = build.itemsTab.items[params.itemId]
	if not item then
		return nil, "Item not found: " .. tostring(params.itemId)
	end
	local slot = build.itemsTab.slots[params.slot]
	if not slot then
		return nil, "Unknown slot: " .. tostring(params.slot)
	end
	slot:SetSelItemId(params.itemId)
	build.itemsTab:PopulateSlots()
	build.itemsTab:AddUndoState()
	return self:RecalcAndSummary(build)
end

-- remove_item: Unequip an item from a slot (set slot to empty)
MCPServer.handlers["remove_item"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	if not params.slot then
		return nil, "params.slot is required"
	end
	local slot = build.itemsTab.slots[params.slot]
	if not slot then
		return nil, "Unknown slot: " .. tostring(params.slot)
	end
	slot:SetSelItemId(0)
	build.itemsTab:PopulateSlots()
	build.itemsTab:AddUndoState()
	return self:RecalcAndSummary(build)
end

-- alloc_node: Allocate a passive node (with automatic pathing)
MCPServer.handlers["alloc_node"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	if not params.nodeId then
		return nil, "params.nodeId is required"
	end
	local node = build.spec.nodes[params.nodeId]
	if not node then
		return nil, "Node not found: " .. tostring(params.nodeId)
	end
	if node.alloc then
		return nil, "Node already allocated"
	end
	build.spec:AllocNode(node)
	build.spec:AddUndoState()
	return self:RecalcAndSummary(build)
end

-- dealloc_node: Deallocate a passive node
MCPServer.handlers["dealloc_node"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	if not params.nodeId then
		return nil, "params.nodeId is required"
	end
	local node = build.spec.nodes[params.nodeId]
	if not node then
		return nil, "Node not found: " .. tostring(params.nodeId)
	end
	if not node.alloc then
		return nil, "Node not allocated"
	end
	build.spec:DeallocNode(node)
	build.spec:AddUndoState()
	return self:RecalcAndSummary(build)
end

-- add_gem: Add gem to a socket group
MCPServer.handlers["add_gem"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	if not params.groupIndex or not params.gemName then
		return nil, "params.groupIndex and params.gemName are required"
	end
	local group = build.skillsTab.socketGroupList[params.groupIndex]
	if not group then
		return nil, "Socket group not found at index: " .. tostring(params.groupIndex)
	end
	local gemInstance = {
		nameSpec = params.gemName,
		level = params.level or 20,
		quality = params.quality or 0,
		qualityId = params.qualityId or "Default",
		enabled = true,
		enableGlobal1 = true,
		enableGlobal2 = false,
		count = 1,
	}
	t_insert(group.gemList, gemInstance)
	build.skillsTab:ProcessSocketGroup(group)
	build.skillsTab:AddUndoState()
	return self:RecalcAndSummary(build)
end

-- remove_gem: Remove gem from a socket group
MCPServer.handlers["remove_gem"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	if not params.groupIndex or not params.gemIndex then
		return nil, "params.groupIndex and params.gemIndex are required"
	end
	local group = build.skillsTab.socketGroupList[params.groupIndex]
	if not group then
		return nil, "Socket group not found at index: " .. tostring(params.groupIndex)
	end
	if not group.gemList[params.gemIndex] then
		return nil, "Gem not found at index: " .. tostring(params.gemIndex)
	end
	t_remove(group.gemList, params.gemIndex)
	build.skillsTab:ProcessSocketGroup(group)
	build.skillsTab:AddUndoState()
	return self:RecalcAndSummary(build)
end

-- set_gem_level: Change gem level/quality
MCPServer.handlers["set_gem_level"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	if not params.groupIndex or not params.gemIndex then
		return nil, "params.groupIndex and params.gemIndex are required"
	end
	local group = build.skillsTab.socketGroupList[params.groupIndex]
	if not group then
		return nil, "Socket group not found at index: " .. tostring(params.groupIndex)
	end
	local gem = group.gemList[params.gemIndex]
	if not gem then
		return nil, "Gem not found at index: " .. tostring(params.gemIndex)
	end
	if params.level then gem.level = params.level end
	if params.quality then gem.quality = params.quality end
	if params.qualityId then gem.qualityId = params.qualityId end
	build.skillsTab:ProcessSocketGroup(group)
	return self:RecalcAndSummary(build)
end

-- set_main_skill: Set the main active skill group
MCPServer.handlers["set_main_skill"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	if not params.groupIndex then
		return nil, "params.groupIndex is required"
	end
	if not build.skillsTab.socketGroupList[params.groupIndex] then
		return nil, "Socket group not found at index: " .. tostring(params.groupIndex)
	end
	build.mainSocketGroup = params.groupIndex
	return self:RecalcAndSummary(build)
end

-- save_build: Save current build to file
MCPServer.handlers["save_build"] = function(self, params)
	local build, err = self:GetBuild()
	if not build then return nil, err end
	build:SaveDBFile()
	return { saved = true, fileName = build.dbFileName }
end

return MCPServer
