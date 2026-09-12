local BlackSoldier = {}

local EnemyOverheadHpBar = require(script.Parent.Parent.EnemyOverheadHpBar)
local NPCAI = require(script.Parent.NPCAI)

function BlackSoldier.setup(model: Model)
	EnemyOverheadHpBar.attach(model)
	NPCAI.bind(model)
end

return BlackSoldier
