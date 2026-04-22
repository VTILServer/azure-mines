--[[
	ServerController

	This server script coordinates gameplay loop, mine generation,
	trading, crafting, building, and ore BOOMing. ~ Shout out to the Boomite ore, BOOMITE FTW!!!
	
	Deadline: 05/04/2026
		Rework how the entire script looks,
		Rewrite the entire cave generation,
		Make all generation based systems to be parallel, to SQEEEEZE ALL THE PERFORMANCE OUT OF THIS.
	
	~ Orignal Creator, andrew@ber.gg
	~ Reworked/Cleanup by, erringpaladin10@vtilserver.com
]]

local Utl = require(game.ServerScriptService.Utl)

-- Services and shared state --------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local BadgeService = game:GetService("BadgeService")
local RunService = game:GetService("RunService")

local caveTeleportCommand
local tryRunMaxOutCommand
local generateOre
local Rand
local VectorsGen

-- MODULES
require(script.OreEmblems)()
require(workspace.Leaderboard.BillboardScript)()

-- Player lifecycle -----------------------------------------------------------
local function getTycoonForPlayer(player)
	for _, tycoon in pairs(workspace.Tycoons:GetChildren()) do
		if tycoon.Owner.Value == player then
			return tycoon
		end
	end
end

function ReplicatedStorage.LoadCharacter.OnServerInvoke(player)
	player:LoadCharacterAsync()
end

-- Anti-exploit / novelty handlers -------------------------------------------
local function hackPlayer(player)
	if player.Character and player.Character:FindFirstChild("Torso") then
		local explosion = Instance.new("Explosion")
		explosion.Position = player.Character.Torso.Position
		explosion.DestroyJointRadiusPercent = 0
		explosion.ExplosionType = Enum.ExplosionType.NoCraters
		explosion.Parent = workspace
		player.Character.Torso:Destroy()

		for _ = 1, 10 do
			local randomPrimaryColor = Color3.new(math.random(), math.random(), math.random())
			local randomSecondaryColor = Color3.new(math.random(), math.random(), math.random())
			ReplicatedStorage.Announce:FireClient(player, "HACKED BY POODLECORP", 10, randomPrimaryColor, randomSecondaryColor, 320570430)
		end
	end
end

function ReplicatedStorage.FreeStuff.OnServerInvoke(player)
	hackPlayer(player)
end

function ServerStorage.PoodleCorp.OnInvoke(player)
	hackPlayer(player)
end

local function updatePlayerBillboard(player)
	if player.Character and player.Character:FindFirstChild("PlayerBillboard") then
		local emblem = ReplicatedStorage.Emblems:FindFirstChild(player.Emblem.Value)
		if emblem then
			player.Character.PlayerBillboard.Emblem.Image = emblem.Texture
		end
	end
end

local function onPlayerLoaded(player)
	player.CharacterAdded:Connect(function(character)
		repeat task.wait() until character:FindFirstChild("Torso")

		local playerTycoon = getTycoonForPlayer(player)
		if playerTycoon then
			character.Torso.CFrame = playerTycoon.Spawn.CFrame + Vector3.new(0, 10, 0)
		else
			character.Torso.CFrame = CFrame.new(87.422 + math.random(-2, 2), 5022, 19.225 + math.random(-2, 2))
		end

		character.Parent = workspace.Players

		local billboard = script.PlayerBillboard:Clone()
		billboard.Parent = character
		billboard.Adornee = character.Head
		billboard.Username.Text = player.Name
		billboard.Enabled = true

		updatePlayerBillboard(player)
		player:WaitForChild("Level")

		local levelDefinition = ReplicatedStorage.Levels:FindFirstChild(player.Level.Value)
		if levelDefinition then
			billboard.Username.TextColor3 = levelDefinition.Color.Value
		end

		local headLight = Instance.new("PointLight")
		headLight.Brightness = 1
		headLight.Range = 7
		headLight.Parent = character.Head
	end)

	player:WaitForChild("Emblem")
	player.Emblem.Changed:Connect(function()
		updatePlayerBillboard(player)
	end)
	task.wait(3)
end

ServerStorage.PlayerLoaded.Event:Connect(onPlayerLoaded)


-- Mine generation state ------------------------------------------------------
local UsedPositions = {}

local function getPositionKey(x,y,z)
	return x..","..y..","..z
end

local function isPointInsidePartBounds(part, worldPosition)
	local localPosition = part.CFrame:PointToObjectSpace(worldPosition)
	local halfSize = part.Size * 0.5

	return math.abs(localPosition.X) <= halfSize.X
		and math.abs(localPosition.Y) <= halfSize.Y
		and math.abs(localPosition.Z) <= halfSize.Z
end

local BASE_MINING_COMPACT_DEPTH_LIMIT = 10
local BASE_FOOTPRINT_PADDING = Vector3.new(12, 0, 12)

local function isPointInsideTycoonFootprint(tycoon, worldPosition)
	local boundingCFrame, boundingSize = tycoon:GetBoundingBox()
	local expandedSize = boundingSize + BASE_FOOTPRINT_PADDING
	local localPosition = boundingCFrame:PointToObjectSpace(worldPosition)
	local halfSize = expandedSize * 0.5

	return math.abs(localPosition.X) <= halfSize.X
		and math.abs(localPosition.Z) <= halfSize.Z
end

local function isOreInsidePlayerBase(player, ore)
	local tycoon = getTycoonForPlayer(player)
	if not tycoon then
		return false
	end

	local hitbox = ore:IsA("Model") and ore:FindFirstChild("Hitbox") or ore
	if not hitbox or not hitbox:IsA("BasePart") then
		return false
	end

	local compactPosition = Vector3.new(
		hitbox.Position.X / 6,
		(hitbox.Position.Y - 5000) / -6,
		hitbox.Position.Z / 6
	)
	if compactPosition.Y > BASE_MINING_COMPACT_DEPTH_LIMIT then
		return false
	end

	return isPointInsideTycoonFootprint(tycoon, hitbox.Position)
end

local UnfilteredItems = ReplicatedStorage.Ores:GetChildren()
local Items = {}
for i,Item in pairs(UnfilteredItems) do
	if Item:IsA("BasePart") then
		table.insert(Items,Item)
	end
end

local function getOreFromId(id)
	return Items[id]
end

-- Trade helpers --------------------------------------------------------------
local function tagTradeComplete(trade)
	local completionTag = Instance.new("BoolValue")
	completionTag.Name = "Complete"
	completionTag.Parent = trade
	trade.Parent.Parent.RefreshTime.Value = os.time()
end

function ReplicatedStorage.MakeTrade.OnServerInvoke(Player,Trade)
	if Trade == nil or Trade:FindFirstChild("Locked") or Trade:FindFirstChild("Complete") then
		return false
	end
	if Trade.Buying.Value then
		local CoinsNeeded = Trade.Get.Amount.Value
		if Player.Gold.Value < CoinsNeeded then
			return false
		end
		local OreGiven = ReplicatedStorage.Ores:FindFirstChild(Trade.Give.Ore.Value)
		local Amount = Trade.Give.Amount.Value
		if OreGiven and Amount then
			Player.Gold.Value = Player.Gold.Value - Trade.Get.Amount.Value
			local PlayerData = Utl.GetPlayerData(Player.UserId)
			PlayerData["Inventory"][OreGiven.Name] = PlayerData["Inventory"][OreGiven.Name] + Amount

			ReplicatedStorage.UpdateInventoryItem:FireClient(Player,OreGiven.Name,Amount)

			--ReplicatedStorage.InventoryChanged:FireClient(Player,PlayerData)
			tagTradeComplete(Trade)
			return true
		end
	else
		local OreGiving = ReplicatedStorage.Ores:FindFirstChild(Trade.Give.Ore.Value)
		local OreAmount = Trade.Give.Amount.Value
		local PlayerData = Utl.GetPlayerData(Player.UserId)

		if OreGiving == nil or PlayerData["Inventory"][OreGiving.Name] + PlayerData["Storage"][OreGiving.Name] < OreAmount then
			return false
		end
		if PlayerData["Inventory"][OreGiving.Name] < OreAmount then
			OreAmount = OreAmount - PlayerData["Inventory"][OreGiving.Name]
			PlayerData["Inventory"][OreGiving.Name] = 0
			PlayerData["Storage"][OreGiving.Name] = PlayerData["Storage"][OreGiving.Name] - OreAmount
			ReplicatedStorage.InventoryChanged:FireClient(Player,PlayerData)			
		else
			PlayerData["Inventory"][OreGiving.Name] = PlayerData["Inventory"][OreGiving.Name] - OreAmount
			ReplicatedStorage.UpdateInventoryItem:FireClient(Player,OreGiving.Name,-OreAmount)			
		end
		Player.Gold.Value = Player.Gold.Value + Trade.Get.Amount.Value

		tagTradeComplete(Trade)
		return true
	end
end


local function rollOreForDepth(y,Cave)
	local Chance1 = math.random(1,1000)
	local Chance2 = math.random(1,1000)
	if Chance1 == 392 and Chance2 == 739 then
		return ReplicatedStorage.Ores.Ambrosia
	end

	local weightedCandidates = {}
	local totalWeight = 0

	for Index,Ore in pairs(Items) do
		if Ore.Name ~= "Ambrosia" then
			local MaxDepth = (Ore.MaxDepth.Value > 0 and Ore.MaxDepth.Value) or 9999
			local MinDepth = (Ore.MinDepth.Value > 0 and Ore.MinDepth.Value) or 1
			local Range = MaxDepth - MinDepth + 1
			local MinDistance = y - MinDepth + 1
			local MaxDistance = MaxDepth - y + 1
			local MaxRarity, MinRarity = Ore.MaxRarity.Value, Ore.MinRarity.Value

			local Chance = math.ceil(((MinDistance / Range) * MinRarity + (MaxDistance / Range) * MaxRarity) / 2)

			if (Ore:FindFirstChild("Cave") == nil or Cave == true) and y >= MinDepth and y <= MaxDepth then
				totalWeight = totalWeight + Chance
				table.insert(weightedCandidates, {
					id = Index,
					maxWeight = totalWeight,
				})
			end
		end
	end

	local selectedWeight = math.random(1, totalWeight)
	for _, candidate in ipairs(weightedCandidates) do
		if selectedWeight <= candidate.maxWeight then
			return getOreFromId(candidate.id)
		end
	end

	return getOreFromId(weightedCandidates[#weightedCandidates].id)
end





VectorsGen = {
	Vector3.new(-1,0,0),
	Vector3.new(1,0,0),
	Vector3.new(0,-1,0),
	Vector3.new(0,1,0),
	Vector3.new(0,0,1),
	Vector3.new(0,0,-1),
}

local VectorsMine = {
	Vector3.new(-1,0,0),
	Vector3.new(1,0,0),
	Vector3.new(0,-1,0),
	Vector3.new(0,1,0),
	Vector3.new(0,0,1),
	Vector3.new(0,0,-1),
	Vector3.new(0,2,0),
	Vector3.new(-1,0,-1),
	Vector3.new(1,0,1),
	Vector3.new(-1,0,1),
	Vector3.new(1,0,-1)
}

local GCounts = {}

local function getUniqueOreAtPosition(CompactPos)
	for i,Ore in pairs(ReplicatedStorage.Ores:GetChildren()) do
		if Ore:FindFirstChild("UniquePosition") and Ore.UniquePosition.Value == CompactPos then
			return Ore
		end
	end
end

Rand = Random.new(os.time())

local function getWorldPositionFromCompactPosition(compactPosition)
	return Vector3.new(compactPosition.X * 6, 5000 + compactPosition.Y * -6, compactPosition.Z * 6)
end

local function getCompactPositionFromWorldPosition(worldPosition)
	return Vector3.new(worldPosition.X / 6, (worldPosition.Y - 5000) / -6, worldPosition.Z / 6)
end

local DEBUG_CAVE_SEARCH_RADIUS = 120
local DEBUG_CAVE_SEARCH_STEP = 3
local DEBUG_CAVE_ZOMBIE_RADIUS = 120
local DEBUG_CAVE_DEPTH_TOLERANCE = 12

local function isCaveCell(x, y, z)
	if y <= 2 then
		return false
	end

	local noise = math.noise(x / 28, y / 16, z / 28)
	return (noise <= 0.86 and noise >= 0.57) or (noise <= -0.57 and noise >= -0.86)
end

local function getMineCell(x, y, z)
	return UsedPositions[getPositionKey(x, y, z)]
end

local function reserveMineCell(x, y, z, value)
	UsedPositions[getPositionKey(x, y, z)] = value
end

local function buildCaveInfo(origin, allowZombie)
	local caveInfo = {
		Origin = origin,
		HasZombie = false,
		FirstZombie = false,
		ZombiePos = nil,
	}

	if allowZombie then
		local chance = Rand:NextInteger(1, 4)
		if chance <= 2 then
			caveInfo.HasZombie = true
		end
	end

	return caveInfo
end

local function hasZombieNearPosition(worldPosition, radius)
	for _, mineChild in pairs(workspace.Mine:GetChildren()) do
		if mineChild:IsA("Model") and (mineChild.Name == "Zombie" or mineChild.Name == "Zwambie") then
			local zombieTorso = mineChild:FindFirstChild("Torso")
			if zombieTorso and (zombieTorso.Position - worldPosition).Magnitude <= radius then
				return true
			end
		end
	end

	return false
end

local function hopeForNonZombieCave(compactPosition)
	if not isCaveCell(compactPosition.X, compactPosition.Y, compactPosition.Z) then
		return false
	end

	local caveInfo = buildCaveInfo(compactPosition, false)
	local currentCell = getMineCell(compactPosition.X, compactPosition.Y, compactPosition.Z)
	if currentCell == nil then
		generateOre(compactPosition.X, compactPosition.Y, compactPosition.Z, false, nil, nil, nil, caveInfo)
	end

	for _, vector in pairs(VectorsGen) do
		local neighbor = compactPosition + vector
		if getMineCell(neighbor.X, neighbor.Y, neighbor.Z) == nil then
			generateOre(neighbor.X, neighbor.Y, neighbor.Z, false, nil, nil, nil, caveInfo)
		end
	end

	return true
end

local function isTeleportableCaveCell(compactPosition)
	local currentCell = getMineCell(compactPosition.X, compactPosition.Y, compactPosition.Z)
	local headCell = getMineCell(compactPosition.X, compactPosition.Y - 1, compactPosition.Z)
	local floorCell = getMineCell(compactPosition.X, compactPosition.Y + 1, compactPosition.Z)

	local hasAirSpace = currentCell == false and headCell == false
	local hasSolidFloor = floorCell ~= nil and floorCell ~= false

	return hasAirSpace and hasSolidFloor
end

local function findNonZombieCavePosition(originCompactPosition, targetDepth)
	local compactDepth = math.max(3, math.floor(targetDepth))

	for depthOffset = 0, DEBUG_CAVE_DEPTH_TOLERANCE do
		for _, depthSign in ipairs(depthOffset == 0 and { 1 } or { 1, -1 }) do
			local candidateDepth = compactDepth + (depthOffset * depthSign)
			if candidateDepth > 2 then
				for searchRadius = 0, DEBUG_CAVE_SEARCH_RADIUS, DEBUG_CAVE_SEARCH_STEP do
					for xOffset = -searchRadius, searchRadius, DEBUG_CAVE_SEARCH_STEP do
						for zOffset = -searchRadius, searchRadius, DEBUG_CAVE_SEARCH_STEP do
							local onSearchEdge = searchRadius == 0
								or math.abs(xOffset) == searchRadius
								or math.abs(zOffset) == searchRadius

							if onSearchEdge then
								local candidatePosition = Vector3.new(
									math.floor(originCompactPosition.X + xOffset),
									candidateDepth,
									math.floor(originCompactPosition.Z + zOffset)
								)

								if hopeForNonZombieCave(candidatePosition) and isTeleportableCaveCell(candidatePosition) then
									local worldPosition = getWorldPositionFromCompactPosition(candidatePosition) + Vector3.new(0, 3, 0)
									if not hasZombieNearPosition(worldPosition, DEBUG_CAVE_ZOMBIE_RADIUS) then
										return worldPosition
									end
								end
							end
						end
					end
				end
			end
		end
	end
end

local function findPlayerByNamePrefix(playerName)
	local lowerName = string.lower(playerName)

	for _, player in pairs(Players:GetPlayers()) do
		if string.sub(string.lower(player.Name), 1, #lowerName) == lowerName then
			return player
		end
	end
end

local function canUseTesterAdminCommands(player)
	return RunService:IsStudio() or player:FindFirstChild("Tester") ~= nil
end

local function getStrongestPickaxeName()
	local strongestPickaxeName = "Stone"
	local highestEfficiency = -math.huge

	for _, pickaxe in pairs(ReplicatedStorage.Pickaxes:GetChildren()) do
		local statsModule = pickaxe:FindFirstChild("Parts") and pickaxe.Parts:FindFirstChild("Stats")
		if statsModule then
			local success, stats = pcall(require, statsModule)
			local efficiency = success and stats and stats.Eff or 0
			if efficiency > highestEfficiency then
				highestEfficiency = efficiency
				strongestPickaxeName = pickaxe.Name
			end
		end
	end

	return strongestPickaxeName
end

local function getMaxBasePartLevel(basePartFolder)
	local maxLevel = 0

	for _, child in pairs(basePartFolder:GetChildren()) do
		local numericLevel = tonumber(child.Name)
		if numericLevel and numericLevel > maxLevel then
			maxLevel = numericLevel
		end
	end

	return maxLevel
end

local function maxOutPlayerProgress(targetPlayer)
	local playerData = Utl.GetPlayerData(targetPlayer.UserId)
	if not playerData then
		return false, "Target player data is not loaded."
	end

	local tycoon = getTycoonForPlayer(targetPlayer)
	local strongestPickaxeName = getStrongestPickaxeName()

	for _, basePartFolder in pairs(ServerStorage.BaseParts:GetChildren()) do
		local maxLevel = getMaxBasePartLevel(basePartFolder)
		playerData.BaseData[basePartFolder.Name] = maxLevel

		if tycoon and tycoon:FindFirstChild("Items") and tycoon.Items:FindFirstChild(basePartFolder.Name) then
			tycoon.Items[basePartFolder.Name].Level.Value = maxLevel
		end
	end

	for _, pickaxe in pairs(ReplicatedStorage.Pickaxes:GetChildren()) do
		playerData.Pickaxes[pickaxe.Name] = true
	end

	playerData.Level = 12
	playerData.XP = 0
	playerData.Pickaxe = strongestPickaxeName
	playerData.Tutorial = -1

	if targetPlayer:FindFirstChild("Level") then
		targetPlayer.Level.Value = 12
	end
	if targetPlayer:FindFirstChild("XP") then
		targetPlayer.XP.Value = 0
	end
	if targetPlayer:FindFirstChild("Pickaxe") then
		targetPlayer.Pickaxe.Value = strongestPickaxeName
	end
	if targetPlayer:FindFirstChild("Tutorial") then
		targetPlayer.Tutorial.Value = -1
	end

	ReplicatedStorage.InventoryChanged:FireClient(targetPlayer, playerData)

	return true, string.format(
		"Maxed %s: base upgrades, all pickaxes, strongest pickaxe equipped, level 12.",
		targetPlayer.Name
	)
end

local function sendDebugTeleportMessage(player, messageText, duration, textColor)
	ReplicatedStorage.Announce:FireClient(
		player,
		messageText,
		duration or 4,
		textColor or Color3.new(1, 1, 1),
		Color3.new(0, 0, 0)
	)
end

local function teleportPlayerToChosenDepthInCave(targetPlayer, targetDepth)
	if not targetPlayer.Character or not targetPlayer.Character:FindFirstChild("HumanoidRootPart") then
		return false, "Target player has no character loaded."
	end

	local tycoon = getTycoonForPlayer(targetPlayer)
	local originWorldPosition = tycoon and tycoon.Spawn.Position or targetPlayer.Character.HumanoidRootPart.Position
	local originCompactPosition = getCompactPositionFromWorldPosition(originWorldPosition)
	local teleportPosition = findNonZombieCavePosition(originCompactPosition, targetDepth)

	if not teleportPosition then
		return false, "Couldn't find a non-zombie cave at that depth."
	end

	local compactTeleportPosition = getCompactPositionFromWorldPosition(teleportPosition)
	ReplicatedStorage.Teleported:FireClient(targetPlayer)
	targetPlayer.Character:PivotTo(CFrame.new(teleportPosition))

	return true, string.format(
		"Teleported %s to %sm in a non-zombie cave.",
		targetPlayer.Name,
		math.floor(compactTeleportPosition.Y)
	)
end

caveTeleportCommand = function(player, message)
	if not canUseTesterAdminCommands(player) then
		return
	end

	local commandTarget, commandDepth = string.match(message, "^;cavetp%s+(%S+)%s+(%d+)$")
	local targetPlayer = player
	local targetDepth = commandDepth

	if not commandTarget then
		targetDepth = string.match(message, "^;cavetp%s+(%d+)$")
	else
		targetPlayer = findPlayerByNamePrefix(commandTarget)
	end

	if not targetDepth then
		return
	end

	if not targetPlayer then
		sendDebugTeleportMessage(player, "Player not found.", 4, Color3.new(1, 0.5, 0.5))
		return
	end

	local success, responseMessage = teleportPlayerToChosenDepthInCave(targetPlayer, tonumber(targetDepth))
	sendDebugTeleportMessage(
		player,
		responseMessage,
		5,
		success and Color3.new(0.6, 1, 0.8) or Color3.new(1, 0.5, 0.5)
	)
end

local function tryRunMaxOutCommand(player, message)
	if not canUseTesterAdminCommands(player) then
		return
	end

	local targetName = string.match(message, "^;maxout%s+(%S+)$")
	local targetPlayer = player

	if targetName then
		targetPlayer = findPlayerByNamePrefix(targetName)
		if not targetPlayer then
			sendDebugTeleportMessage(player, "Player not found.", 4, Color3.new(1, 0.5, 0.5))
			return
		end
	elseif message ~= ";maxout" then
		return
	end

	local success, responseMessage = maxOutPlayerProgress(targetPlayer)
	sendDebugTeleportMessage(
		player,
		responseMessage,
		5,
		success and Color3.new(0.6, 1, 0.8) or Color3.new(1, 0.5, 0.5)
	)
end

local function removeTemplateValueChildren(ore)
	for _, child in pairs(ore:GetChildren()) do
		if child:IsA("StringValue") or child:IsA("NumberValue") or child:IsA("Color3Value") or child:IsA("IntValue") then
			child:Destroy()
		end
	end
end

local function applyDepthBrickColor(ore, depth)
	if depth > 4000 then
		ore.BrickColor = BrickColor.new("Royal purple")
	elseif depth > 3000 then
		ore.BrickColor = BrickColor.new("Earth green")
	elseif depth > 2000 then
		ore.BrickColor = BrickColor.new("Persimmon")
	elseif depth >= 1000 then
		ore.BrickColor = BrickColor.new("Dark indigo")
	elseif depth >= 600 then
		ore.BrickColor = BrickColor.new("Smoky grey")
	end
end

local function applyOreEffect(ore, effect)
	if effect == "Stain" then
		local oreColor = ore.BrickColor.Color
		ore.BrickColor = BrickColor.new(oreColor.r + 0.3, oreColor.g, oreColor.b)
	end
end


generateOre = function(x,y,z,Override,PresetOre,Default,Effect,CaveInfo)

	local isCave = false	

	if (UsedPositions[getPositionKey(x,y,z)] == nil or Override == true) and y > 0 then		
		local Noise = math.noise(x/28,y/16,z/28)
		--local xrem = x % 25
		--local yrem = y % 25
		--local zrem = z % 25

		local Constricted = false
		--local Constricted = xrem == 0 or yrem == 0 or zrem == 0

		local CompactPos = Vector3.new(x,y,z)	
		if y > 2 and ((Noise <= 0.86 and Noise >= 0.57) or (Noise <= -0.57 and Noise >= - 0.86)) and not Constricted then

			-- Air

			isCave = true			

			UsedPositions[getPositionKey(x,y,z)] = false

			if Override ~= "Branch" and Override ~= "BranchProtect" then

				if CaveInfo == nil then
					CaveInfo = buildCaveInfo(Vector3.new(x, y, z), true)
				end				

				local Origin = getPositionKey(x,y,z)
				GCounts[Origin] = 0
				--coroutine.resume(coroutine.create((function()
				for i,Vec in pairs(VectorsGen) do
					local NewPos = CompactPos + Vec
					if UsedPositions[getPositionKey(NewPos.x,NewPos.y,NewPos.z)] == nil then
						GCounts[Origin] = GCounts[Origin] + 1
						generateOre(NewPos.x,NewPos.y,NewPos.z,"Branch",Origin,nil,nil,CaveInfo)
					end
				end
				--end)))
			else
				local Protection = false
				local Origin = PresetOre




				local SpecialCave = (CaveInfo.HasZombie and CaveInfo.ZombiePos == nil)

				-- Ladder brick support				

				if SpecialCave then	


					local BelowNoise = math.noise(x/28,(y+1)/16,z/28)
					local BlockBelow = not ((BelowNoise <= 0.86 and BelowNoise >= 0.57) or (BelowNoise <= -0.57 and BelowNoise >= - 0.86))

					local AboveNoise = math.noise(x/28,(y-1)/16,z/28)
					local BlockAbove = not ((AboveNoise <= 0.86 and AboveNoise >= 0.57) or (AboveNoise <= -0.57 and AboveNoise >= - 0.86))								

					local posRand = Random.new(math.floor(x*1000)+z)

					if posRand:NextInteger(0,24) == 7 and ((not BlockBelow) or (not BlockAbove)) then

						local Ore = ReplicatedStorage.Ores["Ladder Brick"]:Clone()
						Ore.PrimaryPart = Ore.Hitbox
						Ore:PivotTo(CFrame.new(0 + x*6,5000 + y*(-6),0 + z*6))
						Ore.Parent = workspace.Mine
						reserveMineCell(x, y, z, Ore)

					elseif BlockBelow then
						local Chance = Rand:NextInteger(1,70)
						if (Chance == 7 or Chance == 13 or Chance == 42) then
							local Torch
							if y < 600 then
								Torch = ReplicatedStorage.Ores.Torch:Clone()
							elseif y < 1000 then
								Torch = ReplicatedStorage.Ores["Uranium Stick"]:Clone()
							else
								Torch = ReplicatedStorage.Ores["Glass Candle"]:Clone()
							end
							Torch.Parent = workspace.Mine
							Torch.PrimaryPart = Torch.Hitbox
							Torch:PivotTo(CFrame.new(0 + x*6,5000 + y*(-6),0 + z*6))
							reserveMineCell(x, y, z, Torch)
							Protection = true
						elseif (Chance == 15 or Chance == 77 or not CaveInfo.FirstZombie) then


							if not BlockAbove then

								CaveInfo.FirstZombie = true
								CaveInfo.ZombiePos = Vector3.new(x, y, z)

								local Zombie
								if y >= 600 and y <= 1000 then
									Zombie = script.Zwambie:Clone()	
								else
									Zombie = script.Zombie:Clone()
								end
								Zombie.PrimaryPart = Zombie.Torso
								Zombie.Parent = workspace.Mine
								Zombie:PivotTo(CFrame.new(0 + x*6, 5000 + 2 + y*(-6),0 + z*6))	
								Zombie.ZombieScript.Disabled = false		
								reserveMineCell(x, y, z, Zombie)


								--local Zombie = ReplicatedStorage.Ores.Tombstone:Clone()
								--Zombie.Parent = workspace.Mine
								--Zombie.PrimaryPart = Zombie.Hitbox
								--Zombie:PivotTo(CFrame.new(0 + x*6,5000 + y*(-6),0 + z*6))
								--CaveInfo.ZombiePos = Vector3.new(x,y,z)

								--Protection = true
							end
						end
					end
				end		

				-- generates nearby blocks
				for i,Vec in pairs(VectorsGen) do
					local NewPos = CompactPos + Vec
					if UsedPositions[getPositionKey(NewPos.x,NewPos.y,NewPos.z)] == nil then
						GCounts[Origin] = GCounts[Origin] + 1
						if GCounts[Origin] % 250 == 0 then -- wait every hundred
							task.wait()
						end
						local Code = "Branch"
						if Protection and Vec == Vector3.new(0,1,0) then
							Code = "BranchProtect"
						end
						local Ore, Cave = generateOre(NewPos.x,NewPos.y,NewPos.z,Code,Origin,nil,nil,CaveInfo)
						if Cave then
							isCave = true
						end
					end
				end	



			end


			for xo = 1,3 do
				for yo = 1,3 do
					for zo = 1,3 do
						if y + (yo-2) > 0 and UsedPositions[getPositionKey(x + (xo-2),y + (yo-2),z + (zo-2))] == nil then
							generateOre(x + (xo-2),y + (yo-2), z + (zo-2), false, nil, nil, nil, isCave and CaveInfo or nil)
						end
					end
				end
			end
		else
			local Ore
			local PredestinedOre = getUniqueOreAtPosition(CompactPos)
			if PredestinedOre then
				Ore = PredestinedOre:Clone()
			elseif PresetOre and Override ~= "Branch" and Override ~= "BranchProtect" then
				Ore = ReplicatedStorage.Ores:FindFirstChild(PresetOre):Clone()
			elseif y <= 1 and not Default then
				Ore = ReplicatedStorage.Ores.Stone:Clone()
				Instance.new("BoolValue",Ore).Name = "Claimed"
				Ore.BrickColor = BrickColor.new("Fossil")
			else
				Ore = rollOreForDepth(y,(Override == "Branch" or Override == "BranchProtect")):Clone()
				if Override == "BranchProtect" then
					Instance.new("BoolValue",Ore).Name = "Claimed"
				end
			end

			removeTemplateValueChildren(Ore)

			Ore.Parent = workspace.Mine
			applyDepthBrickColor(Ore, y)
			applyOreEffect(Ore, Effect)
			Ore.CFrame = CFrame.new(getWorldPositionFromCompactPosition(Vector3.new(x, y, z)))	

			UsedPositions[getPositionKey(x,y,z)] = Ore
			return Ore, isCave	
		end
	end
	return nil, isCave
end

local function generateNeighborOres(compactPosition, vectors, effect)
	for _, offset in pairs(vectors) do
		local nextPosition = compactPosition + offset
		if UsedPositions[getPositionKey(nextPosition.X, nextPosition.Y, nextPosition.Z)] == nil then
			generateOre(nextPosition.X, nextPosition.Y, nextPosition.Z, false, nil, nil, effect)
		end
	end
end


local function awardXp(Player, XP, Color)
	Color = Color or Color3.new(1,1,1)
	Player.XP.Value = Player.XP.Value + XP
	if XP > 1 then
		ReplicatedStorage.XP:FireClient(Player, XP, Color)
	end
end

function ReplicatedStorage.RefreshDeals.OnServerInvoke(Player)
	if Player.Crystals.Value >= 20 then
		Player.Crystals.Value = Player.Crystals.Value - 20
		ServerStorage.RefreshMarket:Fire(Player)
		return true
	end
	return false
end

local function buyEmblem(Player, Emblem)
	if Emblem.Cost.Type.Value == "GoldCoin" then
		if Player.Gold.Value >= Emblem.Cost.Amount.Value then
			Player.Gold.Value = Player.Gold.Value - Emblem.Cost.Amount.Value
			return true
		end
	elseif Emblem.Cost.Type == "Crystal" then
		if Player.Crystals.Value >= Emblem.Cost.Amount.Value then
			Player.Crystals.Value = Player.Crystals.Value - Emblem.Cost.Amount.Value
			return true
		end
	else
		local PlayerData = Utl.GetPlayerData(Player.UserId)
		if PlayerData.Inventory[Emblem.Cost.Type.Value] >= Emblem.Cost.Amount.Value then
			PlayerData.Inventory[Emblem.Cost.Type.Value] = PlayerData.Inventory[Emblem.Cost.Type.Value] - Emblem.Cost.Amount.Value
			ReplicatedStorage.UpdateInventoryItem:FireClient(Player, Emblem.Cost.Type.Value, - (Emblem.Cost.Amount.Value))
			return true
		end
	end
	return false
end

function ReplicatedStorage.EquipEmblem.OnServerInvoke(Player, EmblemName)
	local PlayerData = Utl.GetPlayerData(Player.UserId)
	local Emblem = ReplicatedStorage.Emblems:FindFirstChild(EmblemName)
	if PlayerData.Emblems[EmblemName] then
		Player.Emblem.Value = EmblemName
	elseif buyEmblem(Player, Emblem) then
		PlayerData.Emblems[EmblemName] = true
		Player.Emblem.Value = EmblemName
	else
		return false
	end	
	return true
end

function ReplicatedStorage.EventGift.OnServerInvoke(Player)
	local PlayerData = Utl.GetPlayerData(Player.UserId)
	if PlayerData["HelenEvent"] == "Gift" then
		PlayerData["HelenEvent"] = "Done"



		awardXp(Player, 10000, Color3.new(1,1,1))
		Player.Gold.Value = Player.Gold.Value + 5000

		local Message = "Obtained 5000 Gold Coin!"
		ReplicatedStorage.Announce:FireClient(Player,Message,2,Color3.new(1, 209/255, 69/255))
		ReplicatedStorage.Announce:FireClient(Player,"Obtained Savior Badge",3,Color3.new(1,0,1))

		local Tycoon = Utl.GetTycoon(Player)
		if Tycoon and Tycoon:FindFirstChild("EventGift") and Tycoon.EventGift:FindFirstChild("EventGift") then
			Tycoon.EventGift.EventGift:Destroy()
		end
		return true
	end
	return false
end

function ReplicatedStorage.OpenDailyGift.OnServerInvoke(Player)
	local Today = Utl.CurrentDay()
	if Player.LastGift.Value < Today then
		local Level = ReplicatedStorage.Levels:FindFirstChild(Player.Level.Value)
		local AdvanceXP = Level:FindFirstChild("AdvanceXP") and Level.AdvanceXP.Value or 0
		local XPMulti = (Player.Level.Value < 7 and 15) or (Player.Level.Value < 10 and 100) or 700
		local XP = math.ceil(AdvanceXP*(math.random(2,5)/XPMulti) + 25)
		local Gold = math.ceil((10 ^ (Player.Level.Value/3)) * (math.random(1,10) / 100) + 50)
		awardXp(Player, XP, Color3.new(1,1,1))
		Player.Gold.Value = Player.Gold.Value + Gold
		local Amount = math.random(5,15)
		local Suffix = (Amount ~= 1 and "s") or ""
		local Message = "Obtained "..Amount.." Unobtainium Crystal"..Suffix.."!"
		Player.Crystals.Value = Player.Crystals.Value + Amount
		ReplicatedStorage.Announce:FireClient(Player,Message,2,Color3.new(1,51/255,167/255))
		ReplicatedStorage.Announce:FireClient(Player,"Thank you for logging in! Come back tomorrow!",3,Color3.new(1,0,1))
		Player.LastGift.Value = Today
		return true
	end
	return false
end


local function shareXp(Miner, XP, Color,LevelUp)
	if Miner.Character and Miner.Character:FindFirstChild("Torso") then
		for i,Player in pairs(workspace.Players:GetChildren()) do
			if Player:FindFirstChild("Lantern") and Player:FindFirstChild("Torso") and Player ~= Miner.Character then
				if (Miner.Character.Torso.Position - Player.Torso.Position).Magnitude <= Player.Lantern.Handle.PointLight.Range then
					awardXp(Players:GetPlayerFromCharacter(Player),math.ceil(XP/3),Color)
				end 				
			end
		end
	end
end

local function destroyOre(Ore)

	local Hitbox = Ore:IsA("Model") and Ore:FindFirstChild("Hitbox") or Ore


	local CompactPos = getCompactPositionFromWorldPosition(Hitbox.Position)


	UsedPositions[getPositionKey(CompactPos.X,CompactPos.Y,CompactPos.Z)] = false


	if Ore:FindFirstChild("AntiGen") == nil then		
		for i,Vec in pairs(VectorsMine) do
			local NewPos = CompactPos + Vec
			if UsedPositions[getPositionKey(NewPos.x,NewPos.y,NewPos.z)] == nil then

				generateOre(NewPos.x,NewPos.y,NewPos.z,false,nil,nil,nil)
			end
		end	
	end	
	Ore:Destroy()
end

-- Mining helpers -------------------------------------------------------------
local function grantUnobtainiumReward(player)
	local crystalAmount = math.random(1,4)
	if crystalAmount == 2 then crystalAmount = 1 end
	if crystalAmount == 4 then crystalAmount = 2 end

	local suffix = (crystalAmount ~= 1 and "s") or ""
	local message = "Found " .. crystalAmount .. " Unobtainium Crystal" .. suffix .. "!"
	ReplicatedStorage.Announce:FireClient(player, message, 2, Color3.new(1,51/255,167/255))
	player.Crystals.Value = player.Crystals.Value + crystalAmount
end

local function triggerBoomiteExplosion(ore)
	local explosion = Instance.new("Explosion")
	explosion.DestroyJointRadiusPercent = 0
	explosion.BlastRadius = 5
	explosion.Hit:Connect(function(hit)
		if hit.Parent:FindFirstChild("Humanoid") then
			hit.Parent.Humanoid:TakeDamage(5)
		elseif hit.Parent == workspace.Mine and hit ~= ore then
			destroyOre(hit)
		end
	end)
	explosion.Position = ore.Position
	explosion.Parent = workspace
	ore:Destroy()
end

local function advanceMiningTutorial(player, playerData)
	if player.Tutorial.Value == 3 then
		player.Tutorial.Value = 4
	end

	if player.Tutorial.Value == 4 then
		if playerData["Inventory"]["Coal"] + playerData["Storage"]["Coal"] >= 3 and playerData["Inventory"]["Iron"] + playerData["Storage"]["Iron"] >= 1 then
			player.Tutorial.Value = 5
		end
	end

	if player.Tutorial.Value == 7 then
		if playerData["Inventory"]["Coal"] + playerData["Storage"]["Coal"] >= 3 and playerData["Inventory"]["Iron"] + playerData["Storage"]["Iron"] >= 6 then
			player.Tutorial.Value = 8
		end
	end
end

local function applyPickaxeOnMineEffects(player, ore)
	if player.Pickaxe.Value == "Boomite" then
		local explodeChance = math.random(1,20)
		if explodeChance == 7 then
			local explodeSound = ReplicatedStorage.Ores.Boomite.BOOM:Clone()
			explodeSound.Parent = ore

			local explosion = Instance.new("Explosion")
			explosion.DestroyJointRadiusPercent = 0
			explosion.BlastRadius = math.random(1,10)
			explosion.Hit:Connect(function(hit)
				if hit.Parent == workspace.Mine and hit ~= ore then
					destroyOre(hit)
				end
			end)
			explosion.Position = ore.Position
			explosion.Parent = workspace
		end
	elseif player.Pickaxe.Value == "Dragonglass" then
		if ore:FindFirstChild("BOOM") then
			ore:FindFirstChild("BOOM").PlayOnRemove = false
		end
	end
end

local function getAwardedMiningXp(player, oreTemplate)
	local xp = oreTemplate.XP.Value
	if player.Pickaxe.Value == "Moonstone" then
		xp = math.floor(xp * 1.3)
	end

	return xp
end

local function shareMiningXp(player, ore, oreTemplate, xp)
	local beforeLevel = player.Level.Value
	awardXp(player, xp, oreTemplate.OreColor.Value)

	task.spawn(function()
		task.wait()
		local levelUp = player.Level.Value > beforeLevel
		if ore.Name ~= "Stone" or levelUp then
			shareXp(player, xp, oreTemplate.OreColor.Value, levelUp)
		end
	end)
end

local function clearBelowClaimTag(compactPosition)
	local belowOre = UsedPositions[getPositionKey(compactPosition.X, compactPosition.Y + 1, compactPosition.Z)]
	if belowOre and belowOre:FindFirstChild("Claimed") then
		belowOre.Claimed:Destroy()
	end
end

local function triggerSerendibiteChainMine(player, compactPosition)
	if player.Pickaxe.Value ~= "Serendibite" then
		return
	end

	local character = player.Character
	if not character or not character.PrimaryPart then
		return
	end

	local playerCompactPosition = getCompactPositionFromWorldPosition(character.PrimaryPart.Position)
	local playerDifference = compactPosition - playerCompactPosition
	local bestPosition
	local bestVector
	local minimumDifference = math.huge

	for _, vector in pairs(VectorsMine) do
		local difference = (vector - playerDifference).magnitude
		if difference < minimumDifference then
			minimumDifference = difference
			bestPosition = compactPosition + vector
			bestVector = vector
		end
	end

	if not bestPosition then
		return
	end

	local secondOre = UsedPositions[getPositionKey(bestPosition.x,bestPosition.y,bestPosition.z)]
	if secondOre then
		destroyOre(secondOre)
		local thirdPosition = bestPosition + bestVector
		local thirdOre = UsedPositions[getPositionKey(thirdPosition.x,thirdPosition.y,thirdPosition.z)]
		if thirdOre then
			destroyOre(thirdOre)
		end
	end
end

function ReplicatedStorage.ToSurface.OnServerInvoke(Player)
	local Tycoon = Utl.GetTycoon(Player)
	if Player then
		ReplicatedStorage.Teleported:FireClient(Player)
	end
	task.wait(0.8)
	if Player.Character then
		Player.Character:PivotTo(Tycoon.Spawn.CFrame + Vector3.new(0,6,0))	
	end	
	if Player.Tutorial.Value == 5 then
		Player.Tutorial.Value = 6
	end
end

function ServerStorage.MineOre.OnInvoke(Player,Ore,XPMulti)
	local RealOre = ReplicatedStorage.Ores:FindFirstChild(Ore.Name)
	if Ore:FindFirstChild("Claimed") == nil then
		local PlayerData = Utl.GetPlayerData(Player.UserId)		

		local Hitbox = Ore:IsA("Model") and Ore:FindFirstChild("Hitbox") or Ore
		local CompactPos = getCompactPositionFromWorldPosition(Hitbox.Position)
		local isMiningInsideBase = isOreInsidePlayerBase(Player, Ore)

		if Ore.Name == "Unobtainium" then
			grantUnobtainiumReward(Player)
		elseif Ore.Name == "Boomite" and Player.Pickaxe.Value ~= "Dragonglass" then
			triggerBoomiteExplosion(Ore)
		else


			PlayerData["Inventory"][Ore.Name] = PlayerData["Inventory"][Ore.Name] + 1
			ReplicatedStorage.UpdateInventoryItem:FireClient(Player,Ore.Name,1)

		end

		advanceMiningTutorial(Player, PlayerData)

	--[[	if Ore.Name ~= "Stone" then
			ReplicatedStorage.InventoryChanged:FireClient(Player,PlayerData)
	        end ]]

		if Ore and Ore:IsA("BasePart") then

			Player.OreMined.Value = Player.OreMined.Value + 1

			applyPickaxeOnMineEffects(Player, Ore)

			local xp = getAwardedMiningXp(Player, RealOre)
			shareMiningXp(Player, Ore, RealOre, xp)
		end


		UsedPositions[getPositionKey(CompactPos.X,CompactPos.Y,CompactPos.Z)] = false

		local Effect
		if Player.Pickaxe.Value == "Garnet" then
			Effect = "Stain"
		end
		if not isMiningInsideBase and Ore:FindFirstChild("AntiGen") == nil then
			generateNeighborOres(CompactPos, VectorsMine, Effect)
		end	


		if not isMiningInsideBase then
			for x = 1,3 do
				for y = 1,3 do
					for z = 1,3 do
						if CompactPos.Y + (y-2) > 0 then
							generateOre(CompactPos.X + (x-2),CompactPos.Y + (y-2), CompactPos.Z + (z-2))
						end
					end
				end
			end
		end

		clearBelowClaimTag(CompactPos)

		Ore:Destroy()
		triggerSerendibiteChainMine(Player, CompactPos)
	end
end

local function placeItem(Player, Position, Item)
	local PlayerData = Utl.GetPlayerData(Player.UserId)
	if PlayerData["Inventory"][Item.Name] > 0 then
		local Hitbox = Item.Hitbox
		Item.PrimaryPart = Hitbox

		local CompactPos = Vector3.new(0 + Position.X/6,(Position.Y - 5000)/(-6),Position.Z/6)

		if CompactPos.Y <= 4 then
			return false
		end

		local Spot = UsedPositions[getPositionKey(CompactPos.X,CompactPos.Y,CompactPos.Z)]
		if Spot == nil or Spot == false then

			local BelowOre = UsedPositions[getPositionKey(CompactPos.X,CompactPos.Y+1,CompactPos.Z)]

			if BelowOre and BelowOre:IsA("Model") and (BelowOre.Owner.Value ~= Player or (not BelowOre.Hitbox.CanCollide and not BelowOre:FindFirstChild("PlaceOn"))) then
				return false
			end			

			if not Item.Hitbox.CanCollide then
				if (BelowOre == nil or BelowOre == false) and (not Item.Hitbox.CanCollide) then
					return false
				elseif BelowOre and BelowOre:FindFirstChild("Claimed") then
					return false
				elseif BelowOre and BelowOre:IsA("BasePart") and BelowOre.Reflectance > 0 then
					return false
				elseif BelowOre == nil or BelowOre == false then
					BelowOre = generateOre(CompactPos.X,CompactPos.Y+1,CompactPos.Z,true,"Stone")
				end
				local ClaimedTag = Instance.new("BoolValue")
				ClaimedTag.Name = "Claimed"
				ClaimedTag.Parent = BelowOre
			end

			if Item.Name == "Teleport Pad" then -- ugly 
				local PreviousPad = Player.TPPad.Value
				if PreviousPad ~= nil and PreviousPad.Parent == workspace.Mine then
					local Position = PreviousPad.Hitbox.Position
					local CompactPos = Vector3.new(0 + Position.X/6,(Position.Y - 5000)/(-6),Position.Z/6)
					local BelowOre = UsedPositions[getPositionKey(CompactPos.X,CompactPos.Y+1,CompactPos.Z)]
					if BelowOre and BelowOre:FindFirstChild("Claimed") then
						BelowOre.Claimed:Destroy()
					end

					PreviousPad:Destroy()
					UsedPositions[getPositionKey(CompactPos.X,CompactPos.Y,CompactPos.Z)] = false

					PlayerData["Inventory"]["Teleport Pad"] = PlayerData["Inventory"]["Teleport Pad"] + 1
				end
				Player.TPPad.Value = Item	
			end			


			Item.Owner.Value = Player
			PlayerData["Inventory"][Item.Name] = PlayerData["Inventory"][Item.Name] - 1
			ReplicatedStorage.UpdateInventoryItem:FireClient(Player,Item.Name,-1)
			--		ReplicatedStorage.InventoryChanged:FireClient(Player,PlayerData)
			Item:PivotTo(CFrame.new(Position))
			Item.Parent = workspace.Mine

			UsedPositions[getPositionKey(CompactPos.X,CompactPos.Y,CompactPos.Z)] = Item




			return true
		end
	end
	return false
end

function ReplicatedStorage.Build.OnServerInvoke(Player, Position, ItemName)
	local Item = ReplicatedStorage.Ores:FindFirstChild(ItemName):Clone()
	return placeItem(Player, Position, Item)
end



math.random(os.time())

function ReplicatedStorage.ToggleMute.OnServerInvoke(Player)
	Player.Mute.Value = not Player.Mute.Value
end

local function canAfford(Player,Requirements)
	local PlayerData = Utl.GetPlayerData(Player.UserId)
	for i,Requirement in pairs(Requirements) do
		local Total = (PlayerData["Inventory"][Requirement.Name] or 0) + (PlayerData["Storage"][Requirement.Name] or 0)
		if Total < Requirement.Value then
			return false
		end
	end
	return true
end
local function handleCosts(Player, Costs)
	local PlayerData = Utl.GetPlayerData(Player.UserId)
	for i,Cost in pairs(Costs) do
		local CostAmount = Cost.Value
		if PlayerData["Inventory"][Cost.Name] < CostAmount then
			CostAmount = CostAmount - PlayerData["Inventory"][Cost.Name]
			PlayerData["Inventory"][Cost.Name] = 0
			PlayerData["Storage"][Cost.Name] = PlayerData["Storage"][Cost.Name] - CostAmount 
		else
			PlayerData["Inventory"][Cost.Name] = PlayerData["Inventory"][Cost.Name] - CostAmount
		end
	end
end


function ReplicatedStorage.Craft.OnServerInvoke(Player, ItemName)
	local PlayerData = Utl.GetPlayerData(Player.UserId)
	local Item = ReplicatedStorage.Ores:FindFirstChild(ItemName)
	if Item:FindFirstChild("Cost") then
		if canAfford(Player, Item.Cost:GetChildren()) then

			handleCosts(Player, Item.Cost:GetChildren())
			--		for i,Cost in pairs(Item.Cost:GetChildren()) do

			--			PlayerData["Inventory"][Cost.Name] = PlayerData["Inventory"][Cost.Name] - Cost.Value
			--		end
			PlayerData["Inventory"][Item.Name] = PlayerData["Inventory"][Item.Name] + 1

			ReplicatedStorage.InventoryChanged:FireClient(Player, PlayerData)
			return true
		else
			return false
		end
	end
end

function ReplicatedStorage.EventNextStep.OnServerInvoke(Player)
	local PlayerData = Utl.GetPlayerData(Player.UserId)
	if PlayerData["GoldQuest"] == nil or PlayerData["GoldQuest"] == "" then
		PlayerData["GoldQuest"] = "Started"
		Player.GoldQuest.Value = "Started"
	end
end

function ReplicatedStorage.Forge.OnServerInvoke(Player, PickaxeName)
	local PlayerData = Utl.GetPlayerData(Player.UserId)
	local Pickaxe = ReplicatedStorage.Pickaxes:FindFirstChild(PickaxeName)
	if PlayerData["Pickaxes"][PickaxeName] == true then
		Player.Pickaxe.Value = PickaxeName
		if Player.Tutorial.Value == 8 then
			Player.Tutorial.Value = -1 -- Congrats u r don!
		end

		return true
	elseif canAfford(Player, Pickaxe.Cost:GetChildren()) then
		Player.Pickaxe.Value = PickaxeName
		handleCosts(Player, Pickaxe.Cost:GetChildren())
		--	for i, Cost in pairs(Pickaxe.Cost:GetChildren()) do
		--		PlayerData["Inventory"][Cost.Name] = PlayerData["Inventory"][Cost.Name] - Cost.Value
		--	end
		PlayerData["Pickaxes"][PickaxeName] = true
		ReplicatedStorage.InventoryChanged:FireClient(Player,PlayerData)
		if Player.Tutorial.Value == 8 then
			Player.Tutorial.Value = -1 -- Congrats u r don!
		end

		return true
	end
	return false
end

function ReplicatedStorage.MoveAllItems.OnServerInvoke(Player)
	local PlayerData = Utl.GetPlayerData(Player.UserId)
	for Ore,Amount in pairs(PlayerData.Inventory) do
		local RealOre = ReplicatedStorage.Ores:FindFirstChild(Ore)
		if RealOre and RealOre:IsA("BasePart") then
			PlayerData.Storage[Ore] = PlayerData.Storage[Ore] + PlayerData.Inventory[Ore]
			PlayerData.Inventory[Ore] = 0
		end
	end
	return true
end

function ReplicatedStorage.MoveItem.OnServerInvoke(Player, Item, Source, Percent)
	Percent = Percent or 1
	if Percent > 1  or Percent < 0 then
		Percent = 1
	end
	local Target = (Source == "Inventory" and "Storage") or "Inventory"
	local PlayerData = Utl.GetPlayerData(Player.UserId)
	local Amount = math.floor(PlayerData[Source][Item] * Percent)
	PlayerData[Source][Item] = PlayerData[Source][Item] - Amount
	PlayerData[Target][Item] = PlayerData[Target][Item] + Amount
	--	ReplicatedStorage.InventoryChanged:FireClient(Player,PlayerData)
	local InventoryChangeAmount = (Target == "Inventory" and Amount) or -Amount
	ReplicatedStorage.InventoryChanged:FireClient(Player,PlayerData)
	return true
end

function ReplicatedStorage.BuyGear.OnServerInvoke(Player,GearShop)
	local Cost = GearShop.Cost.Value
	local Gear = game.ServerStorage:FindFirstChild(GearShop.Gear.Value)
	if Gear then
		if Player.Crystals.Value >= Cost then
			Player.Crystals.Value = Player.Crystals.Value - Cost
			Gear:Clone().Parent = Player.Backpack
			return true
		end
	end
	return false
end


local MountainOres = {"Coal","Coal","Silver","Iron","Iron","Silver","Ruby","Sapphire"}

local function setMineResetBarrier(isEnabled)
	workspace.Regen.Transparency = isEnabled and 0 or 1
	workspace.Regen.CanCollide = isEnabled
	workspace.Regen.CFrame = CFrame.new(81, isEnabled and 4995 or 5015, 81)
end

local function setTycoonCoversEnabled(isEnabled)
	for _, tycoon in pairs(workspace.Tycoons:GetChildren()) do
		tycoon.Cover.CFrame = CFrame.new(tycoon.Cover.Position.X, isEnabled and 4995 or 5015, tycoon.Cover.Position.Z)
		tycoon.Cover.CanCollide = isEnabled
		tycoon.Cover.Transparency = isEnabled and 0 or 1
	end
end

local function movePlayersToResetPlatform()
	for _, playerCharacter in pairs(workspace.Players:GetChildren()) do
		if playerCharacter:FindFirstChild("Torso") then
			playerCharacter.Torso.CFrame = workspace.Regen.CFrame + Vector3.new(math.random(-50,50),5,math.random(-50,50))
		end
	end
end

local function clearMineInBatches()
	local deleteCount = 1
	for _, ore in pairs(workspace.Mine:GetChildren()) do
		ore:Destroy()
		deleteCount = deleteCount + 1
		if deleteCount > 50 then
			deleteCount = 1
			task.wait()
		end
	end
end

local function seedMineRectangle(startX, width, startZ, depth)
	for x = startX, startX + width - 1 do
		for z = startZ, startZ + depth - 1 do
			generateOre(x, 1, z, false, nil, true)
		end
	end
end

local function seedCoreSpawns()
	for index = 1, 12 do
		local corePosition = Vector3.new(1200, 5000 - 6, index * 240)
		local compactCorePosition = getCompactPositionFromWorldPosition(corePosition)
		for x = 1, 3 do
			for z = 1, 3 do
				generateOre(compactCorePosition.X + x, 1, compactCorePosition.Z + z, false, nil, true)
			end
		end
	end
end

local function spawnMountainOres()
	for i,Loc in pairs(workspace.MountainSpawns:GetChildren()) do

		if (Loc.Ore.Value == nil or Loc.Ore.Value.Parent ~= workspace.Mine) and Loc:FindFirstChild("DragonStone") == nil then
			local OreName
			local Chance = math.random(1,300)
			if Chance == 77 then
				OreName = "Moonstone"
			else
				OreName = MountainOres[math.random(1,#MountainOres)]
			end
			local Ore = ReplicatedStorage.Ores:FindFirstChild(OreName):Clone()

			for i, Child in pairs(Ore:GetChildren()) do
				if Child:IsA("StringValue") or Child:IsA("NumberValue") or Child:IsA("Color3Value") or Child:IsA("IntValue") then
					Child:Destroy()
				end
			end	

			local Tag = Instance.new("BoolValue")
			Tag.Name = "AntiGen"
			Tag.Parent = Ore
			Ore.CFrame = Loc.CFrame
			Loc.Ore.Value = Ore

			Ore.Parent = workspace.Mine
		end
	end
end



local function generateMine()
	math.randomseed(os.time())
	setMineResetBarrier(true)
	setTycoonCoversEnabled(true)
	movePlayersToResetPlatform()
	clearMineInBatches()
	UsedPositions = {}
	seedMineRectangle(1, 26, 1, 26)
	seedMineRectangle(-29, 6, 1, 6)
	seedCoreSpawns()
	task.wait(1)
	setMineResetBarrier(false)
	setTycoonCoversEnabled(false)
	spawnMountainOres()
	ServerStorage.MineReset:Fire()
	repeat task.wait(10) until #workspace.Mine:GetChildren() > 100000
	generateMine()
end

Players.PlayerAdded:Connect(function(player)
	player:LoadCharacterAsync()
	player.Chatted:Connect(function(message)
		caveTeleportCommand(player, message)
		tryRunMaxOutCommand(player, message)
	end)

	player.CharacterAppearanceLoaded:Connect(function(character)
		if ReplicatedStorage.Characters:FindFirstChild(player.Name) == nil then
			character = player.Character or player.CharacterAdded:Wait()
			character.Archivable = true
			task.wait()
			local archivedCharacterModel = character:Clone()
			archivedCharacterModel.Name = player.Name
			archivedCharacterModel.Torso.Anchored = true
			archivedCharacterModel.Parent = ReplicatedStorage.Characters
			player.Character.Parent = ServerStorage.WorthlessGarbage
		end
	end)
end)

task.spawn(function()
	while task.wait(300) do
		spawnMountainOres()
	end
end)

generateMine()
