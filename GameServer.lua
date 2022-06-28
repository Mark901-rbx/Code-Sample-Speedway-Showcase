-- Server-side functionality: Player handling, Game runtime
local GameService = script.Parent
local DB = game.ServerStorage.Database
local DBR = game.ReplicatedStorage.RemoteDatabase
local DS = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local printDebug = true -- toggle printing diagnostic messages
-- Set up references
local Garages = GameService.Garages


-- Player Management
function PlayerService(Player)
	-- Set up references & stats
	local Car
	local PlayerNumber
	local Garage

	-- Player number Assignment (for garage location)
	-- search for the first abandoned or empty garage slot
	for i, garageSlot in ipairs(Garages:GetChildren()) do
		if not garageSlot.Player.Value then
			PlayerNumber = i
			Garage = garageSlot
		break end
	end
	Garage.Player.Value = Player
	
	-- Setup Player data
	local PlayerData = script.PlayerFolder:clone()
	PlayerData.Name = Player.UserId
	PlayerData.Number.Value = PlayerNumber
	PlayerData.Parent = GameService.PlayerData
	-- Load save data
	if not RunService:IsStudio() then
		local PlayerDataStore = DS:GetDataStore("PlayerData:".. Player.UserId)
		local function LoadPlayerData(location)
			for _, object in pairs(location:GetChildren()) do
				if object:IsA("ValueBase") then
					local succeeded, savedValue
					local attempt = 0
					repeat
						if attempt > 0 then
							wait(0.1)
						end
						
						succeeded, savedValue = pcall(PlayerDataStore.GetAsync, PlayerDataStore, object.Name)
						attempt = attempt + 1
					until succeeded or attempt > 10
					
					if savedValue then
						object.Value = savedValue
					end
				elseif object.className == "Folder" then
					LoadPlayerData(object)
				end
			end
		end
		LoadPlayerData(PlayerData)
		PlayerData:SetAttribute("DataLoaded", true)
	end
	
	-- Leaderboard values
	-- create the native leaderboard container
	local leaderboard = Instance.new("StringValue")
	leaderboard.Name = "leaderstats"
	-- player's current top speed record
	local leaderboardRecord = Instance.new("StringValue", leaderboard)
	leaderboardRecord.Name = "Record"
	PlayerData.Record.Changed:connect(function(newRecord)
		if newRecord > 0 then
			leaderboardRecord.Value = tostring(newRecord) .."mph"
		else
			leaderboardRecord.Value = ""
		end
	end)
	-- player's current car
	local leaderboardCar = Instance.new("StringValue", leaderboard)
	leaderboardCar.Name = "Car"
	PlayerData.CurrentCar.Changed:connect(function(newCar)
		leaderboardCar.Value = newCar
	end)
	leaderboardCar.Value = PlayerData.CurrentCar.Value
	-- player number for garage system & spawning
	local leaderboardNumber = Instance.new("IntValue", leaderboard)
	leaderboardNumber.Name = "Garage"
	leaderboardNumber.Value = PlayerNumber
	-- leaderboard ready
	leaderboard.Parent = Player
end
game.Players.PlayerAdded:connect(PlayerService)
-- Connect save data on leave/shutdown
local function SavePlayerData(Player, PlayerID)
	if Player then PlayerID = Player.UserId end
	local PlayerData = GameService.PlayerData:findFirstChild(PlayerID)
	if not PlayerData:GetAttribute("DataLoaded") then return end

	local PlayerDataStore = DS:GetDataStore("PlayerData:".. PlayerID)
	local function WritePlayerData(location)
		for _, object in pairs(location:GetChildren()) do
			if object:IsA("ValueBase") then
				local succeeded, errorMsg
				local attempt = 0
				repeat
					if attempt > 0 then
						warn("Failed to save player data, attempt #".. attempt .." with message: ".. errorMsg)
						wait(0.1)
					end

					succeeded, errorMsg = pcall(function()
						PlayerDataStore:SetAsync(object.Name, object.Value)
					end)
					attempt = attempt + 1
				until succeeded or attempt > 10
			elseif object.className == "Folder" then
				WritePlayerData(object)
			end
		end
	end
	WritePlayerData(PlayerData)
end
-- save on server shutdown
game:BindToClose(function()
	for _, PlayerData in pairs(GameService.PlayerData:GetChildren()) do
		SavePlayerData(nil, PlayerData.Name)
	end
end)
-- save and clean up on player leave
game.Players.PlayerRemoving:connect(function(Player)
	if Player:findFirstChild("Car") and Player.Car.Value then
		Player.Car.Value:Destroy()
	end
	SavePlayerData(Player)
	local PlayerData = GameService.PlayerData:findFirstChild(Player.UserId)
	if PlayerData then
		local Garage = Garages[PlayerData.Number.Value]
		Garage.Player.Value = nil
		PlayerData:Destroy()
	end
end)

-- Game Functions
-- Player car spawning
function SpawnCar(Player, carName)
	local Car = DB.Cars[carName].Car:clone()
	local PlayerData = GameService.PlayerData[Player.UserId]
	-- get Player's garage number for spawn location
	local Garage = Garages[PlayerData.Number.Value]
	-- reset player's speed record from last session
	PlayerData.Record.Value = 0
	if Car:findFirstChild("PaintColor") then
		-- paint car with a color according to user's id
		local playerColorNumber = (Player.UserId % #script.PaintColors:GetChildren()) + 1
		local playerColor = script.PaintColors[playerColorNumber].Value
		Car.PaintColor.Value = playerColor
		for _, partTag in pairs(Car.PaintColor.PaintParts:GetChildren()) do
			partTag.Value.BrickColor = playerColor
			partTag.Value.Reflectance = 0.2
		end
	end
	-- move car above starting point
	local StartPoint = Garage.Position.Value.Position + Vector3.new(0, Car:GetExtentsSize().Y/4, 0) 
	local StartDirection = CFrame.fromEulerAnglesYXZ(0, math.rad(50), 0).lookVector
	Car:PivotTo(CFrame.new(StartPoint, StartPoint + StartDirection))
	-- reference tags for ownership and player name display
	local carTag = Instance.new("ObjectValue")
	carTag.Name = "Car"
	carTag.Value = Car
	carTag.Parent = Player
	local playerTag = Instance.new("ObjectValue")
	playerTag.Name = "Player"
	playerTag.Value = Player
	playerTag.Parent = Car
	Car.Parent = game.Workspace
	-- set up player control: wait for car to initialize itself, then give GUI to player and control starts
	while Car["A-Chassis Tune"]:findFirstChild("Plugins") do wait() end
	Car.PrimaryPart:SetNetworkOwner(Player)
	local Interface = Car["A-Chassis Tune"]["A-Chassis Interface"]:clone()
	Interface.Car.Value = Car
	Interface.Parent = Player.PlayerGui
	return Car
end

-- Server & Client Communication Setup
local Valet = game.ReplicatedStorage.Valet
local Teller = game.ReplicatedStorage.Teller

-- RemoteFunction "Valet" = Interface for client to fetch info from server
Valet.OnServerInvoke = function(Player, operation, variable1, variable2, variable3)
	if printDebug then print("Valet received request \"".. operation .."\" from ".. Player.Name) end
	if operation == "SpawnCar" then
		if Player:findFirstChild("Car") then
			Player.Car.Value:Destroy()
			Player.Car:Destroy()
		end
		local PlayerData = GameService.PlayerData[Player.UserId]
		local Car = SpawnCar(Player, PlayerData.CurrentCar.Value)
		return Car
	elseif operation == "RemoveCar" then
		if Player:findFirstChild("Car") then
			Player.Car.Value:Destroy()
			Player.Car:Destroy()
		end
		if Player.PlayerGui:FindFirstChild("A-Chassis Interface") then
			Player.PlayerGui["A-Chassis Interface"]:Destroy()
		end
	elseif operation == "GetCurrentTrack" then
		return GameService.CurrentTrack.Value
	elseif operation == "GetCurrentCar" then
		local PlayerData = GameService.PlayerData[Player.UserId]
		return PlayerData.CurrentCar.Value
	elseif operation == "GetPlayerMoney" then
		local PlayerData = GameService.PlayerData[Player.UserId]

		-- wait for player data to load
		if not RunService:IsStudio() then
			while not PlayerData:GetAttribute("DataLoaded") do
				wait(0.1)
			end
		end
		return PlayerData.Money.Value
	elseif operation == "GetShopCars" then -- return a table of car stats
		-- create a table of cars and their stats from server storage
		local shopCars = {}
		for _, shopCar in pairs(DB.Cars:GetChildren()) do
			local carInfo = {}
			carInfo.Name = shopCar.Name
			carInfo.Price = shopCar.Price.Value
			carInfo.TopSpeed = shopCar.TopSpeed.Value
			table.insert(shopCars, carInfo)
		end
		return shopCars
	elseif operation == "CheckPlayerOwnsCar" then -- return player owns car true or false
		local carName = variable1 -- name received variables for readability
		local PlayerData = GameService.PlayerData:FindFirstChild(Player.UserId)
		if not PlayerData.Cars:findFirstChild(carName) then return end
		return PlayerData.Cars[carName].Value
	elseif operation == "BuyShopCar" then -- return whether purchase was a success true or false
		local carName = variable1 -- name received variables for readability
		local carInfo = DB.Cars:findFirstChild(carName)
		if not carInfo then return false end
		local PlayerData = GameService.PlayerData:FindFirstChild(Player.UserId)
		if PlayerData.Money.Value < carInfo.Price.Value then return false end
		-- passed checks, purchase car
		PlayerData.Money.Value = PlayerData.Money.Value - carInfo.Price.Value
		PlayerData.Cars[carName].Value = true
		Teller:FireClient(Player, "MoneyUpdated", PlayerData.Money.Value)
		return true
	elseif operation == "SwapCar" then -- return if car swap was a success
		local carName = variable1 -- name received variables for readability
		local PlayerData = GameService.PlayerData:FindFirstChild(Player.UserId)
		if not PlayerData.Cars:findFirstChild(carName) then return end
		PlayerData.CurrentCar.Value = carName
		return true
	elseif operation == "GetPlayerGarage" then
		local PlayerData = GameService.PlayerData:FindFirstChild(Player.UserId)
		local PlayerGarage = Garages[PlayerData.Number.Value].Model.Value
		return PlayerGarage
	end
end
-- prepare display-only models for client side
local function RemoveExtras(model)
	for _, object in pairs(model:GetChildren()) do
		if #object:GetChildren() > 0 then
			RemoveExtras(object)
		end
		if not object:IsA("BasePart") and object.className ~= "Model" then object:Destroy() end
	end
end
for _, carFolder in pairs(DB.Cars:GetChildren()) do
	local displayCar = carFolder.Car:clone()
	RemoveExtras(displayCar)
	displayCar:SetAttribute("IsCar", nil)
	displayCar.Name = carFolder.Name
	displayCar.Parent = DBR.CarDisplayModels
end

-- Server-side Runtime
-- wait for players to load in
repeat wait(1) until #game.Players:GetChildren() > 0

-- Award speed reward for each player
local numPlayers = 0
local speedScale = (10/12) * (60/88) -- (using same scale as the existing car system) "1 stud : 10 inches | ft/s to MPH"
local waitInterval = 3 -- frequency of reward
local rewardUnits = 10 -- give reward in multiples of this number
-- award cash for player speed between 50 (minimum reward speed) and 400 (practical limit, don't reward flinging)
local minimumRewardSpeed = 50
local maximumRewardSpeed = 400
pcall(function() -- start constant reward loop
	-- reward function
	local function GiveSpeedReward()
		repeat -- coroutine yield loop
			numPlayers = #game.Players:GetChildren()
			-- spread out award calculation to avoid hitching
			for i, Player in ipairs(game.Players:GetChildren()) do
				if Player:findFirstChild("Car") and Player.Car.Value:GetAttribute("IsCar") and Player.Car.Value.PrimaryPart then
					local PlayerData = GameService.PlayerData:FindFirstChild(Player.UserId)
					local playerSpeed = math.floor(Player.Car.Value.PrimaryPart.Velocity.magnitude * speedScale)
					if playerSpeed > minimumRewardSpeed and playerSpeed < maximumRewardSpeed then
						-- award cash in multiples of rewardUnits
						local reward = math.floor(playerSpeed / rewardUnits) * rewardUnits
						print(Player.Name .." caught traveling at ".. playerSpeed .." mph, award $".. reward)
						PlayerData.Money.Value = PlayerData.Money.Value + reward
						Teller:FireClient(Player, "MoneyUpdated", PlayerData.Money.Value)
						-- update player's speed record
						if playerSpeed > PlayerData.Record.Value then
							PlayerData.Record.Value = playerSpeed
							Teller:FireClient(Player, "RecordUpdated")
						end
					end
				end
				wait(waitInterval/numPlayers)
			end
		until coroutine.yield()
	end
	-- reward loop
	local GiveReward = coroutine.create(GiveSpeedReward)
	repeat
		coroutine.resume(GiveReward)
		wait(waitInterval)
	until false
end)
