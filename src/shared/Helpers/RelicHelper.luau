--[[
	RelicHelper (shared)

	마스터 데이터: DataManager.getRelicDataRaw() (서버) / ReplicatedStorage.DataTable.RelicData (클라이언트)

	RemoteFunction SummonRelics(pool, count) → { { id, name, grade }, ... }
	소환 시 RelicData.summons 비용만큼 재화 차감. 부족 시 빈 배열 반환.
	뽑힌 유물마다 SavedPlayerData.Relics XP +1 (lv.4 캡, 자동 레벨업 없음).
	Normal: D, C / Special: B, A

	RemoteFunction GetRelicProgress → RelicProgress (클라이언트 RelicPopup용)
	RemoteFunction UpgradeRelic(relicId) → RelicProgressEntry? (수동 레벨업)

	XP는 요구치 도달 후에도 자동 레벨업하지 않고 계속 누적된다.
	유저가 UpgradeRelic 호출 시 1레벨 상승, XP에서 요구치만큼 차감(초과분 유지).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataManager = require(Shared.Managers.DataManager)
local AchievementHelper = require(Shared.Helpers.AchievementHelper)
local Types = require(Shared.Types)

local RelicHelper = {}

export type RelicGrade = Types.RelicGrade
export type RelicAbilityLevelStat = Types.RelicAbilityLevelStat
export type RelicAbility = Types.RelicAbility
export type RelicDefinition = Types.RelicDefinition
export type RelicDataSource = Types.RelicDataSource
export type SummonCostEntry = Types.SummonCostEntry
export type RelicSummonCosts = Types.RelicSummonCosts
export type RelicProgress = Types.RelicProgress
export type RelicProgressEntry = Types.RelicProgressEntry
export type RelicSetLevelEntry = Types.RelicSetLevelEntry
export type RelicSetEffect = Types.RelicSetEffect
export type RelicSetDefinition = Types.RelicSetDefinition
export type SummonPool = "Normal" | "Special"
export type SummonRelicResult = {
	id: number,
	name: string,
	grade: string,
}

local SUMMON_REMOTE_NAME = "SummonRelics"
local PROGRESS_REMOTE_NAME = "GetRelicProgress"
local UPGRADE_REMOTE_NAME = "UpgradeRelic"

-- 1회 소환당 1개 소모. 보유량이 count 이상이면 재화 대신 이 아이템으로 소환.
local SUMMON_KEY_ITEM_TYPE: { [SummonPool]: Types.ItemType } = {
	Normal = "RelicNormalKey",
	Special = "RelicSpecialKey",
}

local DEFAULT_LEVEL_XP_REQUIRED: Types.RelicLevelXpRequired = {
	[0] = 10,
	[1] = 30,
	[2] = 50,
	[3] = 70,
}

local NORMAL_GRADES: { [string]: boolean } = { D = true, C = true }
local SPECIAL_GRADES: { [string]: boolean } = { B = true, A = true }

local VALID_RELIC_GRADES: { [string]: RelicGrade } = {
	A = "A",
	B = "B",
	C = "C",
	D = "D",
}

local SET_GRADE_ORDER: { [string]: number } = { D = 1, C = 2, B = 3, A = 4 }

local RELIC_FOLDER_PATH = { "Client", "Relic" }

-- Slot(ItemFrame_01_White_Bg) 틴트 색상 — RelicSummonPopup/RelicPopup 공용
local GRADE_SLOT_COLORS: { [string]: Color3 } = {
	D = Color3.fromRGB(76, 175, 80),
	C = Color3.fromRGB(48, 86, 255),
	B = Color3.fromRGB(156, 39, 176),
	A = Color3.fromRGB(255, 152, 0),
}

local initialized = false
local runtime: RelicDataSource? = nil
local summonRemote: RemoteFunction? = nil
local progressRemote: RemoteFunction? = nil
local upgradeRemote: RemoteFunction? = nil
local maxLevelCached: number? = nil
local relicIconFolder: Folder? = nil

local function buildFallbackSource(): RelicDataSource
	local relics: { [number]: RelicDefinition } = {
		[101] = { id = 101, name = "Relic_01", grade = "D", icon = "", abilities = {} },
		[301] = { id = 301, name = "Relic_08", grade = "B", icon = "", abilities = {} },
	}
	return {
		relics = relics,
		levelXpRequired = table.clone(DEFAULT_LEVEL_XP_REQUIRED),
		summons = {
			Normal = {
				[1] = { currencyType = "Gold", amount = 100 },
				[10] = { currencyType = "Gold", amount = 1000 },
			},
			Special = {
				[1] = { currencyType = "Gem", amount = 100 },
				[10] = { currencyType = "Gem", amount = 1000 },
			},
		},
	}
end

local function normalizeRelicId(raw: any): number?
	if typeof(raw) ~= "number" or raw ~= raw then
		return nil
	end
	local id = math.floor(raw)
	if id < 1 then
		return nil
	end
	return id
end

local function normalizeRelicGrade(raw: any): RelicGrade?
	if typeof(raw) ~= "string" then
		return nil
	end
	return VALID_RELIC_GRADES[raw]
end

local function normalizeAbilityLevelStat(raw: any): Types.RelicAbilityLevelStat?
	if typeof(raw) ~= "table" then
		return nil
	end
	local stat1 = if typeof(raw.stat1) == "number" and raw.stat1 == raw.stat1 then raw.stat1 else nil
	if stat1 == nil then
		return nil
	end
	local stat2 = if typeof(raw.stat2) == "number" and raw.stat2 == raw.stat2 then raw.stat2 else nil
	return {
		stat1 = stat1,
		stat2 = stat2,
	}
end

local function normalizeAbilityLevels(raw: any): { [number]: Types.RelicAbilityLevelStat }
	local levels: { [number]: Types.RelicAbilityLevelStat } = {}
	if typeof(raw) ~= "table" then
		return levels
	end
	for key, value in raw do
		local level = if typeof(key) == "number" then key else tonumber(key)
		if typeof(level) ~= "number" or level ~= level then
			continue
		end
		level = math.floor(level)
		if level < 1 then
			continue
		end
		local stat = normalizeAbilityLevelStat(value)
		if stat then
			levels[level] = stat
		end
	end
	return levels
end

local function normalizeAbility(raw: any): Types.RelicAbility?
	if typeof(raw) ~= "table" then
		return nil
	end
	local abilityType = Types.normalizeOptionType(raw.type)
	if not abilityType then
		return nil
	end
	local levels = normalizeAbilityLevels(raw.levels)
	if next(levels) == nil then
		return nil
	end
	return {
		type = abilityType,
		levels = levels,
	}
end

local function normalizeAbilities(raw: any): { Types.RelicAbility }
	local abilities: { Types.RelicAbility } = {}
	if typeof(raw.abilities) ~= "table" then
		return abilities
	end
	for _, entry in raw.abilities do
		local ability = normalizeAbility(entry)
		if ability then
			table.insert(abilities, ability)
		end
	end
	return abilities
end

local function cloneAbilityLevels(levels: { [number]: Types.RelicAbilityLevelStat }): { [number]: Types.RelicAbilityLevelStat }
	local cloned: { [number]: Types.RelicAbilityLevelStat } = {}
	for level, stat in levels do
		cloned[level] = { stat1 = stat.stat1, stat2 = stat.stat2 }
	end
	return cloned
end

local function cloneAbilities(abilities: { Types.RelicAbility }): { Types.RelicAbility }
	local cloned: { Types.RelicAbility } = {}
	for _, ability in abilities do
		table.insert(cloned, {
			type = ability.type,
			levels = cloneAbilityLevels(ability.levels),
		})
	end
	return cloned
end

local function normalizeSummonCost(raw: any): SummonCostEntry?
	if typeof(raw) ~= "table" then
		return nil
	end
	local currencyType = Types.normalizeCurrencyType(raw.currencyType)
	local amount = if typeof(raw.amount) == "number" and raw.amount > 0 then math.floor(raw.amount) else nil
	if not currencyType or not amount then
		return nil
	end
	return {
		currencyType = currencyType,
		amount = amount,
	}
end

local function normalizeSummonPoolCosts(raw: any): Types.RelicSummonPoolCosts?
	if typeof(raw) ~= "table" then
		return nil
	end

	local costs: Types.RelicSummonPoolCosts = {}
	for _, count in { 1, 10 } do
		local cost = normalizeSummonCost(raw[count])
		if cost then
			costs[count] = cost
		end
	end

	if costs[1] == nil or costs[10] == nil then
		return nil
	end

	return costs
end

local function normalizeSummons(raw: any): RelicSummonCosts?
	if typeof(raw) ~= "table" then
		return nil
	end

	local normal = normalizeSummonPoolCosts(raw.Normal)
	local special = normalizeSummonPoolCosts(raw.Special)
	if not normal or not special then
		return nil
	end

	return {
		Normal = normal,
		Special = special,
	}
end

local function normalizeLevelXpRequired(raw: any): Types.RelicLevelXpRequired
	local out: Types.RelicLevelXpRequired = table.clone(DEFAULT_LEVEL_XP_REQUIRED)
	if typeof(raw) ~= "table" then
		return out
	end
	for key, value in raw do
		local level = if typeof(key) == "number" then key else tonumber(key)
		if typeof(level) ~= "number" or level ~= level then
			continue
		end
		level = math.floor(level)
		if level < 0 then
			continue
		end
		if typeof(value) == "number" and value == value and value > 0 then
			out[level] = math.floor(value)
		end
	end
	return out
end

local function normalizeRelicDefinition(raw: any, tableKeyId: number?): RelicDefinition?
	if typeof(raw) ~= "table" then
		return nil
	end
	local idFromRow = normalizeRelicId(raw.id)
	local id = tableKeyId or idFromRow
	if id == nil then
		return nil
	end
	if idFromRow ~= nil and idFromRow ~= id then
		warn(string.format("[RelicHelper] RelicData id 불일치 (key=%d, row.id=%d) — key 사용", id, idFromRow))
	end
	local grade = normalizeRelicGrade(raw.grade)
	if not grade then
		return nil
	end
	local name = if typeof(raw.name) == "string" and raw.name ~= "" then raw.name else string.format("Relic_%d", id)
	local icon = if typeof(raw.icon) == "string" then raw.icon else ""
	local abilities = normalizeAbilities(raw)
	return {
		id = id,
		name = name,
		grade = grade,
		icon = icon,
		abilities = abilities,
	}
end

local function normalizeSetLevelEntry(raw: any): Types.RelicSetLevelEntry?
	if typeof(raw) ~= "table" then
		return nil
	end
	local stat1 = if typeof(raw.stat1) == "number" and raw.stat1 == raw.stat1 then raw.stat1 else nil
	local requiredRelicLevel = if typeof(raw.requiredRelicLevel) == "number" and raw.requiredRelicLevel == raw.requiredRelicLevel
		then math.floor(raw.requiredRelicLevel)
		else nil
	if stat1 == nil or requiredRelicLevel == nil then
		return nil
	end
	return {
		stat1 = stat1,
		requiredRelicLevel = requiredRelicLevel,
	}
end

local function normalizeSetLevels(raw: any): { [number]: Types.RelicSetLevelEntry }
	local levels: { [number]: Types.RelicSetLevelEntry } = {}
	if typeof(raw) ~= "table" then
		return levels
	end
	for key, value in raw do
		local level = if typeof(key) == "number" then key else tonumber(key)
		if typeof(level) ~= "number" or level ~= level then
			continue
		end
		level = math.floor(level)
		if level < 1 then
			continue
		end
		local entry = normalizeSetLevelEntry(value)
		if entry then
			levels[level] = entry
		end
	end
	return levels
end

local function normalizeSetEffect(raw: any): Types.RelicSetEffect?
	if typeof(raw) ~= "table" then
		return nil
	end
	local effectType = Types.normalizeOptionType(raw.type)
	if not effectType then
		return nil
	end
	local levels = normalizeSetLevels(raw.levels)
	if next(levels) == nil then
		return nil
	end
	return {
		type = effectType,
		levels = levels,
	}
end

local function normalizeSetRelicIds(raw: any): { number }
	local ids: { number } = {}
	if typeof(raw) ~= "table" then
		return ids
	end
	for _, value in raw do
		local id = normalizeRelicId(value)
		if id then
			table.insert(ids, id)
		end
	end
	return ids
end

local function normalizeSetDefinition(raw: any): Types.RelicSetDefinition?
	if typeof(raw) ~= "table" then
		return nil
	end
	local grade = normalizeRelicGrade(raw.grade)
	if not grade then
		return nil
	end
	local relicIds = normalizeSetRelicIds(raw.relicIds)
	if #relicIds == 0 then
		return nil
	end
	local effect = normalizeSetEffect(raw.effect)
	if not effect then
		return nil
	end
	return {
		grade = grade,
		relicIds = relicIds,
		effect = effect,
	}
end

local function normalizeSets(raw: any): { [string]: Types.RelicSetDefinition }
	local sets: { [string]: Types.RelicSetDefinition } = {}
	if typeof(raw) ~= "table" then
		return sets
	end
	for key, value in raw do
		if typeof(key) ~= "string" then
			continue
		end
		local set = normalizeSetDefinition(value)
		if set then
			sets[key] = set
		end
	end
	return sets
end

local function cloneSetDefinition(set: Types.RelicSetDefinition): Types.RelicSetDefinition
	local relicIds = table.clone(set.relicIds)
	local levels: { [number]: Types.RelicSetLevelEntry } = {}
	for level, entry in set.effect.levels do
		levels[level] = { stat1 = entry.stat1, requiredRelicLevel = entry.requiredRelicLevel }
	end
	return {
		grade = set.grade,
		relicIds = relicIds,
		effect = {
			type = set.effect.type,
			levels = levels,
		},
	}
end

local function normalizeSource(raw: any): RelicDataSource?
	if typeof(raw) ~= "table" then
		return nil
	end
	local rows = raw.relics
	if typeof(rows) ~= "table" then
		rows = raw.pets -- legacy PetData key
	end
	if typeof(rows) ~= "table" then
		return nil
	end

	local relics: { [number]: RelicDefinition } = {}
	for key, relicRaw in rows do
		local relicId = normalizeRelicId(if typeof(key) == "number" then key else tonumber(key))
		if relicId == nil then
			continue
		end
		local relic = normalizeRelicDefinition(relicRaw, relicId)
		if relic then
			relics[relicId] = relic
		end
	end

	if next(relics) == nil then
		return nil
	end

	local summons = normalizeSummons(raw.summons)
	if not summons then
		summons = buildFallbackSource().summons
		warn("[RelicHelper] RelicData.summons 없음/형식 오류 — fallback 사용")
	end

	local levelXpRequired = normalizeLevelXpRequired(raw.levelXpRequired)
	local sets = normalizeSets(raw.sets)

	return {
		relics = relics,
		levelXpRequired = levelXpRequired,
		summons = summons,
		sets = sets,
	}
end

local function loadRelicDataRaw(): any?
	if RunService:IsServer() then
		local raw = DataManager.getRelicDataRaw()
		if raw ~= nil then
			return raw
		end
		local ok, result = pcall(function()
			return require(ServerStorage:WaitForChild("DataTable"):WaitForChild("RelicData"))
		end)
		if ok then
			return result
		end
		return nil
	end

	local ok, result = pcall(function()
		return require(ReplicatedStorage:WaitForChild("DataTable"):WaitForChild("RelicData"))
	end)
	if ok then
		return result
	end
	return nil
end

local function getRuntime(): RelicDataSource
	if not runtime then
		local raw = loadRelicDataRaw()
		local normalized = if raw ~= nil then normalizeSource(raw) else nil
		if normalized then
			runtime = normalized
			local count = 0
			for _ in normalized.relics do
				count += 1
			end
			print(string.format("[RelicHelper] RelicData 로드 (%d개)", count))
		else
			runtime = buildFallbackSource()
			warn(
				"[RelicHelper] RelicData 없음/형식 오류 — fallback 사용 (src/datatable/RelicData.luau)"
			)
		end
		maxLevelCached = nil
	end
	return runtime :: RelicDataSource
end

local function cloneDefinition(relic: RelicDefinition): RelicDefinition
	return {
		id = relic.id,
		name = relic.name,
		grade = relic.grade,
		icon = relic.icon,
		abilities = cloneAbilities(relic.abilities),
	}
end

function RelicHelper.getMaxLevel(): number
	if maxLevelCached then
		return maxLevelCached
	end
	local highestFrom = -1
	for level in getRuntime().levelXpRequired do
		if level > highestFrom then
			highestFrom = level
		end
	end
	maxLevelCached = math.max(1, highestFrom + 1)
	return maxLevelCached
end

function RelicHelper.getXpRequiredForNextLevel(level: number): number?
	if typeof(level) ~= "number" or level ~= level then
		return nil
	end
	local current = math.floor(level)
	if current < 0 or current >= RelicHelper.getMaxLevel() then
		return nil
	end
	local required = getRuntime().levelXpRequired[current]
	if typeof(required) ~= "number" or required <= 0 then
		return nil
	end
	return required
end

function RelicHelper.getRelic(id: number): RelicDefinition?
	local relicId = normalizeRelicId(id)
	if relicId == nil then
		return nil
	end
	local relic = getRuntime().relics[relicId]
	if not relic then
		return nil
	end
	return cloneDefinition(relic)
end

function RelicHelper.getRelicByName(name: string): RelicDefinition?
	if typeof(name) ~= "string" or name == "" then
		return nil
	end
	for relicId, relic in getRuntime().relics do
		if relic.name == name then
			return RelicHelper.getRelic(relicId)
		end
	end
	return nil
end

function RelicHelper.getIconName(id: number): string?
	local relic = RelicHelper.getRelic(id)
	if not relic or relic.icon == "" then
		return nil
	end
	return relic.icon
end

function RelicHelper.getGradeSlotColor(grade: string): Color3?
	return GRADE_SLOT_COLORS[grade]
end

--[[
	Slot(Instance) 하위의 ItemFrame_01_White_Bg(ImageLabel)를 등급 색으로 틴트.
	RelicSummonPopup / RelicPopup 공용.
]]
function RelicHelper.applyGradeSlotBg(slotContainer: Instance, grade: string)
	local bgInst = slotContainer:FindFirstChild("ItemFrame_01_White_Bg", true)
	if bgInst and bgInst:IsA("ImageLabel") then
		local color = GRADE_SLOT_COLORS[grade]
		if color then
			(bgInst :: ImageLabel).ImageColor3 = color
		end
	end
end

local function resolveRelicIconFolder(): Folder?
	if relicIconFolder then
		return relicIconFolder
	end

	local folder: Instance = ReplicatedStorage
	for _, name in RELIC_FOLDER_PATH do
		local child = folder:FindFirstChild(name)
		if not child then
			warn("[RelicHelper] ReplicatedStorage." .. table.concat(RELIC_FOLDER_PATH, ".") .. " 없음")
			return nil
		end
		folder = child
	end

	if folder:IsA("Folder") then
		relicIconFolder = folder
		return folder
	end

	warn("[RelicHelper] Client.Relic 가 Folder 가 아님")
	return nil
end

local function findRelicIconImageLabel(root: Instance): ImageLabel?
	local direct = root:FindFirstChild("RelicIcon")
	if direct and direct:IsA("ImageLabel") then
		return direct
	end
	for _, desc in root:GetDescendants() do
		if desc.Name == "RelicIcon" and desc:IsA("ImageLabel") then
			return desc
		end
	end
	return nil
end

local function applyImageLabelImageProperties(source: ImageLabel, target: ImageLabel)
	-- 동일 Image(스프라이트 시트)에서 rect만 바뀔 때 UI가 갱신되지 않는 경우 방지
	if target.Image == source.Image then
		target.ImageRectOffset = Vector2.new(0, 0)
		target.ImageRectSize = Vector2.new(1, 1)
	end

	target.Image = source.Image
	target.ImageColor3 = source.ImageColor3
	target.ImageRectOffset = source.ImageRectOffset
	target.ImageRectSize = source.ImageRectSize
	target.ImageTransparency = source.ImageTransparency
	target.ResampleMode = source.ResampleMode
	target.ScaleType = source.ScaleType

	local aspect = target:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspect and source.ImageRectSize.Y > 0 then
		aspect.AspectRatio = source.ImageRectSize.X / source.ImageRectSize.Y
	end
end

local function getSourceRelicIcon(relicId: number): ImageLabel?
	local folder = resolveRelicIconFolder()
	if not folder then
		return nil
	end
	local relic = RelicHelper.getRelic(relicId)
	local iconName = if relic and relic.icon ~= "" then relic.icon else nil
	if not iconName then
		warn("[RelicHelper] RelicData.icon 없음 (id=", relicId, ")")
		return nil
	end
	local inst = folder:FindFirstChild(iconName)
	if not inst then
		warn("[RelicHelper] Client.Relic." .. iconName, "없음")
		return nil
	end
	if inst:IsA("ImageLabel") then
		return inst :: ImageLabel
	end
	local nested = findRelicIconImageLabel(inst)
	if nested then
		return nested
	end
	warn("[RelicHelper] Client.Relic." .. iconName, "에 ImageLabel 없음")
	return nil
end

--[[
	root 하위(자기 자신 포함)에서 이름이 "RelicIcon"인 ImageLabel을 찾아
	ReplicatedStorage.Client.Relic 원본 아이콘 이미지를 복사해 적용.
	RelicSummonPopup / RelicPopup 공용.
]]
function RelicHelper.findRelicIconImageLabel(root: Instance): ImageLabel?
	return findRelicIconImageLabel(root)
end

function RelicHelper.applyRelicIconToImageLabel(relicIconInst: Instance, relicId: number): boolean
	if not relicIconInst:IsA("ImageLabel") then
		return false
	end
	local source = getSourceRelicIcon(relicId)
	if not source then
		return false
	end
	applyImageLabelImageProperties(source, relicIconInst :: ImageLabel)
	return true
end

function RelicHelper.getAllRelics(): { [number]: RelicDefinition }
	local out: { [number]: RelicDefinition } = {}
	for relicId, relic in getRuntime().relics do
		out[relicId] = cloneDefinition(relic)
	end
	return out
end

function RelicHelper.getRelicIds(): { number }
	local ids: { number } = {}
	for relicId in getRuntime().relics do
		table.insert(ids, relicId)
	end
	table.sort(ids)
	return ids
end

-- 하위 호환 별칭
function RelicHelper.getRelicIndices(): { number }
	return RelicHelper.getRelicIds()
end

function RelicHelper.getRelicCount(): number
	local count = 0
	for _ in getRuntime().relics do
		count += 1
	end
	return count
end

function RelicHelper.getSetIds(): { string }
	local ids: { string } = {}
	local sets = getRuntime().sets
	if not sets then
		return ids
	end
	for setId in sets do
		table.insert(ids, setId)
	end
	table.sort(ids, function(a, b)
		local orderA = SET_GRADE_ORDER[sets[a].grade] or 0
		local orderB = SET_GRADE_ORDER[sets[b].grade] or 0
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a < b
	end)
	return ids
end

function RelicHelper.getSet(setId: string): RelicSetDefinition?
	if typeof(setId) ~= "string" then
		return nil
	end
	local sets = getRuntime().sets
	local set = sets and sets[setId]
	if not set then
		return nil
	end
	return cloneSetDefinition(set)
end

function RelicHelper.getSetCount(): number
	local count = 0
	local sets = getRuntime().sets
	if not sets then
		return count
	end
	for _ in sets do
		count += 1
	end
	return count
end

local function normalizePool(raw: any): SummonPool?
	if raw == "Normal" or raw == "Special" then
		return raw
	end
	return nil
end

local function normalizeCount(raw: any): number?
	if raw == 1 or raw == 10 then
		return raw
	end
	return nil
end

function RelicHelper.getSummonCost(pool: SummonPool, count: number): SummonCostEntry?
	local normalizedCount = normalizeCount(count)
	if not normalizedCount then
		return nil
	end

	local summons = getRuntime().summons
	if not summons then
		return nil
	end

	local poolCosts = summons[pool]
	if not poolCosts then
		return nil
	end

	return poolCosts[normalizedCount]
end

function RelicHelper.getSummonKeyItemType(pool: SummonPool): Types.ItemType?
	return SUMMON_KEY_ITEM_TYPE[pool]
end

function RelicHelper.addRelicXp(player: Player, relicId: number, amount: number): RelicProgressEntry?
	if not RunService:IsServer() then
		return nil
	end
	local id = normalizeRelicId(relicId)
	if id == nil or not RelicHelper.getRelic(id) then
		return nil
	end
	local delta = if typeof(amount) == "number" and amount == amount then math.floor(amount) else 0
	if delta <= 0 then
		return DataManager.getRelicProgressEntry(player, id)
	end

	local entry = DataManager.getRelicProgressEntry(player, id)
	if not entry then
		return nil
	end

	local maxLevel = RelicHelper.getMaxLevel()
	if entry.level >= maxLevel then
		return entry
	end

	entry.xp += delta

	if not DataManager.setRelicProgressEntry(player, id, entry) then
		return nil
	end
	return entry
end

function RelicHelper.canRelicLevelUp(level: number, xp: number): boolean
	local maxLevel = RelicHelper.getMaxLevel()
	local required = RelicHelper.getXpRequiredForNextLevel(level)
	return level < maxLevel and required ~= nil and xp >= required
end

function RelicHelper.tryLevelUpRelic(player: Player, relicId: number): RelicProgressEntry?
	if not RunService:IsServer() then
		return nil
	end
	local id = normalizeRelicId(relicId)
	if id == nil or not RelicHelper.getRelic(id) then
		return nil
	end

	local entry = DataManager.getRelicProgressEntry(player, id)
	if not entry then
		return nil
	end

	if not RelicHelper.canRelicLevelUp(entry.level, entry.xp) then
		return nil
	end

	local required = RelicHelper.getXpRequiredForNextLevel(entry.level)
	if not required then
		return nil
	end

	entry.level += 1
	entry.xp -= required

	local maxLevel = RelicHelper.getMaxLevel()
	if entry.level >= maxLevel then
		entry.level = maxLevel
		entry.xp = 0
	end

	if not DataManager.setRelicProgressEntry(player, id, entry) then
		return nil
	end
	return entry
end

local function getPoolIds(pool: SummonPool): { number }
	local allowedGrades = if pool == "Normal" then NORMAL_GRADES else SPECIAL_GRADES
	local ids: { number } = {}
	for _, relicId in RelicHelper.getRelicIds() do
		local relic = RelicHelper.getRelic(relicId)
		if relic and allowedGrades[relic.grade] then
			table.insert(ids, relicId)
		end
	end
	table.sort(ids)
	return ids
end

local function rollRelics(pool: SummonPool, count: number): { SummonRelicResult }
	local poolIds = getPoolIds(pool)
	if #poolIds == 0 then
		warn("[RelicHelper] 풀에 유물 없음:", pool)
		return {}
	end

	local results: { SummonRelicResult } = {}
	for _ = 1, count do
		local pick = poolIds[math.random(1, #poolIds)]
		local relic = RelicHelper.getRelic(pick)
		if relic then
			table.insert(results, {
				id = relic.id,
				name = relic.name,
				grade = relic.grade,
			})
		end
	end
	return results
end

local function ensureSummonRemote(): RemoteFunction
	if summonRemote then
		return summonRemote
	end

	local existing = ReplicatedStorage:FindFirstChild(SUMMON_REMOTE_NAME)
	local remote = if existing and existing:IsA("RemoteFunction")
		then existing
		else Instance.new("RemoteFunction")
	remote.Name = SUMMON_REMOTE_NAME
	remote.Parent = ReplicatedStorage
	summonRemote = remote
	return remote
end

local function ensureProgressRemote(): RemoteFunction
	if progressRemote then
		return progressRemote
	end

	local existing = ReplicatedStorage:FindFirstChild(PROGRESS_REMOTE_NAME)
	local remote = if existing and existing:IsA("RemoteFunction")
		then existing
		else Instance.new("RemoteFunction")
	remote.Name = PROGRESS_REMOTE_NAME
	remote.Parent = ReplicatedStorage
	progressRemote = remote
	return remote
end

local function ensureUpgradeRemote(): RemoteFunction
	if upgradeRemote then
		return upgradeRemote
	end

	local existing = ReplicatedStorage:FindFirstChild(UPGRADE_REMOTE_NAME)
	local remote = if existing and existing:IsA("RemoteFunction")
		then existing
		else Instance.new("RemoteFunction")
	remote.Name = UPGRADE_REMOTE_NAME
	remote.Parent = ReplicatedStorage
	upgradeRemote = remote
	return remote
end

--[[
	RemoteFunction 직렬화 시 비연속 number key(101, 201 등)가 string key("101")로
	바뀌는 경우가 있어, 클라이언트 조회 전 number key로 정규화한다.
]]
local function normalizeRelicProgressFromRemote(raw: any): RelicProgress
	local out: RelicProgress = {}
	if typeof(raw) ~= "table" then
		return out
	end

	for key, entryRaw in raw do
		local relicId = if typeof(key) == "number" then key else tonumber(key)
		if typeof(relicId) ~= "number" or relicId ~= relicId then
			continue
		end
		relicId = math.floor(relicId)
		if relicId < 1 then
			continue
		end
		if typeof(entryRaw) ~= "table" then
			continue
		end

		local level = if typeof(entryRaw.level) == "number" and entryRaw.level == entryRaw.level
			then math.floor(entryRaw.level)
			else nil
		local xp = if typeof(entryRaw.xp) == "number" and entryRaw.xp == entryRaw.xp
			then math.floor(entryRaw.xp)
			else nil
		if level == nil or xp == nil then
			continue
		end

		out[relicId] = {
			level = math.max(0, level),
			xp = math.max(0, xp),
		}
	end

	return out
end

function RelicHelper.hasUpgradeableRelics(progress: RelicProgress?): boolean
	local data = progress
	if data == nil then
		if RunService:IsServer() then
			return false
		end
		data = RelicHelper.fetchRelicProgress()
	end

	for _, entry in data do
		if RelicHelper.canRelicLevelUp(entry.level, entry.xp) then
			return true
		end
	end
	return false
end

local function normalizeRelicProgressEntryFromRemote(raw: any): RelicProgressEntry?
	if typeof(raw) ~= "table" then
		return nil
	end
	local level = if typeof(raw.level) == "number" and raw.level == raw.level then math.floor(raw.level) else nil
	local xp = if typeof(raw.xp) == "number" and raw.xp == raw.xp then math.floor(raw.xp) else nil
	if level == nil or xp == nil then
		return nil
	end
	return {
		level = math.max(0, level),
		xp = math.max(0, xp),
	}
end

function RelicHelper.requestLevelUp(relicId: number): RelicProgressEntry?
	if RunService:IsServer() then
		return nil
	end
	local id = normalizeRelicId(relicId)
	if id == nil then
		return nil
	end

	local remote = ReplicatedStorage:FindFirstChild(UPGRADE_REMOTE_NAME)
	if not (remote and remote:IsA("RemoteFunction")) then
		remote = ReplicatedStorage:WaitForChild(UPGRADE_REMOTE_NAME, 5)
	end
	if not (remote and remote:IsA("RemoteFunction")) then
		warn("[RelicHelper] UpgradeRelic RemoteFunction 없음")
		return nil
	end

	local ok, result = pcall(function()
		return (remote :: RemoteFunction):InvokeServer(id)
	end)
	if not ok then
		warn("[RelicHelper] UpgradeRelic 실패:", result)
		return nil
	end
	return normalizeRelicProgressEntryFromRemote(result)
end

function RelicHelper.fetchRelicProgress(): RelicProgress
	if RunService:IsServer() then
		return {}
	end
	local remote = ReplicatedStorage:FindFirstChild(PROGRESS_REMOTE_NAME)
	if not (remote and remote:IsA("RemoteFunction")) then
		remote = ReplicatedStorage:WaitForChild(PROGRESS_REMOTE_NAME, 5)
	end
	if not (remote and remote:IsA("RemoteFunction")) then
		warn("[RelicHelper] GetRelicProgress RemoteFunction 없음")
		return {}
	end
	local ok, result = pcall(function()
		return (remote :: RemoteFunction):InvokeServer()
	end)
	if not ok or typeof(result) ~= "table" then
		warn("[RelicHelper] GetRelicProgress 실패:", result)
		return {}
	end
	return normalizeRelicProgressFromRemote(result)
end

function RelicHelper.init()
	if initialized then
		return
	end
	initialized = true

	getRuntime()

	if not RunService:IsServer() then
		print("[RelicHelper] 클라이언트 초기화 완료")
		return
	end

	local remote = ensureSummonRemote()
	remote.OnServerInvoke = function(player: Player, poolRaw: any, countRaw: any)
		if not DataManager.waitUntilLoaded(player) then
			return {}
		end

		local pool = normalizePool(poolRaw)
		local count = normalizeCount(countRaw)
		if not pool or not count then
			warn("[RelicHelper] 잘못된 요청:", player.Name, poolRaw, countRaw)
			return {}
		end

		local cost = RelicHelper.getSummonCost(pool, count)
		if not cost then
			warn("[RelicHelper] 소환 비용 없음:", pool, count)
			return {}
		end

		local keyItemType = SUMMON_KEY_ITEM_TYPE[pool]
		local usedKey = keyItemType ~= nil and DataManager.consumeItem(player, keyItemType, count)
		if not usedKey then
			if not DataManager.spendCurrency(player, cost.currencyType, cost.amount) then
				return {}
			end
		end

		local results = rollRelics(pool, count)
		if #results > 0 then
			AchievementHelper.incrementByType(player, "RelicSummon", { amount = #results })
			for _, result in results do
				RelicHelper.addRelicXp(player, result.id, 1)
				AchievementHelper.incrementByType(player, "RelicGradeCollect", {
					relicGrade = result.grade :: Types.RelicGrade,
				})
			end
		end

		return results
	end

	local progressRf = ensureProgressRemote()
	progressRf.OnServerInvoke = function(player: Player)
		if not DataManager.waitUntilLoaded(player) then
			return {}
		end
		return DataManager.getRelicProgress(player) or {}
	end

	local upgradeRf = ensureUpgradeRemote()
	upgradeRf.OnServerInvoke = function(player: Player, relicIdRaw: any)
		if not DataManager.waitUntilLoaded(player) then
			return nil
		end
		local relicId = normalizeRelicId(relicIdRaw)
		if relicId == nil then
			warn("[RelicHelper] UpgradeRelic 잘못된 relicId:", player.Name, relicIdRaw)
			return nil
		end
		local entry = RelicHelper.tryLevelUpRelic(player, relicId)
		if not entry then
			return nil
		end
		return entry
	end

	print("[RelicHelper] 초기화 완료")
end

return RelicHelper
