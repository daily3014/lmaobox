local config = {
	debug = false,
	enabled = true,
	cheater_priority = 1, -- at what priority is a player considered cheating

	-- when passive, it will only react to threats that kill you instantly
	passive = false,
	passive_resistance = "Bullet", -- "Bullet" / "Blast" / "Fire"
	manual_charge = true, -- Allow manual charging?

	filters = {
		bonked = false, -- react to bonked players
		friends = false, -- react to friends
	},

	-- which resistance types to skip
	disallow = {
		bullet = false,
		blast = false,
		fire = false,
	},

	-- how sensitive each resist type is, higher is more sensitive and will pop more frequently
	sensitivity = {
		-- in rijin, these values are placebo in prod and only applied in dev
		-- shucks.
		bullet = 1,
		blast = 1,
		fire = 1,
	},
}

local UBER_COST = 26 -- If danger exceeds cost, vaccinator will pop
local MAX_PLAYER_DIST = 32
local MAX_PROJECTILE_DIST = 8
local CLOSE_RANGE = 4
local PROJECTILE_DANGER = 6
local VULNERABLE_COST_MODIFIER = 0.9 -- Lowers cost by this modifier if player is vulnerable
local HEALTH_COST_MULTIPLIER = 1.0 -- Multiples the cost reduction of players health
local MAGIC_THREAT_VALUE = 6924

local CWeapon, CPlayer

---@enum ResistanceTypes
local RESIST_TYPES = {
	UNKNOWN = -1,
	AMMO_RESIST = 0,
	BLAST_RESIST = 1,
	FIRE_RESIST = 2,
}

local ManualCharge = RESIST_TYPES.AMMO_RESIST

---@param Message string
---@param ... any
local function Notify(Message, ...)
	client.ChatPrintf(string.format("\x073475c9[Auto Vaccinator] \x01%s", string.format(Message, ...)))
end

---@param Message string
---@param ... any
local function Debug(Message, ...)
	if not config.debug then
		return
	end

	local Formatted = string.format(Message, ...)
	-- Chud print isn't same as echo, isn't shown when developer=1
	client.Command(string.format("echo %s", Formatted) .. "\n", true)
	--print(string.format(Message, ...))
end

---@param Message string
---@param ... any
local function DebugAssert(Condition, Message, ...)
	if not config.debug then
		return
	end

	if not Condition then
		error(string.format(Message, ...) .. "\nTraceback:\n" .. debug.traceback())
	end
end

---@param x number
---@param inmin number
---@param inmax number
---@param outmin number
---@param outmax number
---@return number number
local function map(x, inmin, inmax, outmin, outmax)
	return outmin + (x - inmin) * (outmax - outmin) / (inmax - inmin)
end

---@param Value number
---@return number number
local function round(Value)
	local Integral, Fractional = math.modf(Value)
	return Integral + (Fractional > 0.5 and 1 or 0)
end

---@param Value number
---@param Min number
---@param Max number
---@return number number
local function clamp(Value, Min, Max)
	if Value > Max then return Max end
	if Value < Min then return Min end
	return Value
end

---@param Value number
---@return number number
local function simple_spline(Value)
	local ValueSquared = Value * Value
	return (3 * ValueSquared - 2 * ValueSquared * Value)
end

---@param Value number
---@@param inmin number
---@param inmax number
---@param outmin number
---@param outmax number
---@return number number
local function SimpleSplineRemap(Value, inmin, inmax, outmin, outmax)
	if inmin == inmax then
		return Value >= inmax and outmax or outmin
	end

	local CValue = (Value - inmin) / (inmax - inmin)
	CValue = clamp(CValue, 0, 1)
	return outmin + (outmax - outmin) * simple_spline(CValue)
end

---@class CEntity
---@field private Entity Entity?
local CEntity = {} do
	CEntity.__index = CEntity

	---@param Entity Entity
	---@return CEntity entity
	function CEntity.from(Entity)
		DebugAssert(type(Entity) ~= "table", "Expected lmaobox entity, got %s", type(Entity))
		DebugAssert(Entity and Entity:IsValid(), "CEntity: Expected valid entity, got %s", type(Entity))
		return setmetatable({Entity = Entity}, CEntity)
	end

	---@param Other AnyEntity?
	---@return boolean equal
	function CEntity:Is(Other)
		if not Other or not self.Entity:IsValid() then
			return false
		end

		return Other:IsValid() and Other:GetIndex() == self.Entity:GetIndex()
	end

	---@return Entity entity
	function CEntity:Raw()
		return self.Entity
	end

	---@return boolean valid
	function CEntity:IsValid()
		return self.Entity:IsValid()
	end

	function CEntity:GetIndex()
		return self.Entity:GetIndex()
	end

	---@return boolean is_weapon
	function CEntity:IsWeapon()
		return self.Entity:IsWeapon()
	end

	---@return boolean is_player
	function CEntity:IsPlayer()
		return self.Entity:IsPlayer()
	end

	---@return boolean is_dormant
	function CEntity:IsDormant()
		return self.Entity:IsDormant()
	end

	--- Returns the entity's team
	---@return number team
	function CEntity:Team()
		if not self:IsValid() then
			return -1
		end

		return self.Entity:GetPropInt("m_iTeamNum")
	end


	do -- Projectiles
		---@return boolean is_critical_projectile
		function CEntity:IsCritical()
			local Class = self.Entity:GetClass()
			if Class == "CTFProjectile_EnergyBall" then
				return self.Entity:GetPropBool("m_bChargedShot")
			end

			if Class == "CTFProjectile_Rocket"
				or Class == "CTFProjectile_Arrow"
				or Class == "CTFProjectile_HealingBolt"
				or Class == "CTFGrenadePipebombProjectile"
				or Class == "CTFProjectile_Flare"
			then
				return self.Entity:GetPropBool("m_bCritical")
			end

			return false
		end
		
		---@return boolean is_deflected
		function CEntity:IsDeflected()
			if self:IsStickyBomb() then
				-- Sticky bombs can be deflected but won't deal minicrits
				return false
			end

			return self.Entity:GetPropInt("m_iDeflected") > 0
		end

		local Projectiles = {
			CTFProjectile_Rocket = true,
			CTFProjectile_JarGas = true,
			CTFProjectile_Cleaver = true,
			CTFProjectile_JarMilk = true,
			CTFProjectile_Jar = true,
			CTFProjectile_MechanicalArmOrb = true,
			CTFGrenadePipebombProjectile = true,
			CTFProjectile_SentryRocket = true,
			CTFProjectile_Flare = true,
			CTFProjectile_EnergyBall = true,
			CTFProjectile_SpellKartBats = true,
			CTFProjectile_SpellKartOrb = true,
			CTFProjectile_SpellLightningOrb = true,
			CTFProjectile_SpellMeteorShower = true,
			CTFProjectile_SpellMirv = true,
			CTFProjectile_SpellPumpkin = true,
			CTFProjectile_SpellSpawnHorde = true,
			CTFProjectile_SpellSpawnZombie = true,
			CTFProjectile_SpellSpawnBoss = true,
			CTFProjectile_SpellBats = true,
			CTFProjectile_SpellFireball = true,
			CTFBall_Ornament = true,
			CTFStunBall = true,
			CTFProjectile_BallOfFire = true,
		}

		---@return boolean is_projectile
		function CEntity:IsProjectile()
			local Class = self.Entity:GetClass()
			
			if Class == "CTFProjectile_HealingBolt" or Class == "CTFProjectile_Arrow" then
				return self:IsArrow()
			end

			return Projectiles[Class] == true
		end
	
		---@return boolean is_rocket
		function CEntity:IsRocket()
			local Class = self.Entity:GetClass()
			return Class == "CTFProjectile_Rocket"
				or Class == "CTFProjectile_SentryRocket"
				or Class == "CTFProjectile_EnergyBall"
		end

		---@return boolean is_demo_projectile
		function CEntity:IsDemoProjectile()
			return self.Entity:GetClass() == "CTFGrenadePipebombProjectile"
		end

		---@return boolean is_arrow
		function CEntity:IsArrow()
			local Class = self.Entity:GetClass()
			return (Class == "CTFProjectile_Arrow" or Class == "CTFProjectile_HealingBolt")
				and self:EstVelocity():Length() > 1
		end

		---@return boolean is_flare
		function CEntity:IsFlare()
			return self.Entity:GetClass() == "CTFProjectile_Flare"
		end

		---@return boolean is_fire_spell
		function CEntity:IsFireSpell()
			local Class = self.Entity:GetClass()
			return Class == "CTFProjectile_SpellFireball"
				or Class == "CTFProjectile_SpellMeteorShower"
		end

		---@return boolean is_flame_ball
		function CEntity:IsFlameBall()
			return self.Entity:GetClass() == "CTFProjectile_BallOfFire"
		end
		
		---@return boolean is_huntsman_arrow
		function CEntity:IsHuntsmanArrow()
			return self.Entity:GetClass() == "CTFProjectile_Arrow"
				and self.Entity:GetPropInt("m_iProjectileType") == 8
		end

		---@return boolean is_sticky_bomb
		function CEntity:IsStickyBomb()
			return self:IsDemoProjectile() and self.Entity:GetPropInt("m_iType") == 1
		end

		---@return CWeapon? launcher
		function CEntity:GetLauncher()
			local Launcher = self.Entity:GetPropEntity("m_hLauncher")
			return (Launcher and Launcher:IsValid())
				and CWeapon.from(Launcher)
				or nil
		end
	end

	do -- Buildings
		---@return CPlayer? owner
		function CEntity:BuildingOwner()
			local Builder = self.Entity:GetPropEntity("m_hBuilder")
			if not Builder or not Builder:IsValid() then
				return nil
			end

			return CPlayer.fromCached(Builder)
		end
	
		---@return boolean is_sapped
		function CEntity:Sapped()
			return self.Entity:GetPropBool("m_bHasSapper")
		end

		---@return boolean is_building
		function CEntity:Building()
			return self.Entity:GetPropBool("m_bBuilding")
		end

		---@return boolean is_disabled
		function CEntity:Disabled()
			return self.Entity:GetPropBool("m_bDisabled")
		end

		---@return boolean is_placing
		function CEntity:Placing()
			return self.Entity:GetPropBool("m_bPlacing")
		end
	end

	do -- Sentry
		---@return boolean is_sentry
		function CEntity:IsSentry()
			return self.Entity:GetClass() == "CObjectSentrygun"
		end

		---@return boolean is_mini_sentry
		function CEntity:IsMiniSentry()
			return self:IsSentry() and self.Entity:GetPropBool("m_bMiniBuilding")
		end
	
		---@return CEntity? target
		function CEntity:GetSentryTarget()
			if not self:IsSentry() and not self:IsMiniSentry() then
				return nil
			end

			local AutoAimHandle = self.Entity:GetPropEntity("m_hAutoAimTarget")
			return AutoAimHandle
				and CEntity.from(AutoAimHandle)
				or nil
		end
	end

	--- Returns the entity's origin
	---@return Vector3 origin
	function CEntity:Origin()
		return self.Entity:GetAbsOrigin() --self.Entity:GetPropVector("m_vecOrigin")
	end

	---@return Vector3 obb_center
	function CEntity:OBBCenter()
		local Mins = self.Entity:GetPropVector("m_Collision", "m_vecMins")
		local Maxs = self.Entity:GetPropVector("m_Collision", "m_vecMaxs")

		return self:Origin() + (Mins + Maxs) * 0.5
	end

	---@return EulerAngles absolute_angle
	function CEntity:AbsAngles()
		return self.Entity:GetAbsAngles()
	end

	---@return Vector3 estimated_velocity
	function CEntity:EstVelocity()
		return self.Entity:EstimateAbsVelocity()
	end
end

---@alias AnyEntity CPlayer | CWeapon | CEntity | Entity 
---@alias AnyCEntity CPlayer | CWeapon | CEntity

---@return boolean is_centity
local function IsCEntity(Value)
	return type(Value) == "table" and getmetatable(Value) == CEntity
end

---@param Value AnyEntity?
---@return Entity? raw
local function ToRaw(Value)
	if Value and IsCEntity(Value) then
		return Value:Raw()
	end

	return Value --[[@as Entity]]
end

---@class CWeapon
---@field private Entity Entity?
CWeapon = {} do
	CWeapon.__index = CWeapon

	---@type table<Entity, CWeapon>
	local Cache = setmetatable({}, {__mode = "kv"})

	---@param Weapon CEntity | Entity 
	---@return CWeapon cweapon
	function CWeapon.from(Weapon)
		local WeaponEntity = ToRaw(Weapon)

		DebugAssert(WeaponEntity and WeaponEntity:IsValid(), "CWeapon: Expected valid entity, got %s", type(WeaponEntity))
		DebugAssert(WeaponEntity and WeaponEntity:IsWeapon(), "Expected a weapon entity")

		return setmetatable({
			Entity = WeaponEntity,
		}, CWeapon)
	end

	---@param Weapon (Entity | CEntity)?
	---@return CWeapon? cweapon
	function CWeapon.fromCached(Weapon)
		local WeaponEntity = ToRaw(Weapon)
		if not WeaponEntity then
			return nil
		end

		local Cached = Cache[WeaponEntity]
		if Cached then
			if Cached:IsValid() then
				-- only return if the cached cweapon is valid..
				return Cached
			end

			-- don't release brah
			--Cached:Release()
		end
		
		local CWeaponObject = CWeapon.from(WeaponEntity)
		Cache[WeaponEntity] = CWeaponObject

		return CWeaponObject
	end

	function CWeapon.clearCache()
		Cache = setmetatable({}, {__mode = "kv"})
	end

	---@return nil
	function CWeapon:Release()
		if not self.Entity then
			return
		end

		if self.Entity:IsValid() then
			self.Entity:Release()
			self.Entity = nil
		end
	end

	---@return boolean valid
	function CWeapon:IsValid()
		return (self.Entity and self.Entity:IsValid() and self.Entity:IsWeapon())
			or false
	end

	-- CEntity inherits
	CWeapon.Origin = CEntity.Origin
	CWeapon.GetIndex = CEntity.GetIndex
	CWeapon.Raw = CEntity.Raw
	CWeapon.Team = CEntity.Team

	---@return WeaponData info
	function CWeapon:Info()
		return self.Entity:GetWeaponData()
	end

	---@return number definition_index
	function CWeapon:DefinitionIndex()
		return self.Entity:GetPropInt("m_iItemDefinitionIndex")
	end

	---@return number id
	function CWeapon:ID()
		return self.Entity:GetWeaponID()
	end

	do -- Weapon classification
		---@return boolean is_medigun
		function CWeapon:IsMedigun()
			return self:IsValid() and self.Entity:IsMedigun()
		end

		---@return boolean is_sniper_rifle
		function CWeapon:IsSniperRifle()
			local ID = self:IsValid() and self:ID() or -1
			return ID == TF_WEAPON_SNIPERRIFLE
				or ID == TF_WEAPON_SNIPERRIFLE_CLASSIC
				or ID == TF_WEAPON_SNIPERRIFLE_DECAP
		end

		---@return boolean is_scattergun
		function CWeapon:IsScatterGun()
			local ID = self:IsValid() and self:ID() or -1
			return ID == TF_WEAPON_SCATTERGUN
				or ID == TF_WEAPON_SODA_POPPER
				or ID == TF_WEAPON_PEP_BRAWLER_BLASTER
				or ID == TF_WEAPON_HANDGUN_SCOUT_PRIMARY
		end

		---@return boolean is_directhit
		function CWeapon:IsDirectHit()
			local ID = self:IsValid() and self:ID() or -1
			return ID == TF_WEAPON_DIRECTHIT
		end

		---@return boolean is_huntsman
		function CWeapon:IsHuntsman()
			local ID = self:IsValid() and self:ID() or -1
			return ID == TF_WEAPON_COMPOUND_BOW
		end

		---@return boolean is_shotgun
		function CWeapon:IsShotgun()
			local ID = self:IsValid() and self:ID() or -1
			return ID == TF_WEAPON_SHOTGUN_SOLDIER
				or ID == TF_WEAPON_SHOTGUN_HWG
				or ID == TF_WEAPON_SHOTGUN_PRIMARY
				or ID == TF_WEAPON_SHOTGUN_PYRO
		end

		---@return boolean is_minigun
		function CWeapon:IsMinigun()
			local ID = self:IsValid() and self:ID() or -1
			return ID == TF_WEAPON_MINIGUN
		end

		---@return boolean is_ambassador
		function CWeapon:IsAmbassador()
			-- TODO: fucking shit, use smth more reliable
			local Definition = self:DefinitionIndex()
			return Definition == 1006
				or Definition == 61
		end

		---@return boolean is_flamethrower
		function CWeapon:IsFlamethrower()
			local ID = self:IsValid() and self:ID() or -1
			return ID == TF_WEAPON_FLAMETHROWER
		end

		---@return boolean is_enforcer
		function CWeapon:IsEnforcer()
			local Definition = self:DefinitionIndex()
			return Definition == 460
		end
	end

	do -- Mediguns
		---@return boolean is_vaccinator
		function CWeapon:IsVaccinator()
			return self:IsValid() and self:DefinitionIndex() == 998
		end

		---@return ResistanceTypes? resist_type
		function CWeapon:ResistType()
			if not self:IsMedigun() then
				return nil
			end
			
			return self.Entity:GetPropInt("m_nChargeResistType")
		end

		--- Sets the resistance type on the client, to avoid
		--- issues with overshooting due to latency
		---@param Type ResistanceTypes
		function CWeapon:SetResistType(Type)
			if not self:IsMedigun() or not self:IsVaccinator() then
				return nil
			end

			self.Entity:SetPropInt(Type, "m_nChargeResistType")
		end

		---@return Entity? healing_target
		function CWeapon:HealingTarget()
			if not self:IsMedigun() then
				return nil
			end

			local HealingTarget = self.Entity:GetPropEntity("m_hHealingTarget")
			if not HealingTarget or not HealingTarget:IsValid() then
				return nil
			end

			return HealingTarget
		end

		---@return number? charges
		function CWeapon:Charges()
			if self:IsVaccinator() then
				local ChargeMeter = self.Entity:GetPropFloat("LocalTFWeaponMedigunData", "m_flChargeLevel")
				return math.floor(ChargeMeter * 4)
			end

			return nil
		end
	end

	---@return boolean can_headshot
	function CWeapon:CanHeadshot()
		-- 230 = Sydney Sleeper
		return self:IsAmbassador() or (self:IsSniperRifle() and self:DefinitionIndex() ~= 230)
	end

	---@return boolean is_melee
	function CWeapon:IsMelee()
		return self.Entity:IsMeleeWeapon()
	end

	-- TODO: These Is__ functions could be replaced
	-- with table lookups, if if statements are slow
	-- which they probably are, lots of branches!

	
	---@return boolean harmless
	function CWeapon:IsHarmless()
		local ID, Definition = self:ID(), self:DefinitionIndex()
		return Definition == 265 -- Base jumper
			or Definition == 237 -- Rocket jumper
			or ID == TF_WEAPON_GRAPPLINGHOOK -- Grappling hook
			or ID == TF_WEAPON_BUILDER -- Sappers?
			or ID == TF_WEAPON_PDA_ENGINEER_BUILD -- PDA?
			or ID == TF_WEAPON_LUNCHBOX -- Sandviches etc
			or ID == TF_WEAPON_BUFF_ITEM -- Banners
			or ID == TF_WEAPON_PDA_SPY or ID == TF_WEAPON_PDA_SPY_BUILD -- Sapper
			or ID == TF_WEAPON_JAR or ID == TF_WEAPON_JAR_GAS or ID == TF_WEAPON_JAR_MILK
			or ID == TF_WEAPON_ROCKETPACK -- Thermal Thruster
			or ID == TF_WEAPON_LASER_POINTER -- Wrangler
			or ID == TF_WEAPON_CLEAVER -- Cleaver
	end

	---@param ID number
	---@param Definition number
	---@return boolean is_blast
	local function IsBlastDamage(ID, Definition)
		return ID == TF_WEAPON_ROCKETLAUNCHER -- Rocket launchers
			or ID == TF_WEAPON_PARTICLE_CANNON -- Cow Mangler
			or ID == TF_WEAPON_DIRECTHIT -- Direct hit
			or ID == TF_WEAPON_GRENADELAUNCHER -- Grenade launchers
			or ID == TF_WEAPON_CANNON -- Loose Cannon
			or ID == TF_WEAPON_PIPEBOMBLAUNCHER -- Sticky launchers
	end

	---@param ID number
	---@param Definition number
	---@return boolean is_fire
	local function IsFireDamage(ID, Definition)
		return ID == TF_WEAPON_FLAMETHROWER -- Flamethrowers
			or ID == TF_WEAPON_FLAME_BALL -- Dragon's Fury
			or ID == TF_WEAPON_FLAREGUN -- Flare Guns
			or ID == TF_WEAPON_RAYGUN_REVENGE -- Manmelter
	end

	---@return boolean deals_minicrit_in_air
	function CWeapon:DealsMiniCritInAir()
		-- TODO: improve, maybe misses some special editions like festive or killstreak versions
		local Definition = self:DefinitionIndex()
		return Definition == 127 -- Direct hit
			or Definition == 415 -- Reserve shooter
	end

	---@return ResistanceTypes resist_type
	function CWeapon:DamageType()
		local ID, Definition = self:ID(), self:DefinitionIndex()
		if self:IsMelee() or self:IsMedigun() or self:IsHarmless() then
			return RESIST_TYPES.UNKNOWN
		end

		if self:IsEnforcer() then
			return RESIST_TYPES.UNKNOWN
		end

		if IsBlastDamage(ID, Definition) then
			--Debug("Weapon of ID %d (Definition %d) is considered a blast weapon!", ID, Definition)
			return RESIST_TYPES.BLAST_RESIST
		elseif IsFireDamage(ID, Definition) then
			--Debug("Weapon of ID %d (Definition %d) is considered a fire weapon!", ID, Definition)
			return RESIST_TYPES.FIRE_RESIST
		else
			--Debug("Weapon of ID %d (Definition %d) is considered a weapon!", ID, Definition)
			return RESIST_TYPES.AMMO_RESIST
		end
	end
end

---@class CPlayer
---@field private Entity Entity?
CPlayer = {} do
	CPlayer.__index = CPlayer

	---@type table<Entity, CPlayer>
	local Cache = setmetatable({}, {__mode = "kv"})

	---@param Player AnyEntity
	---@return CPlayer cplayer
	function CPlayer.from(Player)
		local PlayerEntity = ToRaw(Player)

 		DebugAssert(PlayerEntity and PlayerEntity:IsValid(), "CPlayer: Expected valid entity, got %s", type(PlayerEntity))
		DebugAssert(PlayerEntity and PlayerEntity:IsPlayer(), "Expected a player entity")

		return setmetatable({
			Entity = PlayerEntity,
		}, CPlayer)
	end

	---@param UserId integer
	---@return CPlayer? cplayer
	function CPlayer.fromUserId(UserId)
		local Entity = entities.GetByUserID(UserId)

		if Entity and Entity:IsValid() then
			return CPlayer.from(Entity)
		end

		return nil
	end

	---@param Player AnyEntity?
	---@return CPlayer? cplayer
	function CPlayer.fromCached(Player)
		local PlayerEntity = ToRaw(Player)
		if not PlayerEntity then
			return nil
		end

		local Cached = Cache[PlayerEntity]
		if Cached then
			if Cached:IsValid() then
				-- only return if the cached cplayer is valid..
				return Cached
			end

			-- we don't know if its networked.. better not to release
			--Cached:Release()
		end

		local CPlayerObject = CPlayer.from(PlayerEntity)
		Cache[PlayerEntity] = CPlayerObject

		return CPlayerObject
	end

	function CPlayer.clearCache()
		Cache = setmetatable({}, {__mode = "kv"})
	end

	---@param self CPlayer
	local function DebugValidCheck(self)
		if config.debug then
			assert(self:IsValid(), "DEBUG ASSERT: Entity is invalid")
		end
	end

	---@return nil
	function CPlayer:Release()
		if not self.Entity then
			return
		end

		if self.Entity:IsValid() then
			self.Entity:Release()
			self.Entity = nil
		end

		if Cache[self.Entity] then
			Cache[self.Entity] = nil
		end
	end

	---@return CEntity entity
	function CPlayer:ToEntity()
		return CEntity.from(self.Entity)
	end

	--- Returns whether the player is cheating
	---@return boolean cheating
	function CPlayer:IsCheating()
		return self:IsValid() and playerlist.GetPriority(self.Entity) == config.cheater_priority
	end

	---@return boolean cheating
	function CPlayer:IsAlive()
		return self:IsValid() and self.Entity:IsAlive()
	end


	-- CEntity inherits
	CPlayer.Is = CEntity.Is
	CPlayer.Origin = CEntity.Origin
	CPlayer.GetIndex = CEntity.GetIndex
	CPlayer.Raw = CEntity.Raw
	CPlayer.Team = CEntity.Team

	--- Returns the player's max health
	---@return number max_health
	function CPlayer:MaxHealth()
		DebugValidCheck(self)

		return self:IsValid()
			and self.Entity:GetMaxHealth()
			or 0
	end

	--- Returns the player's health in percentage
	---@return number health_percent
	function CPlayer:Health()
		local MaxHealth = self:MaxHealth()

		return MaxHealth ~= 0
			and self.Entity:GetHealth() / MaxHealth
			or 0
	end

	--- Returns whether the player is friends with the user
	---@return boolean friend
	function CPlayer:IsFriend()
		DebugValidCheck(self)
		if not self:IsValid() then
			return false
		end

		local PlayerInfo = client.GetPlayerInfo(self.Entity:GetIndex())
		if not PlayerInfo then
			return false
		end

		return steam.IsFriend(PlayerInfo.SteamID)
	end

	--- Returns whether the player is under the bonk effect
	---@return boolean bonked
	function CPlayer:IsBonked()
		return self:InCond(TFCond_Bonked)
	end

	--- Returns whether the player is scoped in
	---@return boolean bonked
	function CPlayer:IsScoped()
		return self:InCond(TFCond_Zoomed)
	end

	--- Returns whether the player has any debuffs
	---@return boolean vulnerable
	function CPlayer:IsVulnerable()
		return self:InCond(TFCond_OnFire)
			or self:InCond(TFCond_HealingDebuff)
			or self:InCond(TFCond_Bleeding)
			or self:InCond(TFCond_MarkedForDeath)
			or self:InCond(TFCond_Jarated)
	end

	---@return boolean ubered
	function CPlayer:IsUbercharged()
		return self:InCond(TFCond_Ubercharged)
			or self:InCond(TFCond_UberchargedHidden)
			or self:InCond(TFCond_UberchargedOnTakeDamage)
			or self:InCond(TFCond_UberchargedCanteen)
	end

	---@return boolean crit_boosted
	function CPlayer:IsCritBoosted()
		return self.Entity:IsCritBoosted()
		--[[return self:InCond(TFCond_CritMmmph)
			or self:InCond(TFCond_Kritzkrieged)
			or self:InCond(TFCond_CritOnWin)
			or self:InCond(TFCond_CritOnFlagCapture)
			or self:InCond(TFCond_CritOnKill)
			or self:InCond(TFCond_HalloweenCritCandy)
			or self:InCond(TFCond_CritCanteen)
			or self:InCond(TFCond_CritOnFirstBlood)]]
	end

	---@return boolean on_fire
	function CPlayer:IsBurning()
		return self:InCond(TFCond_OnFire)
			or self:InCond(TFCond_BurningPyro)
	end

	---@return boolean is_disguised
	function CPlayer:IsDisguised()
		return self:InCond(TFCond_Disguised)
	end

	---@return boolean is_cloaked
	function CPlayer:IsCloaked()
		return self:InCond(TFCond_Cloaked)
	end


	---@return number
	function CPlayer:Healers()
		return self.Entity:GetPropInt("m_nNumHealers")
	end

	---@param ResistType ResistanceTypes
	---@param Charged boolean?
	function CPlayer:HasResistAgainst(ResistType, Charged)
		local Increment = Charged and 3 or 0
		return (ResistType == 0 and self:InCond(TFCond_SmallBulletResist - Increment))
			or (ResistType == 1 and self:InCond(TFCond_SmallBlastResist - Increment))
			or (ResistType == 2 and self:InCond(TFCond_SmallFireResist - Increment))
	end

	---@return boolean valid
	function CPlayer:IsValid()
		return (self.Entity and self.Entity:IsValid() and self.Entity:IsPlayer())
			or false
	end

	--- Returns whether the player is the specified class
	---@param Class number
	---@return boolean matches_class
	function CPlayer:IsClass(Class)
		DebugValidCheck(self)
		local PlayerClass = self.Entity:GetPropInt("m_PlayerClass", "m_iClass")
		return self:IsValid() and PlayerClass == Class
	end

	--- Returns whether the condition is active
	---@param Condition number
	---@return boolean in_condition
	function CPlayer:InCond(Condition)
		DebugValidCheck(self)
		return self:IsValid() and self.Entity:InCond(Condition)
	end

	--- Returns the currently selected weapon.
	--- If slot is defined, returns the weapon in that slot
	---@param Slot number?
	---@return CWeapon? weapon
	function CPlayer:GetWeapon(Slot)
		DebugValidCheck(self)
		if not self:IsValid() then
			return nil
		end

		if Slot then
			local Weapon = self.Entity:GetPropDataTableEntity("m_hMyWeapons")[Slot]
			if not Weapon or not Weapon:IsValid() or not Weapon:IsWeapon() then
				return nil
			end

			return CWeapon.from(Weapon)
		end

		local Weapon = self.Entity:GetPropEntity("m_hActiveWeapon")
		if not Weapon or not Weapon:IsValid() or not Weapon:IsWeapon() then
			return nil
		end

		return CWeapon.from(Weapon)
	end

	function CPlayer:EntityFlags()
		return self.Entity:GetPropInt("m_fFlags")
	end

	---@return Vector3 shoot_position
	function CPlayer:ShootPosition()
		--[[
		do something else for local player for more accurate result?
		if self.Entity == entities.GetLocalPlayer() then
			
		end
		--]]

		local ViewOffset = self.Entity:GetPropVector("localdata", "m_vecViewOffset[0]")
		if not ViewOffset then
			local Flags = self:EntityFlags()
			ViewOffset = (Flags & FL_DUCKING ~= 0) and Vector3(0, 0, 45) or Vector3(0, 0, 75)
		end

		return self:Origin() + ViewOffset
	end

	---@return EulerAngles view_angle
	function CPlayer:ViewAngles()
		local EyeAngles = self.Entity:GetPropVector("tfnonlocaldata", "m_angEyeAngles[0]")
		return EulerAngles(EyeAngles.x, EyeAngles.y, EyeAngles.z)
	end

	---@return Vector3 obb_center
	function CPlayer:OBBCenter()
		local Mins = self.Entity:GetPropVector("m_Collision", "m_vecMins")
		local Maxs = self.Entity:GetPropVector("m_Collision", "m_vecMaxs")

		return self:Origin() + (Mins + Maxs) * 0.5
	end

	function CPlayer:Velocity()
		-- TODO: read m_vecVelocity[0] if possible?
		return self.Entity:EstimateAbsVelocity()
	end
end

local TR_CUSTOM_FILTER_NO_TEAM_BASED_ENTS = 1
local TR_CUSTOM_FILTER_HIT_TEAM = 2
---@class CTrace
---@field private Trace Trace
---@field Start Vector3
---@field End Vector3
local CTrace = {} do
	CTrace.__index = CTrace

	local Filters = {}
	local FilterIgnore = {
		CBaseAnimating = true,
		CFuncAreaPortalWindow = true,
		CFuncRespawnRoomVisualizer = true, --Couldn't find
		CFuncRespawnRoom = true, --Couldn't find
		CTFMedigunShield = true, --Couldn't find
		CAmmoPack = true,
		CTFDroppedWeapon = true,
		CTFRagdoll = true,
		CTFReviveMarker = true,
		CPasstimeBall = true,
		CTFTauntProp = true, --Couldn't find
		CCaptureFlag = true,
		CTFProjectile_BallOfFire = true,
		CTFRobotDestruction_Robot = true,
		CSniperDot = true,
		CLaserDot = true, --Couldn't find
	}


	---@param TraceLocalPlayer AnyCEntity
	Filters[TR_CUSTOM_FILTER_NO_TEAM_BASED_ENTS] = function(TraceLocalPlayer)
		---@param Entity Entity
		---@param ContentsMask integer
		---@return boolean should_hit
		return function(Entity, ContentsMask)
			if not TraceLocalPlayer or not TraceLocalPlayer:IsValid() or Entity:GetIndex() == TraceLocalPlayer:GetIndex() then
				return false
			end

			local Ent = CEntity.from(Entity)
			if Ent:IsProjectile() then
				return false
			end
			
			local EntClass = Entity:GetClass()
			if FilterIgnore[EntClass] then
				return false
			end

			if EntClass == "CTFPlayer"
				or EntClass == "CObjectSentrygun"
				or EntClass == "CObjectDispenser"
				or EntClass == "CObjectTeleporter"
			then
				return false
			end

			return true
		end
	end

	---@param TraceLocalPlayer AnyCEntity
	Filters[TR_CUSTOM_FILTER_HIT_TEAM] = function(TraceLocalPlayer)
		---@param Entity Entity
		---@param ContentsMask integer
		---@return boolean should_hit
		return function(Entity, ContentsMask)
			if not TraceLocalPlayer or not TraceLocalPlayer:IsValid() or Entity:GetIndex() == TraceLocalPlayer:GetIndex() then
				return false
			end

			local Ent = CEntity.from(Entity)
			if Ent:IsProjectile() then
				return false
			end
			
			local EntClass = Entity:GetClass()
			if FilterIgnore[EntClass] then
				return false
			end

			return true
		end
	end

	---@param Source Vector3
	---@param Destination Vector3
	---@param Mask number?
	---@return Vector3 end
	function CTrace.Line(Source, Destination, Mask)
		local Trace = engine.TraceLine(Source, Destination, Mask or MASK_ALL)
		return Trace.endpos
	end

	---@param Source Vector3
	---@param Destination Vector3
	---@param Mask number?
	---@param Filter number
	---@param LocalPlayer AnyCEntity
	---@return Vector3 end
	function CTrace.FLine(Source, Destination, Mask, Filter, LocalPlayer)
		local Trace = engine.TraceLine(Source, Destination, Mask or MASK_ALL, Filters[Filter](LocalPlayer))
		return Trace.endpos
	end

	---@param Source Vector3
	---@param Destination Vector3
	---@param Mask number?
	---@param Filter number?
	---@param LocalPlayer AnyCEntity
	---@return CTrace trace
	function CTrace.Ray(Source, Destination, Mask, Filter, LocalPlayer)
		local Trace = engine.TraceLine(Source, Destination, Mask or MASK_ALL, Filters[Filter](LocalPlayer))

		return setmetatable({
			Trace = Trace,
			Start = Trace.startpos,
			End = Trace.endpos
		}, CTrace)
	end
	

	---@param Entity AnyEntity?
	---@return boolean visible
	function CTrace:Visible(Entity)
		return self.Trace.fraction >= 1 or
			(Entity ~= nil and self.Trace.entity ~= nil and Entity:Is(self.Trace.entity));
	end
end

local AUTO_CHARGE_BULLET = 1
local AUTO_CHARGE_BLAST = 2
local AUTO_CHARGE_FIRE = 4
local AUTO_CHARGE_CANNOT_UBER = 8
local AUTO_CHARGE_BULLET_INSTANT_KILL = 16
local AUTO_CHARGE_BLAST_INSTANT_KILL = 32
local AUTO_CHARGE_FIRE_INSTANT_KILL = 64
---@class AutoVaccinatorState
---@field Flags number flags
---@field BulletDamage number bullet damage total
---@field BlastDamage number blast damage total
---@field FireDamage number fire damage total
---@field Bullet number bullet danger level
---@field Blast number blast danger level
---@field Fire number fire danger level
---@field OverallBullet number amount of players with this damage type in range, for passive healing resist
---@field OverallBlast number amount of players with this damage type in range, for passive healing resist
---@field OverallFire number amount of players with this damage type in range, for passive healing resist
---@field Burning boolean are we burning?
---@field BlastProjectileNearby number blast projectiles near protected
---@field StickiesNearby number stickies near protected

---@param State AutoVaccinatorState
local function PrintState(State)
	print(string.format("Danger levels: bullet(%d), blast(%d), fire(%d)", State.Bullet, State.Blast, State.Fire))
	print(string.format("Total damage: bullet(%d), blast(%d), fire(%d)", State.BulletDamage, State.BlastDamage, State.FireDamage))
	print(string.format("Players: bullet(%d), blast(%d), fire(%d)", State.OverallBullet, State.OverallBlast, State.OverallFire))
	print(string.format("Blast projectiles(%d), Stickies(%d)", State.BlastProjectileNearby, State.StickiesNearby))
	print(string.format("Burning(%s)", State.Burning))
end

---@param A Vector3
---@param B Vector3
---@return number distance
local function Vector3_Distance(A, B)
	return math.sqrt((B.x - A.x)^2 + (B.y - A.y)^2 + (B.z - A.z)^2)
end

---@param A Vector3
---@param B Vector3
---@return number distance
local function Vector3_DistanceMeters(A, B)
	return Vector3_Distance(A, B) * 0.0254
end

---@param Angle number
---@return number angle
local function NormalizedAngle(Angle)
	if Angle < -180 or Angle > 180 then
		local Normalize = (360 * round(math.abs(Angle / 360))) * (Angle < 0 and 1 or -1)
		Angle = Angle + Normalize
	end

	return Angle
end

---@param ViewAngle EulerAngles
---@param Start Vector3
---@param End Vector3
---@return number fov_delta
local function FovDelta(ViewAngle, Start, End)
	local Forward = ViewAngle:Forward()

	local Direction = Vector3(
		End.x - Start.x,
		End.y - Start.y,
		End.z - Start.z
	)

	Direction:Normalize()
	local Degrees = math.acos(math.min(Forward:Dot(Direction), 1)) * (180 / math.pi) 
	return math.abs(math.max(NormalizedAngle(Degrees), 0))
end

local MASK_BULLET = 0x46004023
local MASK_EXPLOSION = 0x6004003
local MASK_SHOT_HULL = 0x600400B

local LagStates = { Classes = {} }

local GlobalResistUberState, GlobalWantedResistCycle, GlobalReloadHeld, GlobalCurrentResist = -1, -1, false, -1
local GlobalResistCheckPredictionTime, GlobalPreferResist, GlobalForceAttack2 = 0, -1, false
local Vaccinator = {} do
	local function Latency()
		local NetChannel = clientstate.GetNetChannel()
		if not NetChannel then
			return 0.05
		end

		local Outgoing = NetChannel:GetLatency(0) or 0
		local Incoming = NetChannel:GetLatency(1) or 0
		local NetLatency = Outgoing + Incoming

		return math.max(0.01, NetLatency)
	end
	Vaccinator.Latency = Latency

	---@return number unknown_reaction_range
	function Vaccinator.UnknownReactionRange()
		local Ping = math.max(0.1, Latency())
		return Ping > 0 and (Ping * 1000) // 16 or 1
	end

	---@param Protect CPlayer?
	---@param State AutoVaccinatorState
	function Vaccinator.Handle(Protect, State)
		if not Protect or not Protect:IsValid() then
			return
		end

		if Protect:IsBurning() then
			State.Burning = true
		
			if Protect:Health() <= 0.1 then
				State.Fire = State.Fire + 12
				State.Flags = State.Flags | AUTO_CHARGE_FIRE
			end
		end
	end

	---@param Protect CPlayer?
	---@param Player CPlayer?
	---@return boolean should_predict
	function Vaccinator.ShouldPredictPlayers(Protect, Player)
		if not Protect or not Player then
			return false
		end

		if not Player:IsValid() then
			return false
		end

		if Player:IsScoped() and Player:IsCheating() then
			return true
		end

		local Distance = Vector3_DistanceMeters(Protect:Origin(), Player:Origin())
		if Distance > CLOSE_RANGE + 2 then
			-- + 2 is kind of arbitrary.. could maybe change it to + half
			return false
		end

		local Weapon = Player:GetWeapon()
		if not Weapon then
			return false
		end

		if Player:IsClass(TF2_Heavy) and Player:InCond(TFCond_Slowed) then
			if Player:IsUbercharged() or Player:IsCritBoosted()
				or Player:HasResistAgainst(RESIST_TYPES.AMMO_RESIST)
				or Player:HasResistAgainst(RESIST_TYPES.BLAST_RESIST)
				or Player:HasResistAgainst(RESIST_TYPES.FIRE_RESIST)
			then
				return true
			end
		elseif Player:IsClass(TF2_Scout) and Weapon:IsScatterGun() then
			return Distance <= CLOSE_RANGE
		end

		return false
	end

	---@param Entity CEntity
	---@param Protect CPlayer
	---@param Predict boolean
	---@return boolean is_visible
	---@return boolean in_blast_radius
	function Vaccinator.IsVisible(Entity, Protect, Predict)
		if not Entity or not Protect then
			return false, false
		end

		local Ping = math.min(math.max(Latency(), 0.1), 4)
		local InBlastRadius = false

		local PredictedShootPosition = CTrace.FLine(
			Protect:ShootPosition(),
			Protect:ShootPosition() + (Protect:Velocity() * Ping),
			MASK_BULLET,
			TR_CUSTOM_FILTER_NO_TEAM_BASED_ENTS,
			Protect
		)

		if Entity:IsPlayer() then
			local Player = CPlayer.fromCached(Entity)
			if not Player then
				return false, InBlastRadius
			end

			local OtherShootPosition = Predict
				and CTrace.FLine(
					Player:ShootPosition(),
					Player:ShootPosition() + (Player:Velocity() * Ping),
					MASK_BULLET, TR_CUSTOM_FILTER_NO_TEAM_BASED_ENTS,
					Player
				)
				or Player:ShootPosition()

			local Trace = CTrace.Ray(
				Protect:ShootPosition(),
				OtherShootPosition,
				MASK_BULLET,
				TR_CUSTOM_FILTER_NO_TEAM_BASED_ENTS,
				Protect
			)

			if Trace:Visible(Entity) then
				return true, InBlastRadius
			else
				Trace = CTrace.Ray(
					PredictedShootPosition,
					OtherShootPosition,
					MASK_BULLET,
					TR_CUSTOM_FILTER_NO_TEAM_BASED_ENTS,
					Protect
				)
				return Trace:Visible(Entity), InBlastRadius
			end
		else
			if Entity:IsDormant() then
				return false, InBlastRadius
			end

			local PredictedPosition = CTrace.Line(
				Entity:Origin(),
				Entity:Origin() + Entity:EstVelocity() * Ping,
				MASK_ALL
			)

			if Entity:IsSentry() then
				local Trace = CTrace.Ray(
					PredictedShootPosition,
					Entity:OBBCenter(),
					MASK_BULLET,
					TR_CUSTOM_FILTER_NO_TEAM_BASED_ENTS,
					Protect
				)

				if Trace:Visible(Entity) then
					return true, InBlastRadius
				end

				local SentryTarget = Entity:GetSentryTarget()
				if SentryTarget and SentryTarget:Is(Protect) then
					return true, InBlastRadius
				end

				return false, InBlastRadius
			elseif Entity:IsRocket() then
				local Forward = Entity:AbsAngles():Forward()
				local Pos = Forward * Entity:EstVelocity():Length()

				local BlastDistance = 4 -- TODO: Seems to be hard coded, calculate blast distance?
				local Launcher = Entity:GetLauncher()
				if Launcher and Launcher:IsDirectHit()  then
					BlastDistance = 2
				end

				local BlastTrace = CTrace.Ray(
					Entity:Origin(),
					Entity:Origin() + (Pos * 1024),
					MASK_SHOT_HULL,
					TR_CUSTOM_FILTER_HIT_TEAM,
					Entity
				)

				local BlastVisibleTrace = CTrace.Ray(
					BlastTrace.End,
					PredictedShootPosition,
					MASK_EXPLOSION,
					TR_CUSTOM_FILTER_HIT_TEAM,
					Entity
				)
			
				if BlastVisibleTrace:Visible(Protect) then
					InBlastRadius = Vector3_DistanceMeters(PredictedShootPosition, BlastTrace.End) <= BlastDistance
					return true, InBlastRadius
				end
			elseif Entity:IsDemoProjectile() then
				local Trace = CTrace.Ray(
					PredictedShootPosition,
					PredictedPosition,
					MASK_EXPLOSION,
					TR_CUSTOM_FILTER_HIT_TEAM,
					Protect
				)

				if Trace:Visible(Entity) then
					InBlastRadius = Vector3_Distance(Trace.Start, Trace.End) <= 250
					return true, InBlastRadius
				end
			else
				local Trace = CTrace.Ray(
					PredictedShootPosition,
					PredictedPosition,
					MASK_BULLET,
					TR_CUSTOM_FILTER_HIT_TEAM,
					Protect
				)

				if Trace:Visible(Entity) then
					local DeathDistance = Entity:IsArrow()
						and 2
						or CLOSE_RANGE

					InBlastRadius = Vector3_DistanceMeters(PredictedShootPosition, Trace.End) <= DeathDistance
					return true, InBlastRadius
				end
			end
		end

		return false, InBlastRadius
	end

	---@param Player CPlayer
	---@param AttackerPosition Vector3
	---@param VictimPosition Vector3
	---@return number damage
	function Vaccinator.CalculateDamage(Player, AttackerPosition, VictimPosition)
		if not Player or not Player:IsValid() then
			return 0
		end

		local Weapon = Player:GetWeapon()
		if not Weapon then
			return 0
		end

		local Info = Weapon:Info()
		if not Info then
			return 0
		end

		local Damage = Info.damage * Weapon:Raw():AttributeHookFloat("mult_dmg")
		if Player:IsDisguised() then
			Damage = Damage * Weapon:Raw():AttributeHookFloat("mult_dmg_disguised")
		end

		local RandomDamage = Damage * 0.5
		local RandomSpread = 0.10

		local Min, Max =
			0.5 - RandomSpread,
			0.5 + RandomSpread

		local Distance = math.max(1, Vector3_Distance(VictimPosition, AttackerPosition))
		local Center = map(Distance / 512, 0, 2, 1, 0)

		Min = math.max(0, Center - RandomSpread)
		Max = math.min(1, Center + RandomSpread)

		local RandomRange = Min + RandomSpread

		local ID = Weapon:ID()
		if ID == TF_WEAPON_SCATTERGUN or ID == TF_WEAPON_SODA_POPPER or ID == TF_WEAPON_PEP_BRAWLER_BLASTER then
			if RandomRange > 0.5 then
				RandomDamage = RandomDamage * 1.5
			end
		elseif ID == TF_WEAPON_ROCKETLAUNCHER or ID == TF_WEAPON_DIRECTHIT or ID == TF_WEAPON_PARTICLE_CANNON then
			if RandomRange > 0.5 then
				RandomDamage = RandomDamage * 0.5
			end
		elseif ID == TF_WEAPON_PIPEBOMBLAUNCHER or ID == TF_WEAPON_GRENADELAUNCHER or ID == TF_WEAPON_CANNON or ID == TF_WEAPON_STICKBOMB then
			if RandomRange > 0.5 then
				RandomDamage = RandomDamage * 0.2
			end
		end

		local DamageVariance = SimpleSplineRemap(RandomRange, 0, 1, -RandomDamage, RandomDamage)
		Damage = Damage + DamageVariance
		return round(Damage)
	end


	local NotificationCooldown = 0
	---@param State AutoVaccinatorState
	---@param Reason string
	---@param Type ResistanceTypes
	---@param Instant boolean?
	function Vaccinator.ForceUberCharge(State, Reason, Type, Instant)
		if globals.RealTime() - NotificationCooldown >= 1.5 then
			NotificationCooldown = globals.RealTime()
			Notify(string.format("Forced uber charge because of: %s", Reason))
		end

		if Type == RESIST_TYPES.AMMO_RESIST then
			State.Flags = State.Flags | AUTO_CHARGE_BULLET
			if Instant then
				State.Flags = State.Flags | AUTO_CHARGE_BULLET_INSTANT_KILL
			end
		elseif Type == RESIST_TYPES.BLAST_RESIST then
			State.Flags = State.Flags | AUTO_CHARGE_BLAST
			if Instant then
				State.Flags = State.Flags | AUTO_CHARGE_BLAST_INSTANT_KILL
			end
		elseif Type == RESIST_TYPES.FIRE_RESIST then
			State.Flags = State.Flags | AUTO_CHARGE_FIRE
			if Instant then
				State.Flags = State.Flags | AUTO_CHARGE_FIRE_INSTANT_KILL
			end
		end
	end

	--- Calculates danger of entity in relation to Protect
	---@param Protect CPlayer?
	---@param Entity CEntity
	---@param State AutoVaccinatorState
	function Vaccinator.HandleEntity(Protect, Entity, State)
		if not Protect or not Protect:IsValid() then
			return
		end

		if not Entity or not Entity:IsValid() then
			return
		end

		if config.debug then
			local Class = Entity.Entity:GetClass()
			if LagStates.Classes[Class] then
				LagStates.Classes[Class] = LagStates.Classes[Class] + 1
			else
				LagStates.Classes[Class] = 1
			end
		end

		if Entity:Team() == Protect:Team() then
			return
		end

		-- is_fake_projectile -> no launcher / harmless launcher (rocket jumper / base jumper)
		if Entity:IsProjectile() then
			local Launcher = Entity:GetLauncher()
			if Launcher and Launcher:IsHarmless() then
				return
			end
		end

		if Protect:IsUbercharged() or Protect:IsBonked() then
			return
		end

		if gamerules.IsTruceActive() and not Entity:IsRocket() then
			return
		end

		local _Visible = false
		local BlastInRadius = false
		local Distance = Vector3_DistanceMeters(Protect:Origin(), Entity:Origin())

		if Entity:IsRocket() or Entity:IsDemoProjectile() or Entity:IsArrow() or Entity:IsFlameBall() or Entity:IsFlare() then
			local Ping = clamp(Latency(), 0.1, 4)
			local PredictedPosition = CTrace.Line(
				Entity:Origin(),
				Entity:Origin() + (Entity:EstVelocity() * Ping)
			)

			Distance = Vector3_DistanceMeters(Protect:ShootPosition(), PredictedPosition)
		end

		if Entity:IsSentry() and not Protect:IsDisguised() then
			if Protect:HasResistAgainst(RESIST_TYPES.AMMO_RESIST, true) then
				return
			end

			if Distance > 27 then
				return
			end

			if Entity:Building() or Entity:Placing() or Entity:Sapped() or Entity:Disabled() then
				return
			end

			State.OverallBullet = State.OverallBullet + 1
			
			_Visible, BlastInRadius = Vaccinator.IsVisible(Entity, Protect, false)
			if not _Visible then
				return
			end

			State.Bullet = State.Bullet + 1

			local Builder = Entity:BuildingOwner()
			-- TODO: Builder can be non players, gotta change that in BuildingOwner
			if Builder and Builder:InCond(TFCond_Buffed) then
				State.Bullet = State.Bullet + 6
			end

			if not Entity:IsMiniSentry() then
				Vaccinator.ForceUberCharge(State, "Sentry visible", RESIST_TYPES.AMMO_RESIST, true)
			else
				State.Bullet = State.Bullet + 16
				if Protect:IsVulnerable() then
					State.Bullet = State.Bullet + 8
				end
			end

			return
		elseif Entity:IsArrow() then
			if Protect:HasResistAgainst(RESIST_TYPES.AMMO_RESIST, true) then
				return
			end

			if Distance > MAX_PROJECTILE_DIST then
				return
			end

			State.OverallBullet = State.OverallBullet + 1
			
			_Visible, BlastInRadius = Vaccinator.IsVisible(Entity, Protect, false)
			if not _Visible then
				return
			end

			State.Bullet = State.Bullet + 2

			local Ping = clamp(Latency(), 0, 4)
			local PredictedShootPosition = CTrace.Line(Protect:ShootPosition(), Protect:ShootPosition() + (Protect:Velocity() * Ping))
			local PredictedPos = CTrace.Line(Entity:Origin(), Entity:Origin() + (Entity:EstVelocity() * Ping))
			local DistanceToHead = math.abs(PredictedShootPosition.z - PredictedPos.z)

			if BlastInRadius then
				State.Bullet = State.Bullet + 16
				if DistanceToHead <= 18 and Entity:IsHuntsmanArrow() or Entity:IsCritical() or Entity:IsDeflected() then
					Vaccinator.ForceUberCharge(State, "Arrow lethal", RESIST_TYPES.AMMO_RESIST, true)
				end
			end

			if Protect:IsVulnerable() then
				State.Bullet = State.Bullet + 6
			end

			return
		elseif Entity:IsFlare() then
			if Protect:HasResistAgainst(RESIST_TYPES.FIRE_RESIST, true) then
				return
			end

			if Distance > MAX_PROJECTILE_DIST then
				return
			end

			State.OverallFire = State.OverallFire + 1
			
			_Visible, BlastInRadius = Vaccinator.IsVisible(Entity, Protect, false)
			if not _Visible then
				return
			end

			State.Fire = State.Fire + 1
			if Protect:IsBurning() or Entity:IsCritical() or Entity:IsDeflected() then
				--if Protect:Health() < 0.9 then
				if (Protect:Health() * Protect:MaxHealth()) <= 90 then
					Vaccinator.ForceUberCharge(State, "Flare lethal", RESIST_TYPES.FIRE_RESIST, true)
				else
					State.Fire = State.Fire + (BlastInRadius and 6 or 4)
				end
			else
				State.Fire = State.Fire + (BlastInRadius and 4 or 2)
			end

			if Protect:IsVulnerable() then
				State.Fire = State.Fire + 2
			end

			return
		elseif Entity:IsFireSpell() then
			if Protect:HasResistAgainst(RESIST_TYPES.FIRE_RESIST, true) then
				return
			end

			if Distance > MAX_PROJECTILE_DIST then
				return
			end

			State.Fire = State.Fire + 1
			
			_Visible, BlastInRadius = Vaccinator.IsVisible(Entity, Protect, false)
			if not _Visible then
				return
			end

			State.Fire = State.Fire + 1
			if BlastInRadius then
				Vaccinator.ForceUberCharge(State, "Firespell", RESIST_TYPES.FIRE_RESIST, true)
			else
				State.Fire = State.Fire + 8
			end

			if Protect:IsVulnerable() then
				State.Fire = State.Fire + 4
			end

			return
		elseif Entity:IsFlameBall() then
			if Protect:HasResistAgainst(RESIST_TYPES.FIRE_RESIST, true) then
				return
			end

			if Distance > MAX_PROJECTILE_DIST then
				return
			end

			State.OverallFire = State.OverallFire + 1
			
			_Visible, BlastInRadius = Vaccinator.IsVisible(Entity, Protect, false)
			if not _Visible then
				return
			end

			State.Fire = State.Fire + 1
			if Protect:IsBurning() or Protect:IsVulnerable() then
				Vaccinator.ForceUberCharge(State, "Flameball lethal", RESIST_TYPES.BLAST_RESIST, true)
			else
				State.Fire = State.Fire + 1
			end

			return
		elseif Entity:IsRocket() then
			if Protect:HasResistAgainst(RESIST_TYPES.BLAST_RESIST, true) then
				return
			end

			if Distance > MAX_PROJECTILE_DIST then
				return
			end

			State.OverallBlast = State.OverallBlast + 1
			
			_Visible, BlastInRadius = Vaccinator.IsVisible(Entity, Protect, false)
			if not _Visible then
				return
			end

			State.Blast = State.Blast + 1
			if Entity:IsCritical() or Entity:IsDeflected() then
				if BlastInRadius then
					Vaccinator.ForceUberCharge(State, "Critical rocket with in blast radius", RESIST_TYPES.BLAST_RESIST, true)
				else
					State.Blast = State.Blast + 8
				end
			else
				State.Blast = State.Blast + (BlastInRadius and 12 or 8)
			end

			if Protect:IsVulnerable() then
				State.Blast = State.Blast + 4
			end

			if BlastInRadius then
				State.BlastProjectileNearby = State.BlastProjectileNearby + 1
			end

			return
		elseif Entity:IsDemoProjectile() then
			if Protect:HasResistAgainst(RESIST_TYPES.BLAST_RESIST, true) then
				return
			end

			if Distance > MAX_PROJECTILE_DIST then
				return
			end

			State.OverallBlast = State.OverallBlast + 1
			
			_Visible, BlastInRadius = Vaccinator.IsVisible(Entity, Protect, false)
			if not _Visible then
				return
			end

			State.Blast = State.Blast + 1
			if Entity:IsCritical() or Entity:IsDeflected() then
				if BlastInRadius then
					Vaccinator.ForceUberCharge(State, "Critical pill/sticky with in blast radius", RESIST_TYPES.BLAST_RESIST, true)
				else
					State.Blast = State.Blast + (Distance <= CLOSE_RANGE and 12 or 6)
				end
			else
				if Entity:IsStickyBomb() then
					State.Blast = State.Blast + (Distance <= CLOSE_RANGE and 8 or 4)
					if BlastInRadius then
						State.StickiesNearby = State.StickiesNearby + 1
						if State.StickiesNearby >= 2 then
							Vaccinator.ForceUberCharge(State, "2+ stickies with in blast radius", RESIST_TYPES.BLAST_RESIST, true)
						end
					end
				else
					State.Blast = State.Blast + 8
				end
			end

			if BlastInRadius then
				State.BlastProjectileNearby = State.BlastProjectileNearby + 1
			end

			return
		end

		print("Entity passed through, no checks")
	end

	--- Calculates danger of player in relation to Protect
	---@param Protect CPlayer?
	---@param Player CPlayer
	---@param State AutoVaccinatorState
	function Vaccinator.HandlePlayer(Protect, Player, State)
		if not Protect or not Protect:IsValid() then
			return
		end

		if not Player or not Player:IsValid() then
			return
		end

		if Protect:Team() == Player:Team() then
			return
		end

		--local LocalPlayer = CPlayer.fromCached(entities.GetLocalPlayer())
		--if not LocalPlayer then
		--	return
		--end

		if gamerules.IsTruceActive() --[[or gamerules.IsManagedMatchEnded()]] then
			return
		end

		-- Ignore taunting players
		if Player:InCond(TFCond_Taunting) then
			return
		end

		-- Handle bonked
		if not config.filters.bonked and Player:IsBonked() or Player:IsCloaked() then
			return
		end

		-- Handle friends
		if not config.filters.friends and Player:IsFriend() then
			return
		end

		-- RijiN lag compensates for the bonked timer
		-- but we can't do that because of no way
		-- of hooking into CTFPlayerShared.OnConditionAdded
		if Protect:IsUbercharged() or Protect:IsBonked() then
			return
		end

		local Weapon = Player:GetWeapon()
		if not Weapon then
			return
		end

		local Info = Weapon:Info()

		local Distance = Vector3_DistanceMeters(Protect:Origin(), Player:Origin())
		if Distance > MAX_PLAYER_DIST and not Weapon:IsSniperRifle() then
			return
		end

		local FOV = FovDelta(Player:ViewAngles(), Player:ShootPosition(), Protect:ShootPosition())
		local PredictPlayers = Vaccinator.ShouldPredictPlayers(Protect, Player)

		local Cheating = Player:IsCheating()
		local InDangerRange = Distance < Vaccinator.UnknownReactionRange()

		local ResistType = Weapon:DamageType()
		if ResistType == RESIST_TYPES.UNKNOWN then
			return
		end

		if ResistType == RESIST_TYPES.AMMO_RESIST then
			if Protect:HasResistAgainst(RESIST_TYPES.AMMO_RESIST, true) then
				return
			end

			if not Player:IsClass(TF2_Medic) then
				State.OverallBullet = State.OverallBullet + 1
			end

			if not Vaccinator.IsVisible(Player:ToEntity(), Protect, PredictPlayers) and Distance >= CLOSE_RANGE - 2 then
				return
			end

			local ExpectedDamage = Vaccinator.CalculateDamage(Player, Player:ShootPosition(), Protect:OBBCenter()) * Info.bulletsPerShot
			State.BulletDamage = State.BulletDamage + ExpectedDamage

			State.Bullet = State.Bullet + 1
			State.Bullet = State.Bullet + Player:Healers()

			if ExpectedDamage > 0 then
				ExpectedDamage = ExpectedDamage / 2
				if (ExpectedDamage > (Protect:Health() * Protect:MaxHealth())) then
					Vaccinator.ForceUberCharge(State, "Expected damage exceeds protected health", RESIST_TYPES.AMMO_RESIST)
				end
			end

			if Weapon:IsHuntsman() and InDangerRange then
				Vaccinator.ForceUberCharge(State, "Huntsman player too close", RESIST_TYPES.AMMO_RESIST)
			end

			if Player:IsUbercharged() or Player:InCond(TFCond_MegaHeal) then
				State.Bullet = State.Bullet + 6
			end

			if Protect:IsVulnerable() then
				State.Bullet = State.Bullet + 2
			end

			if Player:IsCritBoosted() then
				State.Bullet = State.Bullet + 6
			elseif Player:InCond(TFCond_Buffed) or (Protect:EntityFlags() & FL_ONGROUND == 0 and Weapon:DealsMiniCritInAir()) then
				State.Bullet = State.Bullet + 4
			end

			if Weapon:IsShotgun() or Weapon:IsScatterGun() or (Weapon:IsMinigun() and Player:InCond(TFCond_Slowed)) then
				if Distance <= CLOSE_RANGE then
					if Cheating then
						Vaccinator.ForceUberCharge(State, "Cheater in lethal DT range", RESIST_TYPES.AMMO_RESIST)
					else
						Vaccinator.ForceUberCharge(
							State,
							Weapon:IsMinigun() and "Minigun in lethal range" or "Shotgun in lethal range",
							RESIST_TYPES.AMMO_RESIST
						)
					end
				end
			end

			if Player:IsClass(TF2_Heavy) then
				State.Bullet = State.Bullet + (Cheating and 10 or 2)

				if Player:InCond(TFCond_Slowed) then
					State.Bullet = State.Bullet + 2
				end

				if Player:HasResistAgainst(RESIST_TYPES.AMMO_RESIST) then
					State.Bullet = State.Bullet + 2
				end

				if Player:HasResistAgainst(RESIST_TYPES.AMMO_RESIST, true)
					or Player:HasResistAgainst(RESIST_TYPES.BLAST_RESIST, true)
					or Player:HasResistAgainst(RESIST_TYPES.FIRE_RESIST, true)
					or Player:IsUbercharged()
				then
					Vaccinator.ForceUberCharge(State, "Heavy nearby that is uber/vaccinator charged", RESIST_TYPES.AMMO_RESIST)
				elseif Player:HasResistAgainst(RESIST_TYPES.AMMO_RESIST) then
					-- TODO: RijiN does the resist check twice, so it adds 6 if the heavy has passive bullet resist
					State.Bullet = State.Bullet + 4
				end

				if Distance <= CLOSE_RANGE or Protect:IsBurning() then
					if Weapon:DefinitionIndex() == 811 or Weapon:DefinitionIndex() == 832 then 
						State.Bullet = State.Bullet + 10
					end
				end
			elseif Player:IsClass(TF2_Sniper) then
				if Weapon:CanHeadshot() then
					local IsScoped = Player:InCond(TFCond_Zoomed)
					if Weapon:ID() == TF_WEAPON_SNIPERRIFLE_CLASSIC and not IsScoped then
						IsScoped = Player:InCond(TFCond_Slowed)
					end
					
					if IsScoped and FOV < 8 or Cheating then
						Vaccinator.ForceUberCharge(
							State,
							Cheating and "A cheating sniper was visible" or "Sniper aiming near head",
							RESIST_TYPES.AMMO_RESIST
						)
					end
				end
			end
		elseif ResistType == RESIST_TYPES.BLAST_RESIST then
			if Protect:HasResistAgainst(RESIST_TYPES.BLAST_RESIST, true) then
				return
			end

			if Weapon:IsHarmless() then
				return
			end

			State.OverallBlast = State.OverallBlast + 1
			if not Vaccinator.IsVisible(Player:ToEntity(), Protect, false) then
				return
			end

			State.BlastDamage = State.BlastDamage + Vaccinator.CalculateDamage(Player, Player:ShootPosition(), Protect:OBBCenter())
			if InDangerRange then
				Vaccinator.ForceUberCharge(State, "Projectile weapon too close", RESIST_TYPES.BLAST_RESIST)
			end

			State.Blast = State.Blast + 1
			State.Blast = State.Blast + Player:Healers()
			if Player:IsUbercharged() or Player:InCond(TFCond_MegaHeal) then
				Vaccinator.ForceUberCharge(State, "Player nearby that is uber/quickfix charged", RESIST_TYPES.BLAST_RESIST, true)
			end

			if Protect:IsVulnerable() then
				State.Blast = State.Blast + 2
			end

			if Player:IsCritBoosted() then
				State.Blast = State.Blast + 6
			elseif Player:InCond(TFCond_Buffed) or (Protect:EntityFlags() & FL_ONGROUND == 0 and Weapon:DealsMiniCritInAir()) then
				State.Blast = State.Blast + 4
			end

			if Weapon:IsDirectHit() then
				State.Blast = State.Blast + 1
			end
		elseif ResistType == RESIST_TYPES.FIRE_RESIST then
			if Protect:HasResistAgainst(RESIST_TYPES.FIRE_RESIST, true) then
				return
			end

			State.OverallFire = State.OverallFire + 1
			if not Vaccinator.IsVisible(Player:ToEntity(), Protect, false) then
				return
			end

			State.FireDamage = State.FireDamage + Vaccinator.CalculateDamage(Player, Player:ShootPosition(), Protect:OBBCenter())
			State.Fire = State.Fire + 1
			State.Fire = State.Fire + Player:Healers()

			if Player:IsUbercharged() or Player:InCond(TFCond_MegaHeal) then
				-- TODO instant kill flag?
				Vaccinator.ForceUberCharge(State, "Player nearby that is uber/quickfix charged", RESIST_TYPES.FIRE_RESIST, true)
			end

			if Protect:IsVulnerable() then
				State.Fire = State.Fire + 2
			end

			if Player:IsCritBoosted() then
				if Distance <= 12 then
					-- TODO instant kill flag?
					Vaccinator.ForceUberCharge(State, "Crit boosted pyro nearby", RESIST_TYPES.FIRE_RESIST, true)
				else
					State.Fire = State.Fire + 2
				end
			elseif Player:InCond(TFCond_Buffed) then
				State.Fire = State.Fire + 2
			end
			
			if Weapon:IsFlamethrower() and Distance <= CLOSE_RANGE then
				State.Fire = State.Fire + 12
			end
		end
	end

	---@param HealingTarget CPlayer?
	---@return number uber_cost
	function Vaccinator.CalculateUberCost(HealingTarget)
		if config.passive then
			return MAGIC_THREAT_VALUE
		end
		
		local Cost = UBER_COST
		local LocalPlayer = CPlayer.fromCached(entities.GetLocalPlayer())
		if not LocalPlayer then
			return Cost
		end

		if LocalPlayer:IsVulnerable() then
			Cost = Cost * 0.9
		end

		local HP = clamp(LocalPlayer:Health(), 0, 1)
		if HP > 0 then
			Cost = Cost * HP
		end

		if HealingTarget and HealingTarget:IsValid() then
			if HealingTarget:IsVulnerable() then
				Cost = Cost * 0.9
			end

			local HealingHP = clamp(HealingTarget:Health(), 0, 1)
			if HealingHP > 0 then
				Cost = Cost * HealingHP
			end
		end

		return clamp(Cost, 12, UBER_COST)
	end

	---@param Resist ResistanceTypes
	function Vaccinator.SetWantedResist(Resist)
		GlobalWantedResistCycle = Resist
	end

	---@param Resist ResistanceTypes
	---@return boolean is_wanted_cycle
	function Vaccinator.IsWantedCycle(Resist)
		local LocalPlayer = CPlayer.fromCached(entities.GetLocalPlayer())
		if not LocalPlayer then
			return false
		end

		local Weapon = LocalPlayer:GetWeapon()
		if not Weapon then
			return false
		end

		if not Weapon:IsVaccinator() then
			return false
		end

		local ResistType = Weapon:ResistType()
		if ResistType == nil then
			return false
		end

		return ResistType == Resist
	end

	---@param UserCmd UserCmd
	---@param HealingTarget CPlayer?
	---@param State AutoVaccinatorState
	function Vaccinator.ProcessData(UserCmd, HealingTarget, State)
		if not State then
			return
		end

		local Resist = -1
		local UberCost = Vaccinator.CalculateUberCost(HealingTarget)

		if State.BlastProjectileNearby >= PROJECTILE_DANGER then
			State.Blast = State.Blast + 4
		end

		local BlockBullet, BlockBlast, BlockFire = false, false, false
		local BlockCount = 0

		if config.disallow.bullet then
			State.OverallBullet = -MAGIC_THREAT_VALUE
			State.Bullet = -MAGIC_THREAT_VALUE
			BlockCount = BlockCount + 1
		end

		if config.disallow.blast then
			State.OverallBlast = -MAGIC_THREAT_VALUE
			State.Blast = -MAGIC_THREAT_VALUE
			BlockCount = BlockCount + 1
		end

		if config.disallow.fire then
			State.OverallFire = -MAGIC_THREAT_VALUE
			State.Fire = -MAGIC_THREAT_VALUE
			BlockCount = BlockCount + 1
		end

		if BlockCount == 3 then
			Notify("Everything is blocked, can't pop anything")
		end

		local SingleChargeMode = BlockCount == 2

		if State.Flags > 0 then
			if not config.passive then
				if State.Flags & AUTO_CHARGE_BULLET ~= 0 and not BlockBullet then
					State.Bullet = State.Bullet + MAGIC_THREAT_VALUE
				elseif State.Flags & AUTO_CHARGE_BLAST ~= 0 and not BlockBlast then
					State.Blast = State.Blast + MAGIC_THREAT_VALUE
				elseif State.Flags & AUTO_CHARGE_FIRE ~= 0 and not BlockFire then
					State.Fire = State.Fire + MAGIC_THREAT_VALUE
				end
			else
				if State.Flags & AUTO_CHARGE_BULLET_INSTANT_KILL ~= 0 and not BlockBullet then
					Resist = RESIST_TYPES.AMMO_RESIST
				elseif State.Flags & AUTO_CHARGE_BLAST_INSTANT_KILL ~= 0 and not BlockBlast then
					Resist = RESIST_TYPES.BLAST_RESIST
				elseif State.Flags & AUTO_CHARGE_FIRE_INSTANT_KILL ~= 0 and not BlockFire then
					Resist = RESIST_TYPES.FIRE_RESIST
				end
			end
		end

		if State.Bullet > 1 then
			local Multiplier = clamp(config.sensitivity.bullet, 0.01, 2)
			State.Bullet = math.max(clamp(round(State.Bullet * Multiplier), 1, MAGIC_THREAT_VALUE), 1)
		end

		if State.Blast > 1 then
			local Multiplier = clamp(config.sensitivity.blast, 0.01, 2)
			State.Blast = math.max(clamp(round(State.Blast * Multiplier), 1, MAGIC_THREAT_VALUE), 1)
		end

		if State.Fire > 1 then
			local Multiplier = clamp(config.sensitivity.fire, 0.01, 2)
			State.Fire = math.max(clamp(round(State.Fire * Multiplier), 1, MAGIC_THREAT_VALUE), 1)
		end

		if not SingleChargeMode then
			local Equal = BlockCount == 0 and (State.Bullet == State.Blast and State.Blast == State.Fire)
			if not Equal then
				Equal = (BlockBullet and State.Blast == State.Fire)
					or (BlockBlast and State.Bullet == State.Fire)
					or (BlockFire and State.Bullet == State.Blast)
			end

			if Equal then
				if State.Burning and not BlockFire then
					State.Fire = State.Fire + 1
				else
					if config.passive_resistance == "Bullet" and not BlockBullet then
						State.Bullet = State.Bullet + 1
					elseif config.passive_resistance == "Blast" and not BlockBlast then
						State.Blast = State.Blast + 1
					elseif config.passive_resistance == "Fire" and not BlockFire then
						State.Fire = State.Fire + 1
					else
						if State.OverallBullet > State.OverallBlast and State.OverallBullet > State.OverallFire and not BlockBullet then
							State.Bullet = State.Bullet + 1
						elseif State.OverallBlast > State.OverallBullet and State.OverallBlast > State.OverallFire and not BlockBlast then
							State.Blast = State.Blast + 1
						elseif State.OverallFire > State.OverallBullet and State.OverallFire > State.OverallBlast and not BlockFire then
							State.Fire = State.Fire + 1
						end
					end
				end
			end
		end

		if not config.passive then
			if State.Bullet > State.Blast and State.Bullet > State.Fire and not BlockBullet then
				Resist = RESIST_TYPES.AMMO_RESIST
			elseif State.Blast > State.Bullet and State.Blast > State.Fire and not BlockBlast then
				Resist = RESIST_TYPES.BLAST_RESIST
			elseif State.Fire > State.Bullet and State.Fire > State.Blast and not BlockFire then
				Resist = RESIST_TYPES.FIRE_RESIST
			else
				return
			end
		end

		local Ubercharge = false
		if GlobalResistUberState == -1 and Resist ~= -1 then
			if config.passive
				or Resist == RESIST_TYPES.AMMO_RESIST and State.Bullet >= UberCost
				or Resist == RESIST_TYPES.BLAST_RESIST and State.Blast >= UberCost
				or Resist == RESIST_TYPES.FIRE_RESIST and State.Fire >= UberCost
			then
				GlobalResistUberState = Resist
				Ubercharge = true
			end
		else
			Ubercharge = true
			Resist = GlobalResistUberState
		end

		if State.Flags & AUTO_CHARGE_CANNOT_UBER ~= 0 then
			GlobalResistUberState = -1
			Ubercharge = false
		end

		Vaccinator.SetWantedResist(Resist)
		if not Vaccinator.IsWantedCycle(Resist) then
			if not config.passive then
				UserCmd:SetButtons(UserCmd:GetButtons() & ~IN_ATTACK2)
			end
		else
			if Ubercharge then
				UserCmd:SetButtons(UserCmd:GetButtons() | IN_ATTACK2)
			end

			GlobalResistUberState = -1
		end
	end

	---@param UserCmd UserCmd
	function Vaccinator.HandleAttack2(UserCmd)
		local LocalPlayer = CPlayer.fromCached(entities.GetLocalPlayer())
		if not LocalPlayer then
			return
		end

		local Weapon = LocalPlayer:GetWeapon()
		if not Weapon then
			return
		end
	
		if not Weapon:IsVaccinator() then
			return
		end

		if not GlobalForceAttack2 then
			return
		end

		if GlobalPreferResist < 0 or GlobalPreferResist > 2 then
			return
		end

		Vaccinator.SetWantedResist(GlobalPreferResist)
		if Vaccinator.IsWantedCycle(GlobalPreferResist) then
			UserCmd:SetButtons(UserCmd:GetButtons() | IN_ATTACK2)
			GlobalForceAttack2 = false
		end
	end

	---@param UserCmd UserCmd
	function Vaccinator.PerformCycle(UserCmd)
		if GlobalWantedResistCycle < 0 or GlobalWantedResistCycle > 2 then
			return
		end
	
		local LocalPlayer = CPlayer.fromCached(entities.GetLocalPlayer())
		if not LocalPlayer then
			return
		end

		local Weapon = LocalPlayer:GetWeapon()
		if not Weapon then
			return
		end
	
		if not Weapon:IsVaccinator() then
			Vaccinator.SetWantedResist(-1)
			GlobalReloadHeld = false
			return
		end

		local CurrentResistType = Weapon:ResistType()
		if CurrentResistType ~= GlobalWantedResistCycle then
			if GlobalReloadHeld then
				UserCmd:SetButtons(UserCmd:GetButtons() & ~IN_RELOAD)
			else
				UserCmd:SetButtons(UserCmd:GetButtons() | IN_RELOAD)
				GlobalCurrentResist = (CurrentResistType + 1) % 3
				Weapon:SetResistType(GlobalCurrentResist)
				GlobalResistCheckPredictionTime = os.clock() + Vaccinator.Latency() + 0.15
			end

			UserCmd:SetButtons(UserCmd:GetButtons() & ~IN_ATTACK2)
			GlobalReloadHeld = not GlobalReloadHeld
		else
			if GlobalReloadHeld then
				UserCmd:SetButtons(UserCmd:GetButtons() & ~IN_RELOAD)
			end
			GlobalReloadHeld = false
			Vaccinator.SetWantedResist(-1)
		end
	end

	local PersistentReload = false
	---@param UserCmd UserCmd
	---@return boolean
	function Vaccinator.ProcessManualChargeCycle(UserCmd)
		if config.passive then
			return false
		end

		if UserCmd:GetButtons() & IN_RELOAD ~= 0 then
			if not PersistentReload then
				ManualCharge = (ManualCharge + 1) % 3
				local NewCharge = ManualCharge == 0
					and "Bullet"
					or ManualCharge == 1
					and "Blast"
					or "Fire"
				Notify("Switched manual charge to %s", NewCharge)
				engine.PlaySound("weapons\\vaccinator_toggle.wav")

				PersistentReload = true
				return true
			end

			return false
		else
			PersistentReload = false
		end

		return false
	end

	---@param Protect CPlayer?
	---@param UserCmd UserCmd
	---@return boolean shouldnt_process_data
	function Vaccinator.ProcessManualCharge(Protect, UserCmd)
		if UserCmd:GetButtons() & IN_ATTACK2 == 0 or config.passive then
			return false
		end

		if not Protect or not Protect:IsValid() then
			return false
		end

		local LocalPlayer = CPlayer.fromCached(entities.GetLocalPlayer())
		if not LocalPlayer then
			return false
		end

		local Weapon = LocalPlayer:GetWeapon()
		if not Weapon then
			return false
		end

		if not Weapon:IsMedigun() or not Weapon:IsVaccinator() or Weapon:Charges() <= 0 then
			return false
		end

		if not config.manual_charge then
			UserCmd:SetButtons(UserCmd:GetButtons() & ~IN_ATTACK2)
		end

		local Resist = ManualCharge
		Vaccinator.SetWantedResist(Resist)
		return true
	end
end

local IgnoreClasses = {
	CRopeKeyframe = true,
	CSprite = true,
	CLightGlow = true,
	CSceneEntity = true,
	CTFRagdoll = true,
	CDynamicProp = true,
	CTFWearable = true,
	CFuncOccluder = true,
	CBeam = true,
	CFuncRespawnRoomVisualizer = true,
	CTFDroppedWeapon = true,
}
local CombatClasses = {
	CObjectSentrygun = true,
	CTFProjectile_Rocket = true,
	CTFProjectile_SentryRocket = true,
	CTFGrenadePipebombProjectile = true,
	CTFProjectile_Arrow = true,
	CTFProjectile_Flare = true,
	CTFProjectile_SpellFireball = true,
	CTFProjectile_BallOfFire = true,
	CTFProjectile_HealingBolt = true,
	CTFProjectile_EnergyBall = true,
	CTFProjectile_SpellMeteorShower = true
}
--- Runs auto vaccinator logic
---@param UserCmd UserCmd
local function RunAutoVaccinator(UserCmd)
	if not config.enabled then
		return
	end

	local SignonState = clientstate.GetClientSignonState()
	if SignonState ~= E_SignonState.SIGNONSTATE_FULL then
		Debug("SignonState ~= E_SignonState.SIGNONSTATE_FULL")
		-- SIGNONSTATE_FULL: we are fully connected; first non-delta packet received
		return
	end

	local LocalPlayer = CPlayer.fromCached(entities.GetLocalPlayer())
	if not LocalPlayer then
		return
	end

	local OriginalButtons = UserCmd:GetButtons()

	if not LocalPlayer:IsClass(TF2_Medic) then
		return
	end

	local Weapon = LocalPlayer:GetWeapon()
	if not Weapon or not Weapon:IsVaccinator() then
		return
	end

	---@type AutoVaccinatorState
	local State = {
		Flags = 0,
		Bullet = 1, Blast = 1, Fire = 1,
		BulletDamage = 0, BlastDamage = 0, FireDamage = 0,
		OverallBullet = 0, OverallBlast = 0, OverallFire = 0,
		BlastProjectileNearby = 0, StickiesNearby = 0,
		Burning = false
	}

	local VaccinatorCharges = Weapon:Charges()
	if VaccinatorCharges == 0 then
		--return
		State.Flags = State.Flags | AUTO_CHARGE_CANNOT_UBER
	end

	Vaccinator.ProcessManualChargeCycle(UserCmd)
	if not config.passive then
		UserCmd:SetButtons(OriginalButtons & ~IN_RELOAD)
	end

	local HealingTarget = CPlayer.fromCached(Weapon:HealingTarget())
	LagStates.Classes = {}

	Vaccinator.Handle(LocalPlayer, State)
	Vaccinator.Handle(HealingTarget, State)

	local Players = entities.FindByClass("CTFPlayer")
	for _, Player in ipairs(Players) do
		if Player:IsAlive() and not Player:IsDormant() then
			local CPlayerEnt = CPlayer.fromCached(Player)
			if not CPlayerEnt then
				goto continue
			end

			Vaccinator.HandlePlayer(LocalPlayer, CPlayerEnt, State)
			if HealingTarget then
				Vaccinator.HandlePlayer(HealingTarget, CPlayerEnt, State)
			end
		end

		::continue::
	end

	for Index = 1, entities.GetHighestEntityIndex() do
		local Entity = entities.GetByIndex(Index)
		if not Entity or not Entity:IsValid() then
			goto continue
		end

		local Class = Entity:GetClass()
		if not CombatClasses[Class] then
			goto continue
		end
		
		if Entity:IsDormant() then
			goto continue
		end
		
		local CEnt = CEntity.from(Entity)
		Vaccinator.HandleEntity(LocalPlayer, CEnt, State)
		Vaccinator.HandleEntity(HealingTarget, CEnt, State)

		::continue::
	end

	if config.debug then
		PrintState(State)

		local Classes = {}
		for Class, _ in pairs(LagStates.Classes) do
			table.insert(Classes, Class)
		end

		table.sort(Classes, function(a, b)
			return LagStates.Classes[a] < LagStates.Classes[b]
		end)

		print(string.format("%d Classes scanned", #Classes))
		for _, Class in ipairs(Classes) do
			print(string.format("Class '%s' was checked %d times", Class, LagStates.Classes[Class]))
		end
	end
	
	local ShouldntProcessData = Vaccinator.ProcessManualCharge(LocalPlayer, UserCmd)
	if not ShouldntProcessData then
		ShouldntProcessData = Vaccinator.ProcessManualCharge(HealingTarget, UserCmd)
	end

	if not ShouldntProcessData then
		Vaccinator.ProcessData(UserCmd, HealingTarget, State)
	end
end

local function HandleCycle(UserCmd)
	Vaccinator.HandleAttack2(UserCmd)
	Vaccinator.PerformCycle(UserCmd)
end

local CacheEvents = {
	game_newmap = true,
	client_disconnect = true,
	player_death = true,
	player_spawn = true
}
--- Handles cache clearing on joining servers
---@param Event GameEvent
local function Cache(Event)
	local Name = Event:GetName()
	if CacheEvents[Name] then
		-- Easier to just clear the cache when we join a new server
		-- .. its fine if it's called multiple times, worst that can happen
		-- is that we allocate a few more tables than needed (cleared by gc later on)
		CPlayer.clearCache()
		CWeapon.clearCache()

		GlobalCurrentResist = -1
		GlobalResistCheckPredictionTime = 0
		GlobalReloadHeld = false
		GlobalWantedResistCycle = -1

		GlobalResistUberState = -1
		GlobalForceAttack2 = false
		GlobalPreferResist = -1
	
		Debug("Cleared cache in event '%s'", Name)
	end
end

local HitscanWeapons = {
	[TF_WEAPON_SHOTGUN_PRIMARY] = true,
	[TF_WEAPON_SHOTGUN_SOLDIER] = true,
	[TF_WEAPON_SHOTGUN_HWG] = true,
	[TF_WEAPON_SHOTGUN_PYRO] = true,
	[TF_WEAPON_SCATTERGUN] = true,
	[TF_WEAPON_SNIPERRIFLE] = true,
	[TF_WEAPON_MINIGUN] = true,
	[TF_WEAPON_SMG] = true,
	[TF_WEAPON_PISTOL] = true,
	[TF_WEAPON_PISTOL_SCOUT] = true,
	[TF_WEAPON_REVOLVER] = true,
	[TF_WEAPON_SNIPERRIFLE_CLASSIC] = true,
	[TF_WEAPON_CHARGED_SMG] = true,
	[TF_WEAPON_PEP_BRAWLER_BLASTER] = true,
	[TF_WEAPON_HANDGUN_SCOUT_PRIMARY] = true,
	-- [TF_WEAPON_HANDGUN_SCOUT_SECONDARY] = true,
}
---@param Event GameEvent
local function OnDamage(Event)
	if not config.enabled then
		return
	end

	local LocalPlayer = CPlayer.fromCached(entities.GetLocalPlayer())
	if not LocalPlayer then
		return
	end

	if not LocalPlayer:IsClass(TF2_Medic) then
		return
	end

	local Weapon = LocalPlayer:GetWeapon()
	if not Weapon then
		return
	end

	if not Weapon:IsVaccinator() then
		Vaccinator.SetWantedResist(-1)
		GlobalReloadHeld = false
		return
	end

	local HealingTarget = Weapon:HealingTarget()
	local Attacker = CPlayer.fromUserId(Event:GetInt("attacker"))
	local Victim = CPlayer.fromUserId(Event:GetInt("userid"))

	if not Attacker or not Victim then
		return
	end

	if Attacker:Is(Victim) then
		return
	end

	if not Victim:Is(LocalPlayer) and not Victim:Is(HealingTarget) then
		return
	end

	local Crit = Event:GetInt("crit") == 1
	local MiniCrit = Event:GetInt("minicrit") == 1
	local WeaponId = Event:GetInt("weaponid")

	if (Crit or MiniCrit) and HitscanWeapons[WeaponId] then
		-- In RijiN this is a debug message, but I think it would be more useful as a notification
		Notify("Forcing vaccinator charge use because we're hit by a critical shot!")
		-- TODO: Implement "prefer resist" / force attack 2 on next tick
		-- I guess it isn't important to change resistances, since it's already probably
		-- on the most likely resistance so if we get critted, we can just pop instantly
		GlobalPreferResist = RESIST_TYPES.AMMO_RESIST
		GlobalForceAttack2 = true
	end
end

--- Watches server updates for medic resist type
---@param Stage E_ClientFrameStage
local function Prediction(Stage)
	if Stage ~= E_ClientFrameStage.FRAME_NET_UPDATE_POSTDATAUPDATE_START then
		return
	end

	local LocalPlayer = CPlayer.fromCached(entities.GetLocalPlayer())
	if not LocalPlayer then
		return
	end

	if not LocalPlayer:IsClass(TF2_Medic) then
		return
	end

	local Weapon = LocalPlayer:GetWeapon()
	if not Weapon then
		return
	end

	if not Weapon:IsVaccinator() then
		return
	end

	local NewNetworkedResist = Weapon:ResistType()
	if not NewNetworkedResist or NewNetworkedResist == -1 or GlobalCurrentResist == -1 then
		return
	end

	if NewNetworkedResist == GlobalCurrentResist then
		-- Server confirmed our predicted resistance!
		GlobalResistCheckPredictionTime = 0
		return
	end

	-- While within latency grace period, incoming packets are delayed server snapshots.
	-- Keep our predicted resistance on the client so CreateMove doesn't repeat reload commands.
	if os.clock() < GlobalResistCheckPredictionTime then
		Weapon:SetResistType(GlobalCurrentResist)
		return
	end

	-- Grace period expired and server still differs: genuine prediction error
	--if config.debug then
	Notify("Resist type prediction error, predicted %d, got %d", GlobalCurrentResist, NewNetworkedResist)
	--end

	GlobalCurrentResist = NewNetworkedResist
	Weapon:SetResistType(NewNetworkedResist)
	GlobalResistCheckPredictionTime = 0
end

---@diagnostic disable-next-line
callbacks.Register("CreateMove", function(UserCmd)
	RunAutoVaccinator(UserCmd)
	HandleCycle(UserCmd)
end)

---@diagnostic disable-next-line
callbacks.Register("FireGameEvent", function(Event)
	Cache(Event)

	if Event:GetName() == "player_hurt" then
		OnDamage(Event)
	end
end)

callbacks.Register("FrameStageNotify", Prediction)

---@param From Vector3
---@param To Vector3
local function Line3D(From, To)
	local FromScreenSpace = client.WorldToScreen(From)
	local ToScreenSpace = client.WorldToScreen(To)

	if not FromScreenSpace or not ToScreenSpace then
		return
	end

	draw.Line(
		FromScreenSpace[1], FromScreenSpace[2],
		ToScreenSpace[1], ToScreenSpace[2]
	)
end

local function Text3D(Text, Position)
	local ScreenSpace = client.WorldToScreen(Position)
	if not ScreenSpace then
		return
	end

	draw.Text(ScreenSpace[1], ScreenSpace[2], Text)
end

if config.debug then
	local f = draw.CreateFont("Tahoma", 15, 500, FONTFLAG_CUSTOM | FONTFLAG_ANTIALIAS)
	draw.SetFont(f)
	
	callbacks.Register("Draw", function()
		local LocalPlayer = CPlayer.fromCached(entities.GetLocalPlayer())
		if not LocalPlayer then
			return
		end

		local Weapon = LocalPlayer:GetWeapon()
		if Weapon and Weapon:IsVaccinator() then
			local HealingTarget = CPlayer.fromCached(Weapon:HealingTarget())
			if HealingTarget then
				draw.Color(255, 255, 255, 255)
				Text3D(string.format(
					"bullet(%s), blast(%s), fire(%s)",
					HealingTarget:HasResistAgainst(RESIST_TYPES.AMMO_RESIST, true),
					HealingTarget:HasResistAgainst(RESIST_TYPES.BLAST_RESIST, true),
					HealingTarget:HasResistAgainst(RESIST_TYPES.FIRE_RESIST, true)
				), HealingTarget:ShootPosition() + Vector3(0, 10, 0))
			end
		end
			
		for Index = 1, entities.GetHighestEntityIndex() do
			local Entity = entities.GetByIndex(Index)
			if not Entity or not Entity:IsValid() then
				goto continue
			end
			
			if Entity:IsDormant() then
				goto continue
			end
			
			local CEnt = CEntity.from(Entity)
			if CEnt:IsDemoProjectile() then
				for _, Protect in pairs({CPlayer.fromCached(entities.GetLocalPlayer())}) do
					
					local Ping = math.min(math.max(Vaccinator.Latency(), 0.1), 4)
					local InBlastRadius = false

					local PredictedShootPosition = CTrace.FLine(
						Protect:ShootPosition(),
						Protect:ShootPosition() + (Protect:Velocity() * Ping),
						MASK_BULLET,
						TR_CUSTOM_FILTER_NO_TEAM_BASED_ENTS,
						LocalPlayer
					)

					local PredictedPosition = CTrace.Line(
						CEnt:Origin(),
						CEnt:Origin() + CEnt:EstVelocity() * Ping,
						MASK_ALL
					)

					local Trace = CTrace.Ray(
						PredictedShootPosition,
						PredictedPosition,
						MASK_EXPLOSION,
						TR_CUSTOM_FILTER_HIT_TEAM,
						LocalPlayer
					)

					
					draw.Color(255, 255, 255, 255)
					Text3D(string.format(
						"fraction: %f, hit? %s",
						Trace.Trace.fraction,
						Trace.Trace.entity ~= nil and Trace.Trace.entity:GetClass() or "no"
					), PredictedPosition)
					
					draw.Color(0, 0, 255, 255)
					Line3D(PredictedShootPosition, PredictedPosition)

					draw.Color(255, 255, 255, 255)
					Line3D(PredictedShootPosition, Trace.Trace.endpos)
				end
			end

			::continue::
		end
	end)
end
