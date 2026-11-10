-- Discord: YOUR_DISCORD_USERNAME | Roblox: YOUR_ROBLOX_USERNAME
--[[
	Loads and plays a character's animations by name. One per character, created by
	AnimationLoader. States reach it as ctx.animator.

		animator:Play("M1", { Speed = 2 })
		animator:OnMarker("M1", "Hit", function() ... end)   -- connection is cleaned up on Destroy
		animator:PlaySequence({ "Skill1_Part1", "Skill1_Part2" }, { OnComplete = fn })
		animator:Has("M4")   -- is that animation loaded?
		animator.OnPlay = function(name) end   -- optional: runs whenever an animation is played

	why this exists: combat states were all calling LoadAnimation and keeping their own
	tracks/connections, so every state had its own cleanup and half of them leaked.
	now the tracks live in one place and states only deal with names.
]]

local AnimationHandler = {}
-- methods get looked up on the class table, so every handler shares one copy of the
-- functions instead of each object carrying its own
AnimationHandler.__index = AnimationHandler

function AnimationHandler.new(character)

	-- player characters and NPCs have a Humanoid, but rigs without one (viewmodels, props)
	-- use an AnimationController. both can parent an Animator so i accept either
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:FindFirstChildOfClass("AnimationController")
	if not humanoid then
		-- error and not warn here, a handler with no animator would just break later
		-- somewhere far from the actual cause
		error("No humanoid or AnimationController found in character")
	end
	-- the Animator is what actually loads and replicates animations. it's normally there
	-- already, but a rig built from script might not have one yet so make it
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local self = setmetatable({}, AnimationHandler)

	self.Animator = animator
	self.Character = character
	self.Tracks = {} -- name -> AnimationTrack, so nothing outside has to hold a track
	self.Connections = {} -- marker connections, kept so Destroy can disconnect them all
	self.Sequences = {} -- running sequences, the sequence object itself is the key
	self.Destroyed = false -- checked by the public methods so a late call after death is harmless

	return self
end

function AnimationHandler:Load(name, animationId, options)
	if self.Destroyed then
		warn("[AnimationHandler] Load called after Destroy")
		return nil
	end
	-- loading the same name twice would make a second track for the same animation and
	-- the first one could never be stopped by name anymore, so just reuse it
	if self.Tracks[name] then
		return self.Tracks[name]
	end

	local Options = options or {}

	-- LoadAnimation wants an Animation instance, not a raw id. it's never parented
	-- because the track is the only thing that needs it
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	animation.Name = name

	local track = self.Animator:LoadAnimation(animation)
	-- default is Action because nearly everything loaded here is combat, and it has to
	-- play over the default idle/walk animations
	track.Priority = Options.Priority or Enum.AnimationPriority.Action
	-- "~= nil" and not "if Options.Looped", otherwise Looped = false would be skipped
	-- and i couldn't turn looping off for an animation that was published as looped
	if Options.Looped ~= nil then
		track.Looped = Options.Looped
	end
	self.Tracks[name] = track
	return track
end

function AnimationHandler:Play(name, options)
	if self.Destroyed then return nil end
	-- warn instead of error so a typo in one animation name doesn't kill the whole
	-- combat state that called this
	if not self.Tracks[name] then
		warn("[AnimationHandler] animation not loaded: " .. name)
		return nil
	end

	local track = self.Tracks[name]
	local Options = options or {}
	if Options.StopOthers then
		-- pass name as the exception. if this track is already playing, stopping it and
		-- playing it again in the same frame makes it visibly snap
		self:StopAll(Options.FadeTime or 0.1, name)
	end
	-- 0.1 fade is short enough to feel instant but still blends, 0 pops the pose
	track:Play(Options.FadeTime or 0.1, Options.Weight or 1, Options.Speed or 1)
	if self.OnPlay then
		-- task.spawn so if the hook yields or errors it doesn't hold up or break
		-- whoever called Play
		task.spawn(self.OnPlay, name)
	end
	return track
end

-- lets a state check before playing, so optional animations (like an M4 that only
-- some weapons have) don't spam the "not loaded" warning
function AnimationHandler:Has(name)
	return self.Tracks[name] ~= nil
end

function AnimationHandler:Stop(name, fadeTime)
	local track = self.Tracks[name]
	if not track then
		warn("[AnimationHandler] animation not found: " .. name)
		return
	end
	track:Stop(fadeTime or 0.1)
end

function AnimationHandler:StopAll(fadeTime, except)
	for name, track in pairs(self.Tracks) do
		-- IsPlaying check because calling Stop on a track that isn't playing still fires
		-- its Stopped signal, and that would wrongly advance a sequence
		if name ~= except and track.IsPlaying then
			track:Stop(fadeTime or 0.1)
		end
	end
	self.LoopCanceled = true
end

function AnimationHandler:IsPlaying(name)
	-- returns false and not a warning, asking about a missing animation isn't an error,
	-- the answer is just no
	if not self.Tracks[name] then
		return false
	end
	return self.Tracks[name].IsPlaying
end

-- for swapping weapons: drops every track but keeps the handler alive, so the next
-- weapon's animations can be loaded onto the same character
function AnimationHandler:UnloadAll(fadeTime)
	if self.Destroyed then return end
	for name, track in pairs(self.Tracks) do
		if track.IsPlaying then
			-- 0 by default, the track is about to be destroyed so there's nothing to fade to
			track:Stop(fadeTime or 0)
		end
		-- Destroy and not just dropping the reference, an Animator has a limit on how many
		-- tracks it can hold and they aren't freed just because lua forgot them
		track:Destroy()
		-- setting an existing key to nil while looping is allowed in lua, only adding
		-- new keys mid loop is the problem
		self.Tracks[name] = nil
	end
end

function AnimationHandler:Destroy()
	-- stop first with no fade, the character is going away so a blend would never be seen
	self:StopAll(0)
	for _, track in self.Tracks do
		track:Destroy()
	end
	-- these are the OnMarker connections. their callbacks usually close over the state
	-- that made them, so leaving them connected keeps that state alive in memory
	for _, connection in self.Connections do
		connection:Disconnect()
	end
	-- clear everything so the character and animator can be garbage collected even if
	-- some state still holds a reference to this handler
	self.Tracks = {}
	self.Connections = {}
	self.Animator = nil
	self.Character = nil
	self.Sequences = {}
	-- set last, and the sequence callbacks check it, so a Stopped signal that arrives
	-- after this won't try to play the next step on a dead handler
	self.Destroyed = true
end

function AnimationHandler:OnMarker(name, markerName, callback)
	if self.Destroyed then return nil end
	if not self.Tracks[name] then
		warn("[AnimationHandler] animation not loaded: " .. name)
		return nil
	end
	-- markers are the events placed on the animation timeline, so the hitbox lines up
	-- with the actual swing instead of a task.wait guess that breaks when Speed changes
	local connection = self.Tracks[name]:GetMarkerReachedSignal(markerName):Connect(callback)
	-- stored so Destroy cleans it up, but also returned in case the caller wants to
	-- disconnect earlier than that
	table.insert(self.Connections, connection)
	return connection
end

-- middle ground between Play and StopOthers: only stops tracks that would fight with
-- this one, so an attack replaces other attacks but higher priority stuff keeps playing
function AnimationHandler:PlayExclusive(name, options)
	if self.Destroyed then return nil end
	local Options = options or {}
	if not self.Tracks[name] then
		warn("[AnimationHandler] animation not loaded: " .. name)
		return nil
	end
	local thisTrack = self.Tracks[name]
	for Name, track in self.Tracks do
		-- same or lower priority tracks would blend with this one on the same joints.
		-- anything higher wins over it anyway so there's no reason to stop it.
		-- track ~= thisTrack for the same reason as in Play, no restart snap
		if track.Priority.Value <= thisTrack.Priority.Value and track ~= thisTrack and self:IsPlaying(Name) then
			self:Stop(Name, Options.FadeTime)
		end
	end
	self:Play(name, Options)
	return thisTrack
end

function AnimationHandler:PlaySequence(names, options)
	if self.Destroyed then return nil end
	local Options = options or {}
	-- check the whole list before playing anything, otherwise a bad name in step 3
	-- would leave the skill stuck halfway through
	for _, name in ipairs(names) do
		local track = self.Tracks[name]
		if not track then
			warn("[AnimationHandler] animation not loaded: " .. name)
			return nil
		end
		-- a looped track never fires Stopped by itself, so the sequence would sit on
		-- that step forever
		if track.Looped then
			warn("[AnimationHandler] a looped animation can't be used in a sequence: " .. name)
			return nil
		end
	end

	-- kept as locals in a closure and not as fields on self, so two sequences running
	-- at the same time each have their own state and can't cancel each other
	local cancelled = false
	local connection = nil
	local currentTrack = nil
	local sequence = {}

	-- shared by the cancel path and the normal ending so the cleanup can't drift apart
	local function finish()
		cancelled = true
		if connection then
			connection:Disconnect()
			connection = nil
		end
		self.Sequences[sequence] = nil
	end

	function sequence.Cancel()
		-- makes Cancel safe to call twice, or after the sequence already ended
		if cancelled then return end
		-- grab the track before finish(), and finish() before Stop. stopping fires
		-- Stopped, and if the connection was still alive that would start the next step
		local track = currentTrack
		finish()
		if track and track.IsPlaying then
			track:Stop(Options.FadeTime)
		end
	end

	local function playStep(i)
		local name = names[i]
		currentTrack = self.Tracks[name]

		-- Once and not Connect, each step only needs its own first Stopped. Connect would
		-- leave one connection per step hanging on tracks that get reused later.
		-- hooked up before Play so the signal can't be missed
		connection = currentTrack.Stopped:Once(function()
			-- Once already disconnected itself, so drop the reference or finish() would
			-- call Disconnect on a dead connection
			connection = nil
			-- Stopped also fires when something else stops the track, so check that the
			-- sequence is actually still supposed to be running
			if cancelled or self.Destroyed then return end

			if i < #names then
				playStep(i + 1)
			else
				-- finish before OnComplete, so if the callback starts a new sequence
				-- this one is already out of the way
				finish()
				if Options.OnComplete then
					Options.OnComplete()
				end
			end
		end)

		self:Play(name, Options)
	end

	-- the table is the key so finish() can remove it without searching a list
	self.Sequences[sequence] = true
	playStep(1)
	-- hand back the object so the state that started it can cancel on stun/interrupt
	return sequence
end

return AnimationHandler
