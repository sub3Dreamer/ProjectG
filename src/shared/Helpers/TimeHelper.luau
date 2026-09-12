--[[
	TimeHelper (shared)

	UTC 시간 유틸:
	- datatable DateString ("YYYY-MM-DD") ↔ Unix timestamp
	- 일일 갱신/출석용 UTC day start 비교
]]

local TimeHelper = {}

TimeHelper.UTC_DATE_FORMAT = "%Y-%m-%d"
TimeHelper.DailyResetUtcHour = 0

local SECONDS_PER_DAY = 86400

local function utcTimestamp(year: number, month: number, day: number, hour: number, min: number, sec: number): number
	return os.time({
		year = year,
		month = month,
		day = day,
		hour = hour,
		min = min,
		sec = sec,
	}) + os.difftime(os.time(), os.time(os.date("!*t")))
end

function TimeHelper.now(): number
	return os.time()
end

function TimeHelper.unixToDateString(unix: number): string
	return os.date("!" .. TimeHelper.UTC_DATE_FORMAT, unix)
end

function TimeHelper.dateStringToUnix(dateStr: string): number?
	local y, m, d = dateStr:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not y then
		return nil
	end
	local year = tonumber(y)
	local month = tonumber(m)
	local day = tonumber(d)
	if not year or not month or not day then
		return nil
	end
	return utcTimestamp(year, month, day, 0, 0, 0)
end

function TimeHelper.dateStringToDayEndUnix(dateStr: string): number?
	local dayStart = TimeHelper.dateStringToUnix(dateStr)
	if not dayStart then
		return nil
	end
	return dayStart + SECONDS_PER_DAY - 1
end

function TimeHelper.getUtcDayStartTime(now: number?): number
	local ts = now or os.time()
	local utc = os.date("!*t", ts)
	local secondsIntoDay = utc.hour * 3600 + utc.min * 60 + utc.sec
	local dayStart = ts - secondsIntoDay
	local resetOffset = TimeHelper.DailyResetUtcHour * 3600
	if secondsIntoDay < resetOffset then
		return dayStart - SECONDS_PER_DAY + resetOffset
	end
	return dayStart + resetOffset
end

function TimeHelper.isSameUtcDay(a: number, b: number): boolean
	return TimeHelper.getUtcDayStartTime(a) == TimeHelper.getUtcDayStartTime(b)
end

function TimeHelper.getSecondsUntilDailyReset(): number
	local resetHour = TimeHelper.DailyResetUtcHour
	local utc = os.date("!*t")
	local currentSeconds = utc.hour * 3600 + utc.min * 60 + utc.sec
	local targetSeconds = resetHour * 3600

	local remaining: number
	if currentSeconds < targetSeconds then
		remaining = targetSeconds - currentSeconds
	else
		remaining = SECONDS_PER_DAY - currentSeconds + targetSeconds
	end

	if remaining == SECONDS_PER_DAY then
		remaining = 0
	end

	return remaining
end

return TimeHelper
