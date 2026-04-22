--[[
	Util

	TODO: ADD DESCRIPTION
	
	~ Orignal Creator, andrew@ber.gg
	~ Reworked/Cleanup by, erringpaladin10@vtilserver.com
]]

local Utl = {}

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

Utl.Passes = {
	[450646779] = "Risk",
	[450631663] = "Nav",
	[453943049] = "Merchant",
}

Utl.CrystalProducts = {
	[36165501] = 50,
	[36165504] = 130,
	[36165514] = 395,
	[36165517] = 1060,
	[36165522] = 2130,
	[36165528] = 5000,
}

function Utl.CurrentDay()
	return math.floor(os.time() / 86400)
end

function Utl.GetPlayerData(playerId)
	local dataModule = ServerStorage.PlayerData:FindFirstChild(tostring(playerId))
	if dataModule then
		return require(dataModule)
	end
end

function Utl.NewPlayerData(player, playerData)
	local existingModule = ServerStorage.PlayerData:FindFirstChild(tostring(player.userId))
	if existingModule then
		existingModule:Destroy()
	end

	local newModule = ServerStorage.PlayerDataTemplate:Clone()
	newModule.Name = tostring(player.userId)
	newModule.Parent = ServerStorage.PlayerData

	local freshTable = require(newModule)
	for key, value in pairs(playerData) do
		freshTable[key] = value
	end
end

function Utl.IntToBool(value)
	return value == 1
end

function Utl.BoolToInt(value)
	return value and 1 or 0
end

function Utl.GetTycoon(player)
	for _, tycoon in pairs(workspace.Tycoons:GetChildren()) do
		if tycoon.Owner.Value == player then
			return tycoon
		end
	end
end

function Utl.GetEmptyTycoon()
	for _, tycoon in pairs(workspace.Tycoons:GetChildren()) do
		if tycoon.Owner.Value == nil then
			return tycoon
		elseif tycoon.Owner.Value.Parent ~= Players then
			tycoon.Owner.Value = nil
		end
	end
end

function Utl.CreateTag(player, name)
	if player:FindFirstChild(name) == nil then
		local tag = Instance.new("BoolValue")
		tag.Name = name
		tag.Parent = player
	end
end

function Utl.CheckPass(player, passId, tagName)
	if player:FindFirstChild(tagName) == nil and MarketplaceService:PlayerOwnsAssetAsync(player, passId) then
		Utl.CreateTag(player, tagName)
	end
end

function Utl.CheckPasses(player)
	for passId, tagName in pairs(Utl.Passes) do
		Utl.CheckPass(player, passId, tagName)
	end

	if player:GetRankInGroup(15627692) >= 100 then
		Utl.CreateTag(player, "Tester")
	end
end

function Utl.GetCrystals(productId)
	return Utl.CrystalProducts[productId]
end

local function announceCrystalPurchase(player, crystalAmount)
	local messageColor = Color3.new(1, 0, 174 / 255)
	local purchaseMessage = crystalAmount .. " Crystals credited. Thanks for supporting the game!"
	ReplicatedStorage.Announce:FireClient(player, purchaseMessage, 6, messageColor, Color3.new(0, 0, 0), 325234991)

	if crystalAmount > 4900 then
		ReplicatedStorage.Announce:FireClient(player, "Everyone else in the server just got 50uC thanks to you!", 6, Color3.new(0.5, 0.5, 0.5), Color3.new(0, 0, 0))
		for _, otherPlayer in pairs(Players:GetPlayers()) do
			if otherPlayer ~= player and otherPlayer:FindFirstChild("Crystals") and otherPlayer:FindFirstChild("DataLoaded") then
				otherPlayer.Crystals.Value = otherPlayer.Crystals.Value + 50
				local bonusMessage = player.Name .. " just bought you 50 Crystals!"
				ReplicatedStorage.Announce:FireClient(otherPlayer, bonusMessage, 5, messageColor, Color3.new(0, 0, 0), 325234991)
			end
		end
	end
end

MarketplaceService.ProcessReceipt = function(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	local crystalAmount = Utl.GetCrystals(receiptInfo.ProductId)
	if player and crystalAmount then
		announceCrystalPurchase(player, crystalAmount)
		player.Crystals.Value = player.Crystals.Value + crystalAmount
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

MarketplaceService.PromptPurchaseFinished:Connect(function(player, assetId, completed)
	if completed then
		Utl.CheckPasses(player)
	end
end)

Utl.ShuttingDown = false

return Utl
