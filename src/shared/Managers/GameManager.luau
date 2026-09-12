local GameManager = {}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local PlaceManager = require(script.Parent.PlaceManager)
local DataManager = require(script.Parent.DataManager)
local GameSettings = require(script.Parent.Parent.Config.GameSettings)
local CharacterStability = require(script.Parent.Parent.Utils.CharacterStability)
local RelicHelper = require(script.Parent.Parent.Helpers.RelicHelper)
local OptionHelper = require(script.Parent.Parent.Helpers.OptionHelper)
local CostumeHelper = require(script.Parent.Parent.Helpers.CostumeHelper)
local Types = require(script.Parent.Parent.Types)

GameManager.State = {
	CurrentPhase = "Waiting", -- Waiting, Playing, Ended
	Players = {} :: { [number]: { Name: string, JoinTime: number } },
}

--[[
	보유 유물(레벨 1 이상, 활성화된 것만)의 어빌리티 중 optionType과 일치하는 것들을 합산.

	레벨 N인 유물은 levels[1]부터 levels[N]까지의 stat을 "레벨업 시 추가되는 증분"으로 보고
	누적 합산한다 (단순히 levels[N] 값만 쓰지 않음).

	예외: OptionData의 statCount==2인 "주기 충전" 타입(FeverGaugeAutoCharge, XpAutoCharge)은
	stat1이 "충전 주기(초)"를 의미하므로, stat1은 레벨 1..N 누적 합산에서 제외하고
	levels[N]의 값만 사용한다 (레벨이 오를수록 주기가 길어져 충전이 느려지는 회귀를 방지).
	stat2(틱당 충전량)는 statCount==1 타입의 stat1과 동일하게 1..N 누적 합산한다.

	주의(향후 확장 시 유의): "stat1을 누적하지 않는다"는 판단은 OptionData.types[optionType].statCount
	가 2 이상인지로 일반화해서 판별한다. 앞으로 새로 추가되는 statCount==2 타입도 전부 이 규칙을
	적용받으므로, 새 statCount==2 타입을 추가할 때 이 가정이 맞는지 반드시 확인할 것.
]]
local function collectRelicOptionTotal(player: Player, optionType: Types.OptionType): (number, number)
	local stat1Sum = 0
	local stat2Sum = 0

	local progress = DataManager.getRelicProgress(player)
	if not progress then
		return stat1Sum, stat2Sum
	end

	local typeDef = OptionHelper.getTypeDefinition(optionType)
	local isRateType = typeDef ~= nil and typeDef.statCount >= 2

	for relicId, entry in progress do
		if entry.level < 1 then
			continue
		end
		local relic = RelicHelper.getRelic(relicId)
		if not relic then
			continue
		end
		for _, ability in relic.abilities do
			if ability.type == optionType then
				if isRateType then
					local currentStat = ability.levels[entry.level]
					if currentStat then
						stat1Sum += currentStat.stat1
					end
				end

				for level = 1, entry.level do
					local stat = ability.levels[level]
					if stat then
						if not isRateType then
							stat1Sum += stat.stat1
						end
						stat2Sum += stat.stat2 or 0
					end
				end
			end
		end
	end

	return stat1Sum, stat2Sum
end

--[[
	보유 유물 세트(RelicData.sets) 완성 보너스 중 optionType과 일치하는 것을 합산.

	세트 효과는 abilities와 달리 레벨별 누적이 아니라 "레벨별 최종 수치"이므로(RelicData 주석 참고),
	세트 소속 유물 전원이 requiredRelicLevel 이상인 티어들 중 가장 높은 티어의 stat1만 반영한다
	(예: Lv.1/Lv.2 조건을 모두 충족해도 Lv.2 값만 적용되고 Lv.1+Lv.2로 합산하지 않음).
	조건을 만족하는 티어가 없으면 해당 세트는 0으로 취급.
]]
local function collectRelicSetOptionTotal(player: Player, optionType: Types.OptionType): (number, number)
	local stat1Sum = 0
	local stat2Sum = 0

	local progress = DataManager.getRelicProgress(player)
	if not progress then
		return stat1Sum, stat2Sum
	end

	for _, setId in RelicHelper.getSetIds() do
		local set = RelicHelper.getSet(setId)
		if not set or set.effect.type ~= optionType then
			continue
		end

		local achievedLevel = 0
		local achievedStat1 = 0
		for level, levelEntry in set.effect.levels do
			local met = true
			for _, relicId in set.relicIds do
				local relicEntry = progress[relicId]
				local relicLevel = if relicEntry then relicEntry.level else 0
				if relicLevel < levelEntry.requiredRelicLevel then
					met = false
					break
				end
			end
			if met and level > achievedLevel then
				achievedLevel = level
				achievedStat1 = levelEntry.stat1
			end
		end

		stat1Sum += achievedStat1
	end

	return stat1Sum, stat2Sum
end

--[[
	옵션 총합 소스 목록 — 추후 코스튬 등 다른 옵션 보유 대상이 추가되면
	동일한 (player, optionType) -> (stat1Sum, stat2Sum) 시그니처로 여기에 추가하면 됨.
]]
local OPTION_SOURCE_COLLECTORS: { (player: Player, optionType: Types.OptionType) -> (number, number) } = {
	collectRelicOptionTotal,
	collectRelicSetOptionTotal,
}

--[[
	플레이어가 보유한 모든 옵션 소스(현재는 유물)를 취합해 optionType의 stat1/stat2 총합을 반환.
	statCount가 1인 타입은 두 번째 반환값(stat2Sum)을 무시하면 됨.
]]
function GameManager.getPlayerOptionTotal(player: Player, optionType: Types.OptionType): (number, number)
	local stat1Sum = 0
	local stat2Sum = 0
	for _, collector in OPTION_SOURCE_COLLECTORS do
		local s1, s2 = collector(player, optionType)
		stat1Sum += s1
		stat2Sum += s2
	end
	return stat1Sum, stat2Sum
end

function GameManager.init()
	local placeType, stageNum = PlaceManager.getCurrentPlaceType()
	print("[GameManager] 초기화 - 플레이스 타입:", placeType, "스테이지:", stageNum or "N/A")

	Players.PlayerAdded:Connect(function(player)
		GameManager.onPlayerAdded(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		GameManager.onPlayerRemoving(player)
	end)

	for _, player in Players:GetPlayers() do
		GameManager.onPlayerAdded(player)
	end
end

function GameManager.onPlayerAdded(player: Player)
	GameManager.State.Players[player.UserId] = {
		Name = player.Name,
		JoinTime = os.time(),
	}
	print("[GameManager] 플레이어 등록:", player.Name)

	-- 로비는 ScaleModule이 없음 → 스폰 시 안정화만 여기서 적용. 스테이지는 ScaleModule 끝에서도 적용됨.
	local placeType = select(1, PlaceManager.getCurrentPlaceType())
	if placeType == "Lobby" then
		player.CharacterAdded:Connect(function(character: Model)
			task.wait(0.15)
			CharacterStability.apply(character)
		end)
		local existing = player.Character
		if existing then
			task.spawn(function()
				task.wait(0.15)
				CharacterStability.apply(existing)
			end)
		end
	end

	-- 장착 중인 코스튬 재적용: Lobby/Stage 양쪽 모두 GameManager.init()이 호출되므로 장소 무관하게 적용.
	local function applyEquippedCostume(character: Model)
		if DataManager.waitUntilLoaded(player) then
			CostumeHelper.applyEquippedCostumeToCharacter(player, character)
		end
	end
	player.CharacterAdded:Connect(applyEquippedCostume)
	if player.Character then
		task.spawn(applyEquippedCostume, player.Character)
	end
end

function GameManager.onPlayerRemoving(player: Player)
	GameManager.State.Players[player.UserId] = nil
	print("[GameManager] 플레이어 제거:", player.Name)
end

function GameManager.setPhase(phase: string)
	GameManager.State.CurrentPhase = phase
	print("[GameManager] 페이즈 변경:", phase)
end

function GameManager.getPlayerCount(): number
	local count = 0
	for _ in GameManager.State.Players do
		count += 1
	end
	return count
end

return GameManager
