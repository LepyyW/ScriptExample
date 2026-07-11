-- Discord: lepy.devv | Roblox: LepyyW

-- ThrowableSystem
-- A server-authoritative physics system for throwable objects.
--
-- The reason this does not simply use Roblox's built-in physics engine (setting
-- AssemblyLinearVelocity on an unanchored part and letting it fly) is control and
-- reliability. Engine-driven parts owned by a client can be tampered with, and fast
-- moving unanchored parts routinely tunnel straight through thin walls because the
-- engine only resolves collisions at discrete simulation steps.
--
-- Instead every projectile here is anchored, and the script integrates its motion
-- by hand each frame. Because we know exactly where the object was last frame and
-- exactly where we intend to move it this frame, we can raycast along that segment
-- and catch every surface in between. Nothing is ever skipped, no matter how fast
-- the object is travelling.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Tunables. Kept in one place so behaviour can be adjusted without hunting through
-- the logic below.
local GRAVITY = Vector3.new(0, -75, 0)
local DRAG_COEFFICIENT = 0.02
local MAX_LIFETIME = 8
local MAX_SPEED = 400
local THROW_COOLDOWN = 0.35
local FRAGMENT_POOL_SIZE = 60
local FRAGMENT_LIFETIME = 2
local SKIN_WIDTH = 0.05

-- Per-object-type definitions. This is the data that drives everything: adding a new
-- throwable is a matter of adding a table here, not writing new code. "Shatter" objects
-- break apart on first contact, "Bounce" objects ricochet until they run out of energy.
local OBJECT_TYPES = {
	Chair = {
		ImpactMode = "Shatter",
		Damage = 28,
		ThrowSpeed = 110,
		Spin = Vector3.new(14, 4, 2),
		FragmentCount = 6,
		FragmentScale = 0.35,
		Size = Vector3.new(2, 3, 2),
		Color = Color3.fromRGB(120, 82, 48),
		Material = Enum.Material.Wood,
	},
	GlassBottle = {
		ImpactMode = "Shatter",
		Damage = 16,
		ThrowSpeed = 140,
		Spin = Vector3.new(22, 6, 0),
		FragmentCount = 10,
		FragmentScale = 0.2,
		Size = Vector3.new(0.8, 2, 0.8),
		Color = Color3.fromRGB(93, 156, 122),
		Material = Enum.Material.Glass,
	},
	Brick = {
		ImpactMode = "Bounce",
		Damage = 34,
		ThrowSpeed = 95,
		Spin = Vector3.new(8, 8, 8),
		Restitution = 0.45,
		MaxBounces = 3,
		Size = Vector3.new(2, 1, 1),
		Color = Color3.fromRGB(150, 62, 52),
		Material = Enum.Material.Brick,
	},
}

-- Fragment pool.
--
-- Shattering spawns a handful of debris parts, and shattering happens constantly.
-- Calling Instance.new every single time would churn through memory and force the
-- garbage collector to work harder than it needs to. Instead a fixed number of parts
-- are created once at startup, parked out of sight, and handed out on request. When a
-- fragment expires it is parked again rather than destroyed. Allocation cost after the
-- first frame is therefore zero.
local FragmentPool = {}
FragmentPool.__index = FragmentPool

function FragmentPool.new(size)
	local self = setmetatable({}, FragmentPool)

	self._container = Instance.new("Folder")
	self._container.Name = "FragmentPool"
	self._container.Parent = workspace

	-- Parts sitting in _available are inactive and reusable. _size is only kept so the
	-- pool knows when it is safe to return a part rather than destroy it outright.
	self._available = {}
	self._size = size

	for _ = 1, size do
		local part = Instance.new("Part")
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.Parent = self._container
		self:_park(part)
		table.insert(self._available, part)
	end

	return self
end

-- Parking a part means freezing it and moving it far below the map. It stays in the
-- DataModel (so no rebuild cost) but does nothing and is invisible to players.
function FragmentPool:_park(part)
	part.Anchored = true
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
	part.CFrame = CFrame.new(0, -500, 0)
	part.Transparency = 1
end

function FragmentPool:Acquire()
	local part = table.remove(self._available)
	if part then
		return part
	end

	-- The pool has run dry, which means an unusual amount of shattering is happening at
	-- once. Rather than fail or stall, fall back to a fresh part. It is released back
	-- into the pool afterwards only if there is room, so the pool self-heals up to its
	-- intended size and never grows without bound.
	local part = Instance.new("Part")
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Parent = self._container
	return part
end

function FragmentPool:Release(part)
	if not part or not part.Parent then
		return
	end

	if #self._available >= self._size then
		part:Destroy()
		return
	end

	self:_park(part)
	table.insert(self._available, part)
end

-- Throwable.
--
-- Each thrown object is an instance of this class. The metatable gives every projectile
-- the same set of methods without duplicating those functions per object, and the
-- instance table holds only the state that genuinely differs between projectiles.
local Throwable = {}
Throwable.__index = Throwable

-- Every live projectile is tracked here so a single Heartbeat connection can step all
-- of them. One connection stepping N objects is dramatically cheaper than N connections
-- stepping one object each.
local ActiveThrowables = {}

function Throwable.new(owner, objectId, origin, direction, pool)
	local definition = OBJECT_TYPES[objectId]
	if not definition then
		return nil
	end

	local self = setmetatable({}, Throwable)

	self.Owner = owner
	self.ObjectId = objectId
	self.Definition = definition
	self.Pool = pool
	self.Age = 0
	self.Bounces = 0
	self.Alive = true

	-- Direction is normalised and clamped on the server. The client sends where it
	-- wants to aim; it does not get to decide how fast the object travels. Clamping the
	-- resulting speed means a tampered client cannot produce a projectile that outruns
	-- the raycast logic or one-shots everything on the map.
	local unit = direction.Magnitude > 0 and direction.Unit or Vector3.new(0, 0, -1)
	local speed = math.min(definition.ThrowSpeed, MAX_SPEED)
	self.Velocity = unit * speed

	-- LastPosition is the anchor of the whole collision approach. Each frame the ray is
	-- cast from here to the newly integrated position, so the segment between the two
	-- is never left unchecked.
	self.LastPosition = origin

	local part = Instance.new("Part")
	part.Name = objectId
	part.Size = definition.Size
	part.Color = definition.Color
	part.Material = definition.Material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CFrame = CFrame.new(origin, origin + unit)
	part.Parent = workspace
	self.Part = part

	-- The raycast must ignore the projectile itself and the thrower, otherwise the very
	-- first cast would hit the thrower's own torso and detonate instantly. Building the
	-- params object once here and reusing it every frame avoids per-frame allocation.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { part, pool._container, owner.Character }
	self.RaycastParams = params

	table.insert(ActiveThrowables, self)

	return self
end

-- Integrates one frame of motion and resolves any collision along the way.
function Throwable:Step(deltaTime)
	if not self.Alive then
		return
	end

	self.Age += deltaTime
	if self.Age >= MAX_LIFETIME then
		self:Destroy()
		return
	end

	local velocity = self.Velocity

	-- Drag opposes motion and grows with the square of speed, which is how air
	-- resistance actually behaves: a fast object is slowed far more aggressively than a
	-- slow one. Multiplying the unit direction by speed squared gives that curve, and
	-- subtracting it produces a throw that decelerates naturally instead of sailing on
	-- forever at a constant rate.
	local speed = velocity.Magnitude
	if speed > 0 then
		local drag = velocity.Unit * (speed * speed * DRAG_COEFFICIENT)
		velocity -= drag * deltaTime
	end

	-- Semi-implicit Euler integration: acceleration is applied to velocity first, then
	-- the updated velocity is used to move the object. Doing it in this order rather
	-- than the reverse keeps the trajectory stable over long flights instead of slowly
	-- gaining energy, which is what naive Euler tends to do.
	velocity += GRAVITY * deltaTime

	local origin = self.LastPosition
	local displacement = velocity * deltaTime
	local target = origin + displacement

	-- The single most important line in the system. Rather than asking "is anything
	-- touching me right now", it asks "did anything sit between where I was and where I
	-- am going". A projectile moving 400 studs per second covers over six studs in one
	-- frame, so a presence check would miss any wall thinner than that. A swept ray
	-- cannot miss it.
	local result = workspace:Raycast(origin, displacement, self.RaycastParams)

	if result then
		self:_onHit(result, velocity)
		return
	end

	self.Velocity = velocity
	self.LastPosition = target

	-- Orientation is built from a fresh look-direction each frame rather than being
	-- accumulated, so the object always points along its actual path of travel. The
	-- spin is then layered on top of that as a local rotation, which is why a chair
	-- tumbles end over end while still tracking its arc.
	local definition = self.Definition
	local spin = definition.Spin
	local look = velocity.Magnitude > 0 and velocity.Unit or Vector3.new(0, 0, -1)
	local facing = CFrame.new(target, target + look)
	local tumble = CFrame.Angles(spin.X * self.Age, spin.Y * self.Age, spin.Z * self.Age)

	self.Part.CFrame = facing * tumble
end

-- Decides what happens when the swept ray finds something.
function Throwable:_onHit(result, velocity)
	local hitPart = result.Instance
	local normal = result.Normal
	local position = result.Position

	-- Walk up the hierarchy from whatever part was struck to find the Humanoid that owns
	-- it, if any. Hitting an arm and hitting a leg should both damage the same character,
	-- and FindFirstAncestorOfClass handles accessories and nested rigs correctly where
	-- checking hitPart.Parent alone would not.
	local model = hitPart:FindFirstAncestorOfClass("Model")
	local humanoid = model and model:FindFirstChildOfClass("Humanoid")

	if humanoid and humanoid.Health > 0 then
		-- Damage scales with how fast the object was actually moving on impact, not with a
		-- flat number. A brick thrown at point blank range hurts; the same brick tumbling
		-- to a stop at the end of its arc barely does. The ratio is capped at 1 so a
		-- projectile can never exceed its listed damage.
		local impactRatio = math.min(velocity.Magnitude / self.Definition.ThrowSpeed, 1)
		humanoid:TakeDamage(self.Definition.Damage * impactRatio)

		-- A body hit always ends the projectile regardless of its impact mode, because a
		-- brick bouncing off someone's head and continuing on to hit them again would be
		-- both silly and abusable.
		self:_shatter(position, velocity)
		self:Destroy()
		return
	end

	if self.Definition.ImpactMode == "Bounce" then
		self:_bounce(result, velocity)
		return
	end

	self:_shatter(position, velocity)
	self:Destroy()
end

-- Reflects the projectile off a surface.
function Throwable:_bounce(result, velocity)
	local definition = self.Definition

	self.Bounces += 1
	if self.Bounces > definition.MaxBounces then
		self:_shatter(result.Position, velocity)
		self:Destroy()
		return
	end

	-- The standard reflection formula: r = v - 2(v . n)n
	--
	-- The dot product gives how much of the velocity is pointing into the surface. That
	-- component is what needs to be reversed; the component running parallel to the
	-- surface should be left alone, which is why a brick thrown at a glancing angle
	-- skims along a wall rather than stopping dead. Subtracting twice the perpendicular
	-- component flips it while leaving the parallel part untouched.
	local normal = result.Normal
	local reflected = velocity - 2 * velocity:Dot(normal) * normal

	-- Restitution is the fraction of energy that survives the impact. Anything below 1
	-- means the bounce is inelastic, so each successive bounce is weaker and the object
	-- eventually settles instead of ricocheting forever.
	self.Velocity = reflected * definition.Restitution

	-- Nudging the projectile off the surface along the normal is essential. If it were
	-- placed exactly on the contact point, the next frame's ray would start flush with
	-- the wall and immediately register another hit, trapping the object in an infinite
	-- bounce loop against a single surface.
	self.LastPosition = result.Position + normal * SKIN_WIDTH
	self.Part.CFrame = CFrame.new(self.LastPosition)
end

-- Breaks the projectile into debris.
function Throwable:_shatter(position, velocity)
	local definition = self.Definition
	local count = definition.FragmentCount
	if not count then
		return
	end

	local fragmentSize = definition.Size * definition.FragmentScale
	local pool = self.Pool

	for _ = 1, count do
		local fragment = pool:Acquire()
		fragment.Size = fragmentSize
		fragment.Color = definition.Color
		fragment.Material = definition.Material
		fragment.Transparency = 0

		-- Random rotation on spawn so the shards do not all appear perfectly aligned,
		-- which would immediately read as artificial. Two pi is a full revolution, so this
		-- gives each fragment a completely arbitrary starting orientation.
		fragment.CFrame = CFrame.new(position) * CFrame.Angles(
			math.random() * math.pi * 2,
			math.random() * math.pi * 2,
			math.random() * math.pi * 2
		)

		-- Debris inherits a portion of the projectile's momentum rather than scattering
		-- symmetrically. A bottle thrown hard to the right showers its glass to the right,
		-- which is what actually happens and what a player expects to see. The random term
		-- added on top is only there to spread the shards apart so they do not travel as a
		-- single clump.
		local inherited = velocity * 0.25
		local scatter = Vector3.new(
			(math.random() - 0.5) * 30,
			math.random() * 18,
			(math.random() - 0.5) * 30
		)

		-- Handing the fragment to the engine's physics at this point is a deliberate
		-- choice. The precision of manual integration matters for the projectile because
		-- it deals damage and must not tunnel. Debris is decorative, short lived, and
		-- never queried, so the engine's cheaper approximate simulation is the correct
		-- tool and costs us nothing.
		fragment.Anchored = false
		fragment.AssemblyLinearVelocity = inherited + scatter

		-- Fragments must go back to the pool, not be destroyed, or the pool would drain
		-- and every subsequent shatter would fall back to allocating fresh parts.
		task.delay(FRAGMENT_LIFETIME, function()
			pool:Release(fragment)
		end)
	end
end

function Throwable:Destroy()
	if not self.Alive then
		return
	end

	self.Alive = false

	if self.Part then
		self.Part:Destroy()
		self.Part = nil
	end
end

-- Runtime.
local pool = FragmentPool.new(FRAGMENT_POOL_SIZE)

local remote = Instance.new("RemoteEvent")
remote.Name = "ThrowRequest"
remote.Parent = ReplicatedStorage

-- Cooldowns are stored against the Player object itself rather than the character or
-- the user id. Keying on the instance means the entry disappears on its own when the
-- player leaves and the object becomes unreachable, so there is no stale data to clean
-- up manually.
local cooldowns = {}

remote.OnServerEvent:Connect(function(player, objectId, direction)
	-- Everything arriving from a client is treated as untrusted input. A malicious client
	-- can send any value of any type through a RemoteEvent, so each argument is checked
	-- for both type and legitimacy before it is allowed anywhere near the simulation.
	if type(objectId) ~= "string" or not OBJECT_TYPES[objectId] then
		return
	end

	if typeof(direction) ~= "Vector3" then
		return
	end

	-- A zero length vector cannot be normalised, and NaN would propagate silently through
	-- every subsequent calculation and corrupt the projectile's position permanently.
	-- Both are rejected outright. The NaN test relies on NaN being the only value in Lua
	-- that is not equal to itself.
	local magnitude = direction.Magnitude
	if magnitude <= 0 or magnitude ~= magnitude then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return
	end

	-- Rate limiting is enforced here on the server and nowhere else. A client-side
	-- cooldown is a convenience for the player, not a security measure, and an exploiter
	-- would simply remove it and fire the remote every frame.
	local now = os.clock()
	local lastThrow = cooldowns[player]
	if lastThrow and now - lastThrow < THROW_COOLDOWN then
		return
	end
	cooldowns[player] = now

	-- Spawning slightly in front of the character keeps the projectile clear of the
	-- thrower's own body on frame one.
	local origin = root.Position + direction.Unit * 3
	Throwable.new(player, objectId, origin, direction, pool)
end)

Players.PlayerRemoving:Connect(function(player)
	cooldowns[player] = nil
end)

-- A single Heartbeat drives every live projectile.
--
-- The array is walked backwards specifically so that entries can be removed mid-loop.
-- Removing an element from a table shifts everything after it down by one, which would
-- cause a forward loop to skip the next projectile entirely. Iterating from the end
-- means the only elements that shift are ones already visited.
RunService.Heartbeat:Connect(function(deltaTime)
	for index = #ActiveThrowables, 1, -1 do
		local throwable = ActiveThrowables[index]

		if throwable.Alive then
			throwable:Step(deltaTime)
		end

		-- Checked again after stepping, because Step may well have destroyed the object by
		-- hitting something. Testing before and after in the same pass means a dead
		-- projectile is removed on the exact frame it dies rather than lingering for one
		-- extra frame.
		if not throwable.Alive then
			table.remove(ActiveThrowables, index)
		end
	end
end)
