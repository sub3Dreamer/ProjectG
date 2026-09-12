local Utils = {}

function Utils.waitForChild(parent: Instance, childName: string, timeout: number?): Instance?
	return parent:WaitForChild(childName, timeout or 10)
end

function Utils.safeCall(func: (...any) -> ...any, ...: any): (boolean, any)
	local success, result = pcall(func, ...)
	if not success then
		warn("[Utils] 에러:", result)
	end
	return success, result
end

return Utils
