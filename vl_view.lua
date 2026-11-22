-- Villagers: every machine draws the villagers as the game's own player characters (data/prefab/player/*.xml,
-- spawned per machine like the game's playerbody.lua; seen working in the probe, Frustrum 2026-11-14: 54-65
-- entities each with an animator, 39 clips, no walk clip), posed from shared.vl with the game's clips.
-- (no #version line: included by main.lua)

VlView = {list = {}, lastN = -1}

local VV = VlView
local LAYER = 32

local function spawnChar(char, pos)
	local path = "player/player_" .. (char or "sven_lagom") .. ".xml"
	local ok, ents = pcall(Spawn, path, Transform(pos))
	if not ok or type(ents) ~= "table" or #ents == 0 then
		ok, ents = pcall(Spawn, "player/player_sven_lagom.xml", Transform(pos))
		if not ok or type(ents) ~= "table" then return nil end
	end
	local c = {ents = ents, anim = 0, shapes = {}}
	for _, e in ipairs(ents) do
		local t = GetEntityType(e)
		if t == "animator" then c.anim = e
		elseif t == "shape" then
			c.shapes[#c.shapes + 1] = e
			SetShapeCollisionFilter(e, LAYER, 0)               -- (players, bullets and our rays pass through)
		end
	end
	return c
end

local function deleteChar(c)
	for _, e in ipairs(c.ents or {}) do if IsHandleValid(e) then Delete(e) end end
	if c.ext and IsHandleValid(c.ext) then Delete(c.ext) end
end

local function yawRot(fx, fz)
	local f = Vec(fx, 0, fz)
	if VecLength(f) < 0.01 then f = Vec(0, 0, -1) end
	-- a look rotation (its -z toward f), then the player model's 180 degree offset (as player_locomotion.lua)
	return QuatRotateQuat(QuatLookAt(Vec(0, 0, 0), f), QuatEuler(0, 180, 0))
end

function VlView.init() end

-- (the user, 2026-11-14: "when they're hurt (low health), blood should show")
function VlView.blood(pos, n, speed)
	ParticleReset()
	ParticleType("plain")
	ParticleColor(0.45, 0.02, 0.02, 0.25, 0.0, 0.0)
	ParticleRadius(0.03, 0.015)
	ParticleAlpha(1, 0.9)
	ParticleGravity(-10)
	ParticleDrag(0.05)
	ParticleCollide(1)
	ParticleSticky(1)
	for i = 1, n do
		local v = Vec((math.random() - 0.5) * speed, math.random() * speed * 0.6, (math.random() - 0.5) * speed)
		SpawnParticle(pos, v, 2.5 + math.random())
	end
end

-- seen from this machine's camera: a clear line to the point (our models and hitboxes don't count)
local function seenFromCamera(p)
	local cam = GetCameraTransform().pos
	local d = VecSub(p, cam)
	local L = VecLength(d)
	if L < 0.5 then return true end
	QueryCollisionMask(255 - 32 - 64)
	local hit = QueryRaycast(cam, VecScale(d, 1 / L), L - 0.35)
	return not hit
end

function VlView.tick(dt)
	local s = shared.vl
	if not s or not s.d then return end
	if s.n == VV.lastN then return end
	VV.lastN = s.n
	local seen = {}
	for _, e in ipairs(s.d) do
		seen[e.id] = true
		local c = VV.list[e.id]
		local target = Vec(e.x, e.y, e.z)
		if not c then
			c = spawnChar(e.char, target)
			if c then
				c.pos, c.fx, c.fz = VecCopy(target), e.fx, e.fz
				c.k = e.k
				VV.list[e.id] = c
			end
		end
		if c then
			c.target = target
			c.tfx, c.tfz = e.fx, e.fz
			c.post, c.spd, c.talk, c.e = e.post, e.spd or 0, e.talk, e
			c.name, c.hp = e.name, e.hp or 100
			if c.hitN == nil then c.hitN = e.hitN or 0 end
			if (e.hitN or 0) ~= c.hitN then
				c.hitN = e.hitN or 0
				if e.bx then VlView.blood(Vec(e.bx, e.by, e.bz), 18, 4) end
			end
		end
	end
	for id, c in pairs(VV.list) do
		if not seen[id] then deleteChar(c); VV.list[id] = nil end
	end
end

-- the extinguisher in the right hand, and its spray
local function extinguisher(c, on, aim, dt)
	if on and not (c.ext and IsHandleValid(c.ext)) then
		local ok, ents = pcall(Spawn, "<body><vox file='tool/extinguisher.vox' scale='0.5'/></body>", Transform(c.pos), true)
		if ok and type(ents) == "table" then
			for _, h in ipairs(ents) do
				if GetEntityType(h) == "body" then c.ext = h end
				if GetEntityType(h) == "shape" then SetShapeCollisionFilter(h, LAYER, 0) end
			end
		end
	elseif not on and c.ext then
		if IsHandleValid(c.ext) then Delete(c.ext) end
		c.ext = nil
	end
	if not (c.ext and c.anim ~= 0) then return end
	local okb, hand = pcall(GetBoneWorldTransform, c.anim, "hand_r")
	if not okb or not hand then hand = Transform(VecAdd(c.pos, Vec(0, 1.0, 0)), Quat()) end
	local dir = aim and VecNormalize(VecSub(aim, hand.pos)) or QuatRotateVec(yawRot(c.fx, c.fz), Vec(0, 0, 1))
	SetBodyTransform(c.ext, Transform(hand.pos, QuatLookAt(hand.pos, VecAdd(hand.pos, dir))))
	if aim then
		-- a thick white cloud from the nozzle to the fire, and the game's own extinguisher hiss
		ParticleReset()
		ParticleType("smoke")
		ParticleColor(0.96, 0.96, 0.98)
		ParticleRadius(0.1, 0.7)
		ParticleAlpha(0.9, 0)
		ParticleGravity(-0.4)
		ParticleDrag(0.25)
		ParticleCollide(1)
		-- (by time, not by frame: about 300 a second at any frame rate)
		c.sprayAcc = (c.sprayAcc or 0) + 300 * math.min(dt or 0.016, 0.05)
		local n = math.floor(c.sprayAcc)
		c.sprayAcc = c.sprayAcc - n
		for i = 1, n do
			local v = VecScale(VecAdd(dir, Vec((math.random() - 0.5) * 0.3, (math.random() - 0.5) * 0.22, (math.random() - 0.5) * 0.3)), 8 + math.random() * 3)
			SpawnParticle(VecAdd(hand.pos, VecScale(dir, 0.3)), v, 1.1)
		end
		if VV.sprayLoop == nil then
			local okl, h = pcall(LoadLoop, "snd/tools/extinguisher-loop.ogg")
			VV.sprayLoop = okl and h or false
		end
		if VV.sprayLoop then pcall(PlayLoop, VV.sprayLoop, hand.pos, 0.7) end
	end
end

local function pose(c, dt)
	local a = c.anim
	if a == 0 or not c.target then return end
	local post = c.post or "stand"
	-- smooth toward the host's state (it publishes 15 times a second)
	local rate = 10
	if post == "lie" or post == "sit" or post == "dead" then rate = 30 end
	local k = math.min(1, dt * rate)
	c.pos = VecLerp(c.pos, c.target, k)
	local yk = math.min(1, dt * 8)
	c.fx = c.fx + (c.tfx - c.fx) * yk
	c.fz = c.fz + (c.tfz - c.fz) * yk
	if post == "dead" or post == "rag" then
		if not c.ragdoll then
			c.ragdoll = true
			-- (limp: the body parts collide with the world - not with other villagers, hitboxes or players, whose mask
			--  leaves layer 32 out - else the ragdoll falls through the floor; mask 0 again when it stands up)
			for _, s in ipairs(c.shapes or {}) do if IsHandleValid(s) then SetShapeCollisionFilter(s, LAYER, 255 - LAYER - 64) end end
			pcall(MakeRagdoll, a)
		end
		-- (a car hit: the limp body flung with the car's speed, once per hit)
		if post == "rag" and c.e and c.e.ragN and c.ragN ~= c.e.ragN then
			c.ragN = c.e.ragN
			local v = Vec(c.e.rvx or 0, c.e.rvy or 0, c.e.rvz or 0)
			for _, h in ipairs(c.ents or {}) do
				if IsHandleValid(h) and GetEntityType(h) == "body" then pcall(SetBodyVelocity, h, v) end
			end
		end
		return
	elseif c.ragdoll then
		c.ragdoll = false
		pcall(UnRagdoll, a, 0.5)
		for _, s in ipairs(c.shapes or {}) do if IsHandleValid(s) then SetShapeCollisionFilter(s, LAYER, 0) end end
	end
	local rot = yawRot(c.fx, c.fz)
	local pos = VecCopy(c.pos)
	if post == "lie" then
		local h = Vec(c.e.hx or 0, 0, c.e.hz or 1)
		if VecLength(h) < 0.1 then h = Vec(0, 0, 1) end
		h = VecNormalize(h)
		-- on the back (the standing model turned -90 about x: head toward -z, face up), head toward the bed's head end;
		-- the root (feet) half a body short of the middle
		rot = QuatRotateQuat(QuatLookAt(Vec(0, 0, 0), h), QuatEuler(-90, 0, 0))
		pos = VecAdd(VecSub(pos, VecScale(h, 0.9)), Vec(0, 0.12, 0))
		SetAnimatorTransform(a, Transform(pos, rot))
		PlayAnimationLoop(a, "idle_1", 1)
	elseif post == "sit" then
		-- as the game seats a driver: the seat point minus the pelvis' bind offset (player_locomotion.lua)
		local at = Transform(pos, rot)
		local okp, pel = pcall(GetBoneBindPoseTransform, a, "pelvis")
		if okp and pel then at.pos = VecSub(pos, TransformToParentVec(at, pel.pos)) end
		SetAnimatorTransform(a, at)
		PlayAnimationFrame(a, "ik_pose_drive", 0, 1)
	elseif post == "kneel" then
		-- bandaging: crouched by the patient, the right hand working at their chest
		SetAnimatorTransform(a, Transform(pos, rot))
		PlayAnimationLoop(a, "crouch_idle", 1)
		PlayAnimationInstances(a)
		if c.e.tx then
			local t = GetTime()
			local tgt = Vec(c.e.tx + math.sin(t * 3.1) * 0.06, c.e.ty + math.sin(t * 4.7) * 0.05, c.e.tz + math.cos(t * 3.1) * 0.06)
			pcall(SetAnimatorTransformIK, a, "shoulder_r", "hand_r", Transform(tgt), 0.9, 0.5, false, true)
			pcall(SetAnimatorTransformIK, a, "shoulder_l", "hand_l", Transform(VecAdd(tgt, Vec(0.12, -0.05, 0.08))), 0.7, 0.5, false, true)
			if math.random() < dt * 0.8 then
				ParticleReset(); ParticleColor(0.95, 0.93, 0.88); ParticleRadius(0.02); ParticleGravity(-3)
				SpawnParticle(tgt, Vec(0, 0.3, 0), 0.6)
			end
		end
		return
	else
		-- (the user, 2026-11-21: "a simple one would be great") blinded by a flash-bang: hunched over, swaying and
		-- stumbling about on the spot, both hands at the eyes (IK after the clips, below)
		local blind = c.e.blind and post == "stand"
		if blind then
			local t = GetTime() + (c.k or 0) * 1.7
			local side = VecNormalize(Vec(-(c.fz or 1), 0, c.fx or 0))
			pos = VecAdd(pos, VecScale(side, math.sin(t * 1.3) * 0.09 + math.sin(t * 3.1) * 0.03))
			rot = QuatRotateQuat(rot, QuatEuler(math.sin(t * 2.2) * 4, math.sin(t * 1.7) * 22, math.sin(t * 1.3) * 6))
		end
		SetAnimatorTransform(a, Transform(pos, rot))
		PlayAnimationLoop(a, "idle_1", 1)
		-- shoved: a stagger (the landing clip, half weight)
		if c.e.stag then PlayAnimationLoop(a, "jump_land", 0.6) end
		if blind then
			BeginAnimationGroup(a, 0.45)
			PlayAnimationLoop(a, "crouch_idle", 1)
			EndAnimationGroup(a)
		end
		-- weak: bent over, half crouched (the user: "they should look weak")
		if (c.hp or 100) < 45 then
			BeginAnimationGroup(a, 0.5)
			PlayAnimationLoop(a, "crouch_idle", 1)
			EndAnimationGroup(a)
		end
		local spd = c.spd or 0
		if post == "walk" or post == "run" then
			-- no walk clip: the run clip, weighted down and slowed so the feet match the ground speed
			-- (the game: weight = speed / 7, clip speed 1.6 -> 7 m/s at weight 1)
			local w = post == "run" and math.max(0.5, math.min(1, spd / 7)) or math.max(0.3, math.min(0.6, spd / 3.2))
			local cs = 1.6 * spd / (7 * w)
			SetAnimationClipSpeed(a, "run_fwd", math.max(0.3, cs))
			BeginAnimationGroup(a, w)
			PlayAnimationLoop(a, "run_fwd", 1)
			EndAnimationGroup(a)
		end
		-- a punch: the right arm thrown at the target (IK), the body leaning in
		if c.e.strike and c.e.kx then
			pcall(SetAnimatorTransformIK, a, "shoulder_r", "hand_r", Transform(Vec(c.e.kx, c.e.ky, c.e.kz)), 1, 0, false, true)
		end
		-- (the user, 2026-11-15: "a simple animation for fire hydrant use to let players know which villager is putting out
		-- the fire") spraying: both hands forward on the extinguisher (the right on the nozzle, the left steadying the
		-- canister), sweeping slowly across the base of the fire; the cloud and the hiss come from extinguisher()
		c.sweepAim = nil
		if post == "spray" and c.e.ax then
			local aim = Vec(c.e.ax, c.e.ay, c.e.az)
			local chest = VecAdd(c.pos, Vec(0, 1.15, 0))
			local dir = VecSub(aim, chest)
			dir = VecNormalize(Vec(dir[1], math.max(-0.6, math.min(0.3, dir[2])), dir[3]))
			local side = VecNormalize(Vec(-dir[3], 0, dir[1]))
			local sw = math.sin(GetTime() * 2.3 + (c.k or 0)) * 0.22
			local hand = VecAdd(VecAdd(chest, VecScale(dir, 0.45)), VecAdd(VecScale(side, sw * 0.4), Vec(0, -0.08, 0)))
			c.sprayIK = {hand, VecAdd(VecSub(hand, VecScale(dir, 0.22)), VecAdd(VecScale(side, -0.14), Vec(0, -0.18, 0)))}
			c.sweepAim = VecAdd(aim, VecScale(side, sw * 3))
		else
			c.sprayIK = nil
		end
	end
	PlayAnimationInstances(a)
	if c.e.blind and post == "stand" then
		local okh, head = pcall(GetBoneWorldTransform, a, "head")
		if okh and head and head.pos then
			local fwd = VecNormalize(Vec(c.fx or 0, 0, c.fz or 1))
			local side = Vec(-fwd[3], 0, fwd[1])
			local eyes = VecAdd(head.pos, VecAdd(VecScale(fwd, 0.16), Vec(0, 0.06, 0)))
			pcall(SetAnimatorTransformIK, a, "shoulder_r", "hand_r", Transform(VecAdd(eyes, VecScale(side, -0.05))), 1, 0.5, false, true)
			pcall(SetAnimatorTransformIK, a, "shoulder_l", "hand_l", Transform(VecAdd(eyes, VecScale(side, 0.05))), 1, 0.5, false, true)
		end
	end
	-- (the arms after the clips, as bandaging does: before them the clip pose won and the extinguisher hung at the hip)
	if post == "spray" and c.sprayIK then
		pcall(SetAnimatorTransformIK, a, "shoulder_r", "hand_r", Transform(c.sprayIK[1]), 1, 0.4, false, true)
		pcall(SetAnimatorTransformIK, a, "shoulder_l", "hand_l", Transform(c.sprayIK[2]), 0.9, 0.4, false, true)
	end
	extinguisher(c, c.e.ext and (post == "spray" or post == "run" or post == "walk" or post == "stand"),
		post == "spray" and (c.sweepAim or (c.e.ax and Vec(c.e.ax, c.e.ay, c.e.az))) or nil, dt)
end

function VlView.postUpdate(dt)
	for _, c in pairs(VV.list) do
		pose(c, dt)
		-- bleeding: a drop now and then from the badly hurt (alive)
		if c.post ~= "dead" and (c.hp or 100) < 45 and c.pos and math.random() < dt * 2.5 then
			local at = c.post == "lie" and VecAdd(c.pos, Vec(0, 0.25, 0)) or VecAdd(c.pos, Vec(0, 1.0, 0))
			VlView.blood(at, 1, 0.4)
		end
	end
end

function VlView.render(dt) end

-- (the user, 2026-11-14: "names on the top of their heads (only when they're in line of sight)"; "I shouldn't be able
-- to see the sleeping symbols through walls") a name and, when hurt, a health bar over each villager this machine's
-- camera can see; "z z" over sleepers likewise
function VlView.draw()
	-- (the user, 2026-11-15: "villager names should not draw over inventory UI") another mod's full-screen UI is open
	-- on this machine: the Inventory's screen (inventory.screenopen, set by that mod on its own machine)
	if GetBool("inventory.screenopen") then return end
	local cam = GetCameraTransform().pos
	local t = GetTime()
	for _, c in pairs(VV.list) do
		if c.pos and c.post ~= "dead" then
			local up = (c.post == "lie" and 0.75) or (c.post == "sit" and 1.35) or (c.post == "kneel" and 1.35) or 2.05
			local head = VecAdd(c.pos, Vec(0, up, 0))
			local dist = VecLength(VecSub(head, cam))
			if dist < VL_CFG.nameRange and seenFromCamera(VecSub(head, Vec(0, 0.25, 0))) then
				local x, y, d = UiWorldToPixel(head)
				if d and d > 0 then
					local a = math.max(0.25, math.min(1, (VL_CFG.nameRange - dist) / 8))
					UiPush()
					UiTranslate(x, y)
					UiAlign("center bottom")
					UiFont("bold.ttf", 22)
					UiColor(0, 0, 0, 0.6 * a)
					UiTranslate(1, 1); UiText(c.name or "?"); UiTranslate(-1, -1)
					UiColor(1, 1, 1, a)
					UiText(c.name or "?")
					local fz = shared.vl and shared.vl.frozen
					if fz then                                      -- (frozen without the AI: why, over every head)
						UiPush()
						UiTranslate(0, -24)
						UiFont("bold.ttf", 18)
						local msg = fz == "budget" and "Koetama's AI budget ran out" or "Koetama not detected"
						UiColor(0, 0, 0, 0.6 * a); UiTranslate(1, 1); UiText(msg); UiTranslate(-1, -1)
						UiColor(1, 0.55, 0.3, a); UiText(msg)
						UiPop()
					end
					if (c.hp or 100) < 100 then
						UiTranslate(0, 6)
						UiAlign("center top")
						UiColor(0, 0, 0, 0.6 * a)
						UiRect(64, 7)
						UiAlign("left top")
						UiTranslate(-31, 1)
						local f = math.max(0, (c.hp or 0) / 100)
						UiColor(1 - f, 0.15 + 0.7 * f, 0.15, a)
						UiRect(62 * f, 5)
					end
					UiPop()
					if (c.post == "lie" or (c.e and c.e.sleep)) and dist < 18 then
						local zp = VecAdd(c.pos, Vec(0, 0.95 + (t * 0.4 + (c.k or 0) * 0.3) % 0.6, 0))
						local zx, zy, zd = UiWorldToPixel(zp)
						if zd and zd > 0 then
							UiPush(); UiTranslate(zx + 30, zy); UiAlign("center middle"); UiFont("bold.ttf", 22)
							UiColor(1, 1, 1, 0.75); UiText(c.e and c.e.down and "..." or "z z"); UiPop()
						end
					end
				end
			end
		end
	end
end
