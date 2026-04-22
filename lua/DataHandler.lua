--[[
	DataHandler

	TODO: ADD DESCRIPTION
	
	~ Orignal Creator, andrew@ber.gg
	~ Reworked/Cleanup by, erringpaladin10@vtilserver.com
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local DataStoreService = game:GetService("DataStoreService")

local Saving = require(game.ServerScriptService.Saving)
local Utl = require(game.ServerScriptService.Utl)

local ShuttingDown = false

local function savePlayerData(player)
	pcall(function()
		Utl.CheckPasses(player)
	end)

	local playerData = Utl.GetPlayerData(player.userId)
	if player:FindFirstChild("DataLoaded") and playerData ~= nil then
		playerData.Inventory = playerData.Inventory
		playerData.BaseData = playerData.BaseData
		playerData.Emblems = playerData.Emblems
		playerData.Storage = playerData.Storage
		playerData.XP = player:FindFirstChild("XP") and player.XP.Value
		playerData.Level = player:FindFirstChild("Level") and player.Level.Value
		playerData.Pickaxe = player:FindFirstChild("Pickaxe") and player.Pickaxe.Value
		playerData.Mute = player:FindFirstChild("Mute") and Utl.BoolToInt(player.Mute.Value)
		playerData.Gold = player:FindFirstChild("Gold") and player.Gold.Value
		playerData.Crystals = player:FindFirstChild("Crystals") and player.Crystals.Value
		playerData.LastGift = player:FindFirstChild("LastGift") and player.LastGift.Value
		playerData.Emblem = player:FindFirstChild("Emblem") and player.Emblem.Value
		playerData.Tutorial = player:FindFirstChild("Tutorial") and player.Tutorial.Value
		playerData.GoldQuest = player:FindFirstChild("GoldQuest") and player.GoldQuest.Value
		playerData.EventStatus = player:FindFirstChild("EventStatus") and player.EventStatus.Value

		if playerData.TimeStamp and playerData.TimeStamp > 0 then
			playerData.TotalPlaytime = playerData.TotalPlaytime + (playerData.TimeStamp - os.time())
		end

		playerData.TimeStamp = os.time()
		playerData.LifetimeOreTotal = playerData.LifetimeOreTotal

		local success, errorMessage = Saving.SaveData(player, playerData)

		task.spawn(function()
			pcall(function()
				local leaderboardStore = DataStoreService:GetOrderedDataStore("TopMiner" .. tostring(Utl.CurrentDay()))
				leaderboardStore:IncrementAsync(player.userId, player.OreMined.Value)
				playerData.LifetimeOreTotal = playerData.LifetimeOreTotal + player.OreMined.Value
				player.OreMined.Value = 0
			end)
		end)

		return success, errorMessage
	end
end

local function ensurePlayerDataShape(playerData)
	playerData.LifetimeOreTotal = playerData.LifetimeOreTotal or 0
	playerData.TotalPlaytime = playerData.TotalPlaytime or 0
	playerData.Inventory = playerData.Inventory or {}
	playerData.Storage = playerData.Storage or {}
	playerData.BaseData = playerData.BaseData or {}
	playerData.Emblems = playerData.Emblems or {}
	playerData.Pickaxes = playerData.Pickaxes or {}
	playerData.TimeStamp = os.time()
end

local function populateOwnedPickaxes(playerData)
	for _, pickaxe in pairs(ReplicatedStorage.Pickaxes:GetChildren()) do
		playerData.Pickaxes[pickaxe.Name] = playerData.Pickaxes[pickaxe.Name] or false
	end

	if playerData.Pickaxe ~= nil then
		playerData.Pickaxes[playerData.Pickaxe] = true
	end
end

local function populateInventoryDefaults(playerData)
	for _, ore in pairs(ReplicatedStorage.Ores:GetChildren()) do
		playerData.Inventory[ore.Name] = playerData.Inventory[ore.Name] or 0
		playerData.Storage[ore.Name] = playerData.Storage[ore.Name] or 0
	end

	for _, item in pairs(ServerStorage.BaseParts:GetChildren()) do
		playerData.BaseData[item.Name] = playerData.BaseData[item.Name] or 0
	end

	for _, emblem in pairs(ReplicatedStorage.Emblems:GetChildren()) do
		playerData.Emblems[emblem.Name] = playerData.Emblems[emblem.Name] or false
	end
end

local function createValue(parent, className, name, value)
	local instance = Instance.new(className)
	instance.Name = name
	instance.Value = value
	instance.Parent = parent
	return instance
end

local function createPlayerRuntimeValues(player, playerData)
	createValue(player, "IntValue", "OreMined", 0)

	local goldQuest = createValue(player, "StringValue", "GoldQuest", playerData.GoldQuest or "")
	if playerData.GoldQuest ~= "Done" and playerData.GoldQuest ~= "Started" and playerData.GoldQuest ~= "Awarded" then
		playerData.GoldQuest = ""
		goldQuest.Value = ""
	end

	createValue(player, "BoolValue", "Loading", true)
	createValue(player, "StringValue", "Emblem", playerData.Emblem or "")
	local xp = createValue(player, "IntValue", "XP", playerData.XP or 0)
	local level = createValue(player, "IntValue", "Level", playerData.Level or 1)
	createValue(player, "NumberValue", "Gold", playerData.Gold or 50)
	createValue(player, "NumberValue", "Crystals", playerData.Crystals or 0)
	createValue(player, "IntValue", "LastGift", playerData.LastGift or 0)
	createValue(player, "StringValue", "Pickaxe", playerData.Pickaxe or "Stone")
	createValue(player, "BoolValue", "Mute", Utl.IntToBool(playerData.Mute) or false)

	local tutorial = Instance.new("IntValue")
	tutorial.Name = "Tutorial"
	if level.Value > 4 then
		tutorial.Value = -1
	elseif playerData.BaseData.Teleporter > 0 and playerData.Tutorial and playerData.Tutorial == 0 then
		tutorial.Value = 1
	else
		tutorial.Value = playerData.Tutorial or 0
	end
	tutorial.Parent = player

	local teleportPad = Instance.new("ObjectValue")
	teleportPad.Name = "TPPad"
	teleportPad.Parent = player

	return xp, level
end

local function bindPlayerValueEvents(player, xp, level)
	xp.Changed:Connect(function()
		local realLevel = ReplicatedStorage.Levels:FindFirstChild(level.Value)
		if realLevel and realLevel:FindFirstChild("AdvanceXP") and xp.Value >= realLevel.AdvanceXP.Value then
			level.Value = level.Value + 1
			xp.Value = xp.Value - realLevel.AdvanceXP.Value
		end
	end)

	level.Changed:Connect(function()
		if player.Character and player.Character:FindFirstChild("PlayerBillboard") then
			local realLevel = ReplicatedStorage.Levels:FindFirstChild(level.Value)
			if realLevel then
				player.Character.PlayerBillboard.Username.TextColor3 = realLevel.Color.Value
			end
		end
	end)
end

local function assignTycoon(player)
	local tycoon = Utl.GetEmptyTycoon()
	tycoon.Owner.Value = player
	return tycoon
end

local function reloadCharacterAfterLoad(player)
	task.spawn(function()
		task.wait(1)
		local success = pcall(function()
			if player.Character then
				player.Character:Destroy()
				player.Character = nil
			end
			player:LoadCharacter()
		end)
		if not success then
			task.wait()
			player.Character = nil
			player:LoadCharacter()
		end
		task.wait(1)
		ReplicatedStorage.Announce:FireClient(player, "Welcome back to Azure Mines!", 3, Color3.new(0,0.7,0.7))
	end)
end

local function startAutosaveLoop(player)
	task.spawn(function()
		local waitAmount = 180
		while task.wait(waitAmount) do
			if player and player.Parent == Players and not ShuttingDown then
				local success = savePlayerData(player)
				if success then
					if waitAmount == 3 then
						ReplicatedStorage.Announce:FireClient(player, "Data autosaved successfully!", 2, Color3.new(0.7,0.7,0.7))
					end
					waitAmount = 180
				elseif success == nil then
					ReplicatedStorage.Announce:FireClient(player, "Could not locate save data. AutoSave disabled.", 30, Color3.new(1,0.5,0.5))
					break
				elseif success == false then
					if waitAmount == 180 then
						ReplicatedStorage.Announce:FireClient(player, "AutoSave failed. Re-trying...", 5, Color3.new(1,0.7,0.7))
						waitAmount = 3
					else
						ReplicatedStorage.Announce:FireClient(player, "AutoSave failed again. ROBLOX servers may be down.", 7, Color3.new(1,0.7,0.7))
						waitAmount = 180
					end
				end
			else
				break
			end
		end
	end)
end

local function loadPlayerData(player, requestedTime)
	local garbageCharacter = ServerStorage.WorthlessGarbage:FindFirstChild(player.Name)
	if garbageCharacter then
		garbageCharacter:Destroy()
	end

	pcall(function()
		Utl.CheckPasses(player)
	end)

	local success, playerData, errorMessage, timeStamp = Saving.LoadData(player)
	timeStamp = timeStamp or 0

	if not success then
		return success, errorMessage
	elseif requestedTime and requestedTime > 1 then
		if (requestedTime - 1) >= timeStamp then
			return false, "Waiting for newer data"
		end
	end

	ensurePlayerDataShape(playerData)
	populateOwnedPickaxes(playerData)
	populateInventoryDefaults(playerData)
	Utl.NewPlayerData(player, playerData)

	local xp, level = createPlayerRuntimeValues(player, playerData)
	bindPlayerValueEvents(player, xp, level)
	assignTycoon(player)

	if player:FindFirstChild("Loading") then
		player.Loading:Destroy()
	end

	createValue(player, "BoolValue", "DataLoaded", true)
	ServerStorage.PlayerLoaded:Fire(player)

	reloadCharacterAfterLoad(player)
	startAutosaveLoop(player)

	return true
end

function ReplicatedStorage.LoadData.OnServerInvoke(player, requestedTime)
	if player:FindFirstChild("Loading") == nil and player:FindFirstChild("DataLoaded") == nil then
		createValue(player, "BoolValue", "Loading", true)
		local success, errorMessage = loadPlayerData(player, requestedTime)
		return success, errorMessage
	end
end

function ReplicatedStorage.GetData.OnServerInvoke(player)
	return Utl.GetPlayerData(player.UserId)
end

local function onPlayerLeaving(player)
	local success = savePlayerData(player)

	local tycoon = Utl.GetTycoon(player)
	if tycoon then
		tycoon.Owner.Value = nil
	end

	local dataFile = ServerStorage.PlayerData:FindFirstChild(tostring(player.userId))
	if dataFile then
		dataFile:Destroy()
	end

	return success
end

Players.PlayerRemoving:Connect(onPlayerLeaving)

game:BindToClose(function()
	ShuttingDown = true
	for _, player in pairs(Players:GetPlayers()) do
		ReplicatedStorage.Announce:FireClient(player, "SERVER RESTARTING FOR UPDATE. REJOIN AFTER SHUTDOWN", 30, Color3.new(0.9,0.8,0.2))
		ReplicatedStorage.Announce:FireClient(player, "Your data is being saved.", 30, Color3.new(0.5,0.9,0.2))
		local success = onPlayerLeaving(player)
		if success then
			ReplicatedStorage.Announce:FireClient(player, "Data saved successfully, feel free to go!", 3, Color3.new(0.5,0.9,0.2))
		else
			ReplicatedStorage.Announce:FireClient(player, "Data failed to save!", 10, Color3.new(1,0.5,0.2))
		end
	end

	for _ = 1, 500 do
		task.wait()
	end
end)
