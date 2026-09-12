local M = {}

local Players = game:GetService("Players")
local XpHandler = require(script.Parent.Parent.Parent.XpHandler)

-- EnemySetup.EnemyNpcAttributeName 과 동일 (EnemySetup을 require하면 순환 참조)
local ENEMY_NPC_ATTR = "EnemyNpc"

--- 구(중심·반경)와 타겟 모델의 BasePart 하나라도 겹치면 true. 거대 캐릭터는 머리 한 점만 보면 놓친다.
local function modelIntersectsSphereAroundPoint(targetModel: Model, sphereCenter: Vector3, radius: number): boolean
	for _, inst in targetModel:GetDescendants() do
		if inst:IsA("BasePart") then
			local part = inst :: BasePart
			local partExtent = part.Size.Magnitude * 0.5
			if (part.Position - sphereCenter).Magnitude <= radius + partExtent then
				return true
			end
		end
	end
	return false
end

function M.bind(npc: Model)
--Fully made by 
--animations are made with :lerp()
--you can convert the model to use it in script builder
local torso = npc.Torso
local head = npc.Head
local rightarm = npc["Right Arm"]
local npchumanoid = npc.Humanoid

	local ak47Inst = npc:FindFirstChild("AK-47")
	local ak47Muzzle: BasePart = rightarm
	local ak47ShootSound: Sound? = nil
	if ak47Inst then
		if ak47Inst:IsA("BasePart") then
			ak47Muzzle = ak47Inst
		elseif ak47Inst:IsA("Model") then
			local pp = ak47Inst.PrimaryPart
			if pp and pp:IsA("BasePart") then
				ak47Muzzle = pp
			else
				local p = ak47Inst:FindFirstChildWhichIsA("BasePart", true)
				if p then
					ak47Muzzle = p
				end
			end
		end
		local s = ak47Inst:FindFirstChild("shoot", true)
		if s and s:IsA("Sound") then
			ak47ShootSound = s
		end
	end

	local akweldGunPart: BasePart
	if ak47Inst and ak47Inst:IsA("BasePart") then
		akweldGunPart = ak47Inst
	elseif ak47Inst and ak47Inst:IsA("Model") and ak47Muzzle ~= rightarm then
		akweldGunPart = ak47Muzzle
	else
		local holder = Instance.new("Part")
		holder.Name = "GunWeldProxy"
		holder.Size = Vector3.new(0.2, 0.2, 2)
		holder.Transparency = 1
		holder.CanCollide = false
		holder.CanQuery = false
		holder.Massless = true
		holder.Parent = npc
		holder.CFrame = rightarm.CFrame * CFrame.new(0, 0, -1.2)
		akweldGunPart = holder
	end

--Motor6D's
local neck = torso.Neck
neck.C1 = CFrame.new(0,0,0)
local leftshoulder = torso["Left Shoulder"]
leftshoulder.C1 = CFrame.new(0,0,0)
local rightshoulder = torso["Right Shoulder"]
rightshoulder.C1 = CFrame.new(0,0,0)
local lefthip = torso["Left Hip"]
lefthip.C1 = CFrame.new(0,0,0)
local righthip = torso["Right Hip"]
righthip.C1 = CFrame.new(0,0,0)
local root = npc.HumanoidRootPart.RootJoint
root.C1 = CFrame.new(0,0,0)
--
local sight = 30

local aggroVisual = Instance.new("Part")
aggroVisual.Name = "AggroRangeVisual"
aggroVisual.Shape = Enum.PartType.Ball
aggroVisual.Size = Vector3.new(sight * 2, sight * 2, sight * 2)
aggroVisual.Massless = true
aggroVisual.CanCollide = false
aggroVisual.CanQuery = false
aggroVisual.CastShadow = false
aggroVisual.Material = Enum.Material.ForceField
aggroVisual.Color = Color3.fromRGB(255, 25, 35)
aggroVisual.Transparency = 0.68
aggroVisual.Parent = npc
aggroVisual.CFrame = head.CFrame
local aggroWeld = Instance.new("WeldConstraint")
aggroWeld.Part0 = head
aggroWeld.Part1 = aggroVisual
aggroWeld.Parent = aggroVisual

local walking = false
local shooting = false
local canshoot = true
local akweld = Instance.new("Weld")
akweld.Part0 = rightarm
akweld.Part1 = akweldGunPart
akweld.Parent = akweldGunPart
local function walkanim(walkspeed)
	if walkspeed > 5 then
		walking = true
	else
		walking = false
	end
end
npchumanoid.Running:connect(walkanim)
local function randomwalk()
	while wait(math.random(3,6)) do
		if not shooting and not walking then
			npchumanoid.WalkSpeed = 16
			local function createwalkpart()
				local walkpart = Instance.new("Part", npc)
				walkpart.Size = Vector3.new(1,1,1)
				walkpart.Anchored = true
				walkpart.Material = "Neon"
				walkpart.Transparency = 1
				walkpart.BrickColor = BrickColor.new("Maroon")
				walkpart.CFrame = torso.CFrame * CFrame.new(math.random(-60,60),math.random(-30,30),math.random(-60,60))
				local path = game:GetService("PathfindingService"):FindPathAsync(torso.Position, walkpart.Position)
				local waypoints = path:GetWaypoints()
				if path.Status == Enum.PathStatus.Success then
					for i,v in pairs(waypoints) do
						local pospart = Instance.new("Part", npc)
						pospart.Size = Vector3.new(1,1,1)
						pospart.Anchored = true
						pospart.Material = "Neon"
						pospart.Transparency = 1
						pospart.Position = v.Position
						pospart.Name = "pospart"
						pospart.CanCollide = false
					end
					for i,v in pairs(waypoints) do
						npchumanoid:MoveTo(v.Position)
						local allow = 0
						while (torso.Position - v.Position).magnitude > 4 and allow < 35 do
							allow = allow + 1
							wait()
						end
						if v.Action == Enum.PathWaypointAction.Jump then
							npchumanoid.Jump = true
						end
					end
					for i,v in pairs(npc:GetChildren()) do
						if v.Name == "pospart" then
							v:destroy()
						end
					end
				else
					createwalkpart()
					wait()
				end
				walkpart:destroy()
			end
			createwalkpart()
		end
	end
end
local function checkandshoot()
	while wait() do
		for i,v in pairs(workspace:GetChildren()) do
			if v.ClassName == "Model" and v.Name ~= "collazio" and v:GetAttribute(ENEMY_NPC_ATTR) ~= true then
				local victimhumanoid = v:FindFirstChildOfClass("Humanoid")
				if victimhumanoid and v.Name ~= npc.Name and v:IsA("Model") then
					local victimModel = v :: Model
					if modelIntersectsSphereAroundPoint(victimModel, head.Position, sight) then
						if not shooting and victimhumanoid.Health > 0 and canshoot then
							shooting = true
							walking = false
							local doesshoot = 0
							local walk = 0
							npchumanoid.WalkSpeed = 0
							while shooting
								and modelIntersectsSphereAroundPoint(victimModel, head.Position, sight)
								and victimhumanoid.Health > 0
								and canshoot
							do
								doesshoot = doesshoot + 1
								walk = walk + 1
								if npchumanoid.PlatformStand == false then
									local aim = victimModel:GetPivot().Position
									npc.HumanoidRootPart.CFrame = CFrame.new(
										npc.HumanoidRootPart.Position,
										Vector3.new(aim.X, npc.HumanoidRootPart.Position.Y, aim.Z)
									)
								end
								if walk == 100 and not walking then
									local function createwalkpart()
										local walkpart = Instance.new("Part", npc)
										walkpart.Size = Vector3.new(1,1,1)
										walkpart.Anchored = true
										walkpart.Material = "Neon"
										walkpart.Transparency = 1
										walkpart.BrickColor = BrickColor.new("Maroon")
										walkpart.CFrame = torso.CFrame * CFrame.new(-math.random(20,60),math.random(-40,40),math.random(-10,10))
										local path = game:GetService("PathfindingService"):FindPathAsync(torso.Position, walkpart.Position)
										local waypoints = path:GetWaypoints()
										if path.Status == Enum.PathStatus.Success then
											shooting = false
											canshoot = false
											npchumanoid.WalkSpeed = 20
											for i,v in pairs(waypoints) do
												local pospart = Instance.new("Part", npc)
												pospart.Size = Vector3.new(1,1,1)
												pospart.Anchored = true
												pospart.Material = "Neon"
												pospart.Transparency = 1
												pospart.Position = v.Position
												pospart.Name = "pospart"
												pospart.CanCollide = false
											end
											for i,v in pairs(waypoints) do
												npchumanoid:MoveTo(v.Position)
												local allow = 0
												while (torso.Position - v.Position).magnitude > 4 and allow < 35 do
													allow = allow + 1
													wait()
												end
												if v.Action == Enum.PathWaypointAction.Jump then
													npchumanoid.Jump = true
												end
											end
											canshoot = true
											npchumanoid.WalkSpeed = 16
											for i,v in pairs(npc:GetChildren()) do
												if v.Name == "pospart" then
													v:destroy()
												end
											end
										else
											createwalkpart()
											wait()
										end
										walkpart:destroy()
									end
									createwalkpart()
								end
								if doesshoot == 5 then
									doesshoot = 0
									if ak47ShootSound then
										ak47ShootSound:Play()
									end
									local bullet = Instance.new("Part", npc)
									bullet.Size = Vector3.new(0.3,0.3,3)
									bullet.Material = "Neon"
									bullet.CFrame = ak47Muzzle.CFrame * CFrame.new(0, 0, -4)
									bullet.CanCollide = false
									local velocity = Instance.new("BodyVelocity", bullet)
									velocity.MaxForce = Vector3.new(math.huge,math.huge,math.huge)
									bullet.CFrame = CFrame.new(bullet.Position, victimModel:GetPivot().Position)
									velocity.Velocity = bullet.CFrame.lookVector * 500 + Vector3.new(math.random(-25,25),math.random(-25,25),0)
									local pointlight = Instance.new("PointLight", ak47Muzzle)
									game.Debris:AddItem(pointlight,0.1)
									local function damage(part)
										if part.Parent.ClassName ~= "Accessory" and part.Parent.Parent.ClassName ~= "Accessory" and part.ClassName ~= "Accessory" and part.Parent.Name ~= npc.Name and part.CanCollide == true then
											bullet:Destroy()
											local victimhumanoid = part.Parent:FindFirstChildOfClass("Humanoid")
											if victimhumanoid then
												local character = victimhumanoid.Parent
												if character and character:IsA("Model") and character:GetAttribute(ENEMY_NPC_ATTR) == true then
													return
												end
												local plr = character and character:IsA("Model") and Players:GetPlayerFromCharacter(character :: Model)
												if plr then
													XpHandler.removeXpFromGauge(plr, 1)
												else
													victimhumanoid:TakeDamage(math.random(10, 50))
												end
											end
										end
									end
									game.Debris:AddItem(bullet, 5)
									bullet.Touched:Connect(damage)
								end
								wait()
							end
							walking = false
							shooting = false
						end
					end
				end
			end
		end
	end
end
local function run()
	while wait() do
		local hpnow = npchumanoid.Health
		wait()
		if npchumanoid.Health < hpnow then
			local dorun = math.random(1,1)
			if dorun == 1 and not walking then
				local function createwalkpart()
					local walkpart = Instance.new("Part", npc)
					walkpart.Size = Vector3.new(1,1,1)
					walkpart.Anchored = true
					walkpart.Material = "Neon"
					walkpart.Transparency = 1
					walkpart.BrickColor = BrickColor.new("Maroon")
					walkpart.CFrame = torso.CFrame * CFrame.new(math.random(20,60),math.random(-20,20),math.random(-60,60))
					local path = game:GetService("PathfindingService"):FindPathAsync(torso.Position, walkpart.Position)
					local waypoints = path:GetWaypoints()
					if path.Status == Enum.PathStatus.Success then
						shooting = false
						canshoot = false
						walking = true
						npchumanoid.WalkSpeed = 20
						for i,v in pairs(waypoints) do
							local pospart = Instance.new("Part", npc)
							pospart.Size = Vector3.new(1,1,1)
							pospart.Anchored = true
							pospart.Material = "Neon"
							pospart.Transparency = 1
							pospart.Position = v.Position
							pospart.Name = "pospart"
							pospart.CanCollide = false
						end
						for i,v in pairs(waypoints) do
							npchumanoid:MoveTo(v.Position)
							local allow = 0
							while (torso.Position - v.Position).magnitude > 4 and allow < 35 do
								allow = allow + 1
								wait()
							end
							if v.Action == Enum.PathWaypointAction.Jump then
								npchumanoid.Jump = true
							end
						end
						shooting = false
						canshoot = true
						walking = false
						npchumanoid.WalkSpeed = 16
						for i,v in pairs(npc:GetChildren()) do
							if v.Name == "pospart" then
								v:destroy()
							end
						end
					else
						createwalkpart()
						wait()
					end
					walkpart:destroy()
				end
				createwalkpart()
			end
		end
	end
end
task.spawn(run)
task.spawn(checkandshoot)
task.spawn(randomwalk)
-- 이 루프는 무한 yield 하므로 반드시 별도 스레드에서 돌려야 함.
-- 그렇지 않으면 EnemySpawnLocations 등 호출자 코루틴이 여기서 영구 정지한다.
task.spawn(function()
	while wait() do --check animations and other things
	if not walking and not shooting then
		for i = 0.2,0.8 , 0.09 do
			if not walking and not shooting then
				akweld.C0 = akweld.C0:lerp(CFrame.new(-0.583096504, -1.87343168, 0.0918724537, 0.808914721, -0.582031429, 0.0830438882, -0.166903317, -0.0918986499, 0.981681228, -0.56373775, -0.807956576, -0.171481162),i)
				rightshoulder.C0 = rightshoulder.C0:lerp(CFrame.new(1.32261992, 0.220639229, -0.279059082, 0.766044497, 0.604022682, -0.219846413, -0.492403805, 0.331587851, -0.804728508, -0.413175881, 0.724711061, 0.551434159),i)
				leftshoulder.C0 = leftshoulder.C0:lerp(CFrame.new(-1.16202736, -0.00836706161, -0.880517244, 0.939692557, -0.342020094, -2.98023224e-08, 0.171009958, 0.46984598, -0.866025567, 0.296198159, 0.813797832, 0.499999642),i)
				lefthip.C0 = lefthip.C0:lerp(CFrame.new(-0.599619389, -1.99128425, 0, 0.996194661, 0.087155968, 0, -0.087155968, 0.996194661, 0, 0, 0, 1),i)
				righthip.C0 = righthip.C0:lerp(CFrame.new(0.599619389, -1.99128449, 0, 0.996194661, -0.087155968, 0, 0.087155968, 0.996194661, 0, 0, 0, 1),i)
				root.C0 = root.C0:lerp(CFrame.new(0,0,0),i)
				neck.C0 = neck.C0:lerp(CFrame.new(0,1.5,0),i)
				wait()
			end
		end
	end
	if walking then --this is the walking animation
		for i = 0.2,0.8 , 0.09 do
			if walking then
				akweld.C0 = akweld.C0:lerp(CFrame.new(-0.583096504, -1.87343168, 0.0918724537, 0.808914721, -0.582031429, 0.0830438882, -0.166903317, -0.0918986499, 0.981681228, -0.56373775, -0.807956576, -0.171481162),i)
				rightshoulder.C0 = rightshoulder.C0:lerp(CFrame.new(1.32261992, 0.220639229, -0.279059082, 0.766044497, 0.604022682, -0.219846413, -0.492403805, 0.331587851, -0.804728508, -0.413175881, 0.724711061, 0.551434159),i)
				leftshoulder.C0 = leftshoulder.C0:lerp(CFrame.new(-1.16202736, -0.00836706161, -0.880517244, 0.939692557, -0.342020094, -2.98023224e-08, 0.171009958, 0.46984598, -0.866025567, 0.296198159, 0.813797832, 0.499999642),i)
				lefthip.C0 = lefthip.C0:lerp(CFrame.new(-0.527039051, -1.78302765, 0.642787695, 0.999390841, 0.026734557, 0.0224329531, -0.0348994918, 0.765577614, 0.642395973, 0, -0.642787635, 0.766044438),i)
				righthip.C0 = righthip.C0:lerp(CFrame.new(0.522737741, -1.65984559, -0.766044617, 0.999390841, -0.0224329531, 0.0267345682, 0.0348994918, 0.642395794, -0.765577734, 0, 0.766044497, 0.642787457),i)
				root.C0 = root.C0:lerp(CFrame.new(0, 0, 0, 0.996194661, 6.98491931e-09, -0.0871561021, 0.00759615982, 0.996194661, 0.0868242308, 0.0868244469, -0.087155886, 0.992403805),i)
				neck.C0 = neck.C0:lerp(CFrame.new(2.38418579e-07, 1.49809694, 0.0435779095, 0.996194661, 6.38283382e-09, 0.0871560946, 0.00759615889, 0.996194601, -0.0868242308, -0.0868244469, 0.087155886, 0.992403746),i)
				wait()
			end
		end
		head.footstep:Play()
		for i = 0.2,0.8 , 0.09 do
			if walking then
				akweld.C0 = akweld.C0:lerp(CFrame.new(-0.583096504, -1.87343168, 0.0918724537, 0.808914721, -0.582031429, 0.0830438882, -0.166903317, -0.0918986499, 0.981681228, -0.56373775, -0.807956576, -0.171481162),i)
				rightshoulder.C0 = rightshoulder.C0:lerp(CFrame.new(1.32261992, 0.220639229, -0.279059082, 0.766044497, 0.604022682, -0.219846413, -0.492403805, 0.331587851, -0.804728508, -0.413175881, 0.724711061, 0.551434159),i)
				leftshoulder.C0 = leftshoulder.C0:lerp(CFrame.new(-1.16202736, -0.00836706161, -0.880517244, 0.939692557, -0.342020094, -2.98023224e-08, 0.171009958, 0.46984598, -0.866025567, 0.296198159, 0.813797832, 0.499999642),i)
				lefthip.C0 = lefthip.C0:lerp(CFrame.new(-0.520322084, -1.59067655, -0.819151878, 0.999390841, 0.0200175196, -0.028587997, -0.0348994918, 0.573226929, -0.818652987, 0, 0.819151998, 0.57357645),i)
				righthip.C0 = righthip.C0:lerp(CFrame.new(0.528892756, -1.83610249, 0.573575974, 0.999390841, -0.0285879895, -0.020017527, 0.0348994955, 0.818652987, 0.57322675, -7.4505806e-09, -0.573576212, 0.819152057),i)
				root.C0 = root.C0:lerp(CFrame.new(0, 0, 0, 0.996194661, -1.44354999e-08, 0.0871558934, -0.00759615237, 0.996194661, 0.0868244395, -0.0868242383, -0.0871560946, 0.992403805),i)
				neck.C0 = neck.C0:lerp(CFrame.new(0, 1.49809742, 0.0435781479, 0.996194601, -1.27129169e-08, -0.0871559009, -0.0075961519, 0.996194661, -0.0868244097, 0.0868242458, 0.0871560723, 0.992403746),i)
				wait()
			end
		end
		head.footstep:Play()
	end
	if shooting then --this is the shooting animation
		for i = 0.2,0.8 , 0.45 do
			if shooting then
				akweld.C0 = akweld.C0:lerp(CFrame.new(-0.109231472, -2.24730468, -0.300003052, 0.984807491, 1.94707184e-07, 0.173647866, -0.173648044, -2.68220873e-07, 0.984807491, 3.67846468e-07, -0.999999821, -8.00420992e-08),i)
				root.C0 = root.C0:lerp(CFrame.new(0, 0, 0, 0.173648223, 0, -0.98480773, 0, 1, 0, 0.98480773, 0, 0.173648223),i)
				rightshoulder.C0 = rightshoulder.C0:lerp(CFrame.new(1.21384871, 0.500000477, -0.879925251, 0.342019856, 0.939692438, -1.49501886e-08, 1.94707184e-07, -2.68220873e-07, -0.999999821, -0.939692438, 0.342020035, -3.76157232e-07),i)
				leftshoulder.C0 = leftshoulder.C0:lerp(CFrame.new(-1.59201181, 0.470158577, -0.794548988, 0.271118939, 0.181368172, 0.945304275, 0.902039766, -0.390578717, -0.18377316, 0.335885108, 0.902526498, -0.269494623),i)
				lefthip.C0 = lefthip.C0:lerp(CFrame.new(-0.681244373, -2.07163191, 0, 0.98480773, 0.173648283, 0, -0.173648283, 0.98480767, 0, 0, -1.86264515e-09, 0.99999994),i)
				righthip.C0 = righthip.C0:lerp(CFrame.new(0.681244612, -2.07163191, -4.76837158e-07, 0.98480773, -0.173648283, 0, 0.173648283, 0.98480767, 0, 0, 1.86264515e-09, 0.99999994),i)
				neck.C0 = neck.C0:lerp(CFrame.new(0.0296957493, 1.49240398, -0.0815882683, 0.336824059, 0.059391167, 0.939692557, -0.173648164, 0.98480773, -7.4505806e-09, -0.925416589, -0.163175896, 0.342020094),i)
				wait()
			end
		end
		for i = 0.2,0.8 , 0.45 do
			if shooting then
				akweld.C0 = akweld.C0:lerp(CFrame.new(-0.109231472, -2.24730468, -0.300003052, 0.984807491, 1.94707184e-07, 0.173647866, -0.173648044, -2.68220873e-07, 0.984807491, 3.67846468e-07, -0.999999821, -8.00420992e-08),i)
				root.C0 = root.C0:lerp(CFrame.new(0, 0, 0, 0.173648223, 0, -0.98480773, 0, 1, 0, 0.98480773, 0, 0.173648223),i)
				rightshoulder.C0 = rightshoulder.C0:lerp(CFrame.new(1.60777056, 0.499999523, -0.81046629, 0.342019439, 0.939691842, 1.55550936e-07, 4.10554577e-08, -3.93739697e-07, -0.999999464, -0.939691901, 0.342019975, -4.77612389e-07),i)
				leftshoulder.C0 = leftshoulder.C0:lerp(CFrame.new(-1.10000956, 0.482372284, -0.926761627, 0.27112025, 0.263066441, 0.925899446, 0.902039289, -0.405109912, -0.149033815, 0.335885197, 0.875603914, -0.347129732),i)
				lefthip.C0 = lefthip.C0:lerp(CFrame.new(-0.681244373, -2.07163191, 0, 0.98480773, 0.173648283, 0, -0.173648283, 0.98480767, 0, 0, -1.86264515e-09, 0.99999994),i)
				righthip.C0 = righthip.C0:lerp(CFrame.new(0.681244612, -2.07163191, -4.76837158e-07, 0.98480773, -0.173648283, 0, 0.173648283, 0.98480767, 0, 0, 1.86264515e-09, 0.99999994),i)
				neck.C0 = neck.C0:lerp(CFrame.new(0.121206045, 1.4753027, -0.0450725555, 0.336823881, 0.221664757, 0.915103495, -0.173648164, 0.969846308, -0.171010077, -0.925416648, -0.101305753, 0.365159094),i)
				wait()
			end
		end
	end
end
end)
end

return M
