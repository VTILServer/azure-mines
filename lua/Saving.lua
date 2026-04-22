--[[
	Saving

	TODO: ADD DESCRIPTION
	
	~ Orignal Creator, andrew@ber.gg
	~ Reworked/Cleanup by, erringpaladin10@vtilserver.com
]]

local Saving = {}

local DataStoreService = game:GetService("DataStoreService")
local TeleportService = game:GetService("TeleportService")

local selfScript = game.ServerScriptService.Saving
local Utl = require(game.ServerScriptService.Utl)

local function getOrderedSaveStore(player)
	return DataStoreService:GetOrderedDataStore(tostring(player.userId), "PlayerSaveTimes2")
end

local function getTimestampedPlayerDataStore(player)
	return DataStoreService:GetDataStore(tostring(player.userId), "PlayerData2")
end

local function getLegacyPlayerDataStore()
	return DataStoreService:GetDataStore("WatUpDatData")
end

local function getMostRecentSaveTime(orderedStore)
	local pages = orderedStore:GetSortedAsync(false, 1)
	for _, pair in pairs(pages:GetCurrentPage()) do
		return pair.value
	end
end

local function loadTimestampedSave(player, lastSaveTimestamp)
	local dataStore = getTimestampedPlayerDataStore(player)
	local data = dataStore:GetAsync(tostring(lastSaveTimestamp))
	return data, lastSaveTimestamp
end

local function loadLegacySave(player)
	local data
	getLegacyPlayerDataStore():UpdateAsync(player.userId, function(loadedData)
		if loadedData ~= nil then
			data = loadedData
		end
	end)
	return data or {}, 0
end

function Saving.LoadData(player)
	local loadedData
	local saveTimestamp

	local success, errorMessage = pcall(function()
		local orderedStore = getOrderedSaveStore(player)
		orderedStore:SetAsync("Default", 1)

		local lastSaveTimestamp = getMostRecentSaveTime(orderedStore)
		if lastSaveTimestamp and lastSaveTimestamp > 1 then
			loadedData, saveTimestamp = loadTimestampedSave(player, lastSaveTimestamp)
		else
			loadedData, saveTimestamp = loadLegacySave(player)
		end
	end)

	return success, loadedData, errorMessage, saveTimestamp
end

function Saving.SaveData(player, data)
	local saveTimestamp

	local success, errorMessage = pcall(function()
		saveTimestamp = os.time()
		local orderedStore = getOrderedSaveStore(player)
		local dataStore = getTimestampedPlayerDataStore(player)
		dataStore:SetAsync(tostring(saveTimestamp), data)
		orderedStore:SetAsync("s" .. tostring(saveTimestamp), saveTimestamp)
	end)

	return success, errorMessage, saveTimestamp
end

function Saving.TeleportPlayer(player, placeId)
	local success
	local errorMessage
	local saveTimestamp

	repeat
		success, errorMessage, saveTimestamp = Saving.SaveData(player, Utl.GetPlayerData(player.userId))
		task.wait(1)
	until success

	local teleportData = {
		Express = true,
		TimeStamp = saveTimestamp,
	}

	TeleportService:Teleport(placeId, player, teleportData)
end

return Saving
