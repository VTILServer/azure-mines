--[[
	TycoonHandler

	TODO: ADD DESCRIPTION
	
	~ Orignal Creator, andrew@ber.gg
	~ Reworked/Cleanup by, erringpaladin10@vtilserver.com
]]

local BadgeService = game:GetService("BadgeService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Utl = require(game.ServerScriptService.Utl)

local function removeTemplateValueChildren(instance)
	for _, child in pairs(instance:GetChildren()) do
		if child:IsA("StringValue") or child:IsA("NumberValue") or child:IsA("Color3Value") or child:IsA("IntValue") then
			child:Destroy()
		end
	end
end

local function getTycoonForPlayer(player)
	for _, tycoon in pairs(workspace.Tycoons:GetChildren()) do
		if tycoon.Owner.Value == player then
			return tycoon
		end
	end
end

local function createAntiGenTag(parent)
	local tag = Instance.new("BoolValue")
	tag.Name = "AntiGen"
	tag.Parent = parent
	return tag
end

local function spawnDragonstoneOre(oreSpawn)
	if oreSpawn.Ore.Value ~= nil then
		oreSpawn.Ore.Value:Destroy()
	end

	local ore = ReplicatedStorage.Ores.Dragonstone:Clone()
	removeTemplateValueChildren(ore)
	createAntiGenTag(ore)
	ore.Parent = workspace.Mine
	ore.CFrame = oreSpawn.CFrame
	oreSpawn.Ore.Value = ore
end

local function refreshEventOreForTycoon(tycoon)
	for _, child in pairs(tycoon:GetChildren()) do
		if child.Name == "OreSpawn" and child:FindFirstChild("DragonStone") then
			spawnDragonstoneOre(child)
		end
	end
end

local function updateItemSubtitle(item)
	local gui = item.Hitbox.BillboardGui
	local level = item.Level.Value
	local textColor
	local levelText = "Level " .. level

	if level == 0 then
		textColor = Color3.new(1, 12 / 25, 12 / 25)
		levelText = "In ruins"
	elseif level <= 5 then
		textColor = Color3.new(1 - level / 5, 1, 1 - level / 5)
	elseif level <= 10 then
		textColor = Color3.new((level - 5) / 5, 1, 0)
	else
		textColor = Color3.new(0, 1, 1)
	end

	gui.Level.Text = levelText
	gui.Level.TextColor3 = textColor
end

local function applyItemModel(levelModel, item)
	if levelModel then
		local clonedModel = levelModel:Clone()
		if item:FindFirstChild("Model") then
			item.Model:Destroy()
		end

		clonedModel.PrimaryPart = clonedModel.Hitbox
		clonedModel:SetPrimaryPartCFrame(item.Hitbox.CFrame)
		clonedModel.Hitbox:Destroy()
		clonedModel.Name = "Model"
		clonedModel.Parent = item
	end

	updateItemSubtitle(item)
end

local function clearTycoon(tycoon)
	for _, item in pairs(tycoon.Items:GetChildren()) do
		if item:FindFirstChild("Model") then
			item.Model:Destroy()
		end
		item.Hitbox.Transparency = 1
		item.Level.Value = 0
	end

	if tycoon.DailyGift:FindFirstChild("Gift") then
		tycoon.DailyGift.Gift:Destroy()
	end

	refreshEventOreForTycoon(tycoon)
end

local function populateTycoon(tycoon)
	local owner = tycoon.Owner.Value
	local playerData = Utl.GetPlayerData(owner.userId)
	local baseData = playerData.BaseData

	for _, item in pairs(tycoon.Items:GetChildren()) do
		local level = baseData[item.Name] or 0
		item.Level.Value = level

		local itemBaseFolder = ServerStorage.BaseParts:FindFirstChild(item.Name)
		local levelModel = itemBaseFolder and itemBaseFolder:FindFirstChild(level)
		applyItemModel(levelModel, item)
	end
end

local function showDailyGiftIfNeeded(tycoon, owner)
	if owner.LastGift.Value >= Utl.CurrentDay() then
		if tycoon.DailyGift:FindFirstChild("Gift") then
			tycoon.DailyGift.Gift:Destroy()
		end
	else
		if tycoon.DailyGift:FindFirstChild("Gift") == nil then
			local giftModel = ServerStorage.Gift:Clone()
			giftModel.CFrame = tycoon.DailyGift.Pos.CFrame
			giftModel.Parent = tycoon.DailyGift
		end
	end
end

local function showEventGiftIfNeeded(tycoon, owner)
	local playerData = Utl.GetPlayerData(owner.userId)
	if playerData["HelenEvent"] == "Gift" then
		if tycoon.EventGift:FindFirstChild("EventGift") == nil then
			local giftModel = ServerStorage.EventGift:Clone()
			giftModel.CFrame = tycoon.EventGift.Pos.CFrame
			giftModel.Parent = tycoon.EventGift
		end
	else
		if tycoon.EventGift:FindFirstChild("EventGift") then
			tycoon.EventGift.EventGift:Destroy()
		end
	end
end

local function updateTycoonGiftState(tycoon, owner)
	showDailyGiftIfNeeded(tycoon, owner)
	showEventGiftIfNeeded(tycoon, owner)
end

local function bindTycoonOwnerState(tycoon)
	tycoon.Owner.Changed:Connect(function()
		clearTycoon(tycoon)
		if tycoon.Owner.Value ~= nil and tycoon.Owner.Value.Parent == Players then
			tycoon.Owner.Value:WaitForChild("DataLoaded")
			populateTycoon(tycoon)

			if tycoon.Owner.Value.Character and tycoon.Owner.Value.Character:FindFirstChild("Torso") then
				tycoon.Owner.Value.Character.Torso.CFrame = tycoon.Spawn.CFrame + Vector3.new(0, 5, 0)
			end

			updateTycoonGiftState(tycoon, tycoon.Owner.Value)
			tycoon.Owner.Value.LastGift.Changed:Connect(function()
				updateTycoonGiftState(tycoon, tycoon.Owner.Value)
			end)
		end
	end)
end

local function bindTycoonItemLevelState(tycoon)
	for _, item in pairs(tycoon.Items:GetChildren()) do
		item.Level.Changed:Connect(function()
			local itemBaseFolder = ServerStorage.BaseParts:FindFirstChild(item.Name)
			local levelModel = itemBaseFolder and itemBaseFolder:FindFirstChild(item.Level.Value)
			applyItemModel(levelModel, item)
		end)
	end
end

local function moveMountainSpawnsOutOfTycoon(tycoon)
	for _, child in pairs(tycoon:GetChildren()) do
		if child.Name == "OreSpawn" and child:FindFirstChild("DragonStone") == nil then
			child.Parent = workspace.MountainSpawns
		end
	end
end

local function createWorldTycoons()
	for index = 1, 12 do
		local tycoon = ServerStorage.Tycoon:Clone()
		tycoon.PrimaryPart = tycoon.Core
		tycoon:PivotTo(CFrame.new(1200, 5000 - 6, index * 240))
		moveMountainSpawnsOutOfTycoon(tycoon)
		bindTycoonOwnerState(tycoon)
		bindTycoonItemLevelState(tycoon)
		tycoon.Parent = workspace.Tycoons
	end
end

local function canAffordUpgrade(player, requirements)
	local failItems = {}
	local playerData = Utl.GetPlayerData(player.userId)

	for _, requirement in pairs(requirements) do
		if requirement.Name == "GoldCoin" then
			if player.Gold.Value < requirement.Value then
				table.insert(failItems, requirement.Name)
			end
		elseif requirement.Name == "Crystal" then
			if player.Crystals.Value < requirement.Value then
				table.insert(failItems, requirement.Name)
			end
		else
			local totalAmount = (playerData.Inventory[requirement.Name] or 0) + (playerData.Storage[requirement.Name] or 0)
			if totalAmount < requirement.Value then
				table.insert(failItems, requirement.Name)
			end
		end
	end

	return #failItems == 0, failItems
end

local function chargeUpgradeCosts(player, costs)
	local playerData = Utl.GetPlayerData(player.userId)
	local inventory = playerData.Inventory
	local storage = playerData.Storage

	for _, cost in pairs(costs) do
		if cost.Name == "GoldCoin" then
			player.Gold.Value = player.Gold.Value - cost.Value
		elseif cost.Name == "Crystal" then
			player.Crystals.Value = player.Crystals.Value - cost.Value
		else
			local costAmount = cost.Value
			if inventory[cost.Name] < costAmount then
				costAmount = costAmount - inventory[cost.Name]
				inventory[cost.Name] = 0
				storage[cost.Name] = storage[cost.Name] - costAmount
			else
				inventory[cost.Name] = inventory[cost.Name] - costAmount
			end
		end
	end
end

local function applyUpgradeSideEffects(player, itemName)
	if itemName == "Teleporter" then
		if player.Tutorial.Value == 0 then
			player.Tutorial.Value = 1
		end
	elseif itemName == "Mine" then
		if player.Tutorial.Value == 6 then
			player.Tutorial.Value = 7
		end
	end
end

ServerStorage.MineReset.Event:Connect(function()
	for _, tycoon in pairs(workspace.Tycoons:GetChildren()) do
		refreshEventOreForTycoon(tycoon)
	end
end)

createWorldTycoons()

function ReplicatedStorage.UpgradeBaseItem.OnServerInvoke(player, itemName)
	local playerData = Utl.GetPlayerData(player.UserId)
	local basePartFolder = ServerStorage.BaseParts:FindFirstChild(itemName)
	local tycoon = getTycoonForPlayer(player)
	local level = playerData.BaseData[itemName]
	local levelModel = basePartFolder and basePartFolder:FindFirstChild(level)

	if not levelModel or not levelModel:FindFirstChild("UpgradeCost") then
		return false, {}
	end

	local canBuy, failItems = canAffordUpgrade(player, levelModel.UpgradeCost:GetChildren())
	if not canBuy then
		return false, failItems
	end

	chargeUpgradeCosts(player, levelModel.UpgradeCost:GetChildren())
	playerData.BaseData[itemName] = playerData.BaseData[itemName] + 1

	if tycoon and tycoon.Items:FindFirstChild(itemName) then
		tycoon.Items[itemName].Level.Value = tycoon.Items[itemName].Level.Value + 1
	end

	applyUpgradeSideEffects(player, itemName)
	ReplicatedStorage.InventoryChanged:FireClient(player, playerData)

	return true
end
