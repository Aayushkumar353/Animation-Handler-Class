-- Discord: YOUR_DISCORD_USERNAME | Roblox: YOUR_ROBLOX_USERNAME
--[[
	Loads and plays a character's animations by name. One per character, created by
	AnimationLoader. States reach it as ctx.animator.

		animator:Play("M1", { Speed = 2 })
		animator:OnMarker("M1", "Hit", function() ... end)   -- connection is cleaned up on Destroy
		animator:PlaySequence({ "Skill1_Part1", "Skill1_Part2" }, { OnComplete = fn })
		animator:Has("M4")   -- is that animation loaded?
		animator.OnPlay = function(name) end   -- optional: runs whenever an animation is played
]]

local AnimationHandler = {}
-- methods are looked up on the class table so every handler shares one copy of them
AnimationHandler.__index = AnimationHandler

function AnimationHandler.new(character)

	-- rigs without a Humanoid (viewmodels, props) use an AnimationController, so accept either
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:FindFirstChildOfClass("AnimationController")
	if not humanoid then
		-- error not warn, a handler with no animator would only break later far from the cause
		error("No humanoid or AnimationController found in character")
	end
	-- rigs built from script might not have an Animator yet, so make one
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local self = setmetatable({}, AnimationHandler)

	self.Animator = animator
	self.Character = character
	self.Tracks = {} -- name -> AnimationTrack, so nothing outside has to hold a track
	self.Connections = {} -- marker connections, kept so Destroy can disconnect them
	self.Sequences = {} -- running sequences, the sequence object itself is the key
	self.Destroyed = false -- makes late calls after death harmless

	return self
end

function AnimationHandler:Load(name, animationId, options)
	if self.Destroyed then
		warn("[AnimationHandler] Load called after Destroy")
		return nil
	end
	-- reuse it, a second track for the same name could never be stopped by name
	if self.Tracks[name] then
		return self.Tracks[name]
	end

	local Options = options or {}

	-- LoadAnimation needs an Animation instance, never parented since only the track uses it
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	animation.Name = name

	local track = self.Animator:LoadAnimation(animation)
	-- Action by default so combat animations play over the default idle/walk
	track.Priority = Options.Priority or Enum.AnimationPriority.Action
	-- "~= nil" so Looped = false still gets applied
	if Options.Looped ~= nil then
		track.Looped = Options.Looped
	end
	self.Tracks[name] = track
	return track
end

function AnimationHandler:Play(name, options)
	if self.Destroyed then return nil end
	-- warn not error, so one typo'd name doesn't kill the state that called this
	if not self.Tracks[name] then
		warn("[AnimationHandler] animation not loaded: " .. name)
		return nil
	end

	local track = self.Tracks[name]
	local Options = options or {}
	if Options.StopOthers then
		-- skip this track, stopping and replaying it in the same frame makes it snap
		self:StopAll(Options.FadeTime or 0.1, name)
	end
	-- 0.1 fade feels instant but still blends, 0 pops the pose
	track:Play(Options.FadeTime or 0.1, Options.Weight or 1, Options.Speed or 1)
	if self.OnPlay then
		-- task.spawn so a hook that yields or errors can't break the caller
		task.spawn(self.OnPlay, name)
	end
	return track
end

-- lets states check for optional animations without triggering the "not loaded" warning
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
		-- Stop on an idle track still fires Stopped, which would wrongly advance a sequence
		if name ~= except and track.IsPlaying then
			track:Stop(fadeTime or 0.1)
		end
	end
	self.LoopCanceled = true
end

function AnimationHandler:IsPlaying(name)
	-- a missing animation isn't an error here, the answer is just no
	if not self.Tracks[name] then
		return false
	end
	return self.Tracks[name].IsPlaying
end

-- for weapon swaps: drops every track but keeps the handler usable
function AnimationHandler:UnloadAll(fadeTime)
	if self.Destroyed then return end
	for name, track in pairs(self.Tracks) do
		if track.IsPlaying then
			-- no fade by default, the track is about to be destroyed anyway
			track:Stop(fadeTime or 0)
		end
		-- Destroy frees the Animator's track slot, dropping the reference doesn't
		track:Destroy()
		-- clearing an existing key mid loop is safe, only adding keys isn't
		self.Tracks[name] = nil
	end
end

function AnimationHandler:Destroy()
	-- no fade, the character is going away so a blend would never be seen
	self:StopAll(0)
	for _, track in self.Tracks do
		track:Destroy()
	end
	-- marker callbacks close over their state, so leaving them connected leaks it
	for _, connection in self.Connections do
		connection:Disconnect()
	end
	-- drop references so the character can be garbage collected
	self.Tracks = {}
	self.Connections = {}
	self.Animator = nil
	self.Character = nil
	self.Sequences = {}
	-- sequence callbacks check this so a late Stopped can't play the next step
	self.Destroyed = true
end

function AnimationHandler:OnMarker(name, markerName, callback)
	if self.Destroyed then return nil end
	if not self.Tracks[name] then
		warn("[AnimationHandler] animation not loaded: " .. name)
		return nil
	end
	-- markers keep hit timing tied to the animation even when Speed changes, unlike task.wait
	local connection = self.Tracks[name]:GetMarkerReachedSignal(markerName):Connect(callback)
	-- stored for Destroy, returned in case the caller wants to disconnect earlier
	table.insert(self.Connections, connection)
	return connection
end

-- only stops tracks that would fight with this one, higher priority ones keep playing
function AnimationHandler:PlayExclusive(name, options)
	if self.Destroyed then return nil end
	local Options = options or {}
	if not self.Tracks[name] then
		warn("[AnimationHandler] animation not loaded: " .. name)
		return nil
	end
	local thisTrack = self.Tracks[name]
	for Name, track in self.Tracks do
		-- same or lower priority would blend with this one, higher wins anyway so leave it
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
	-- validate everything first so a bad name can't leave the skill stuck halfway
	for _, name in ipairs(names) do
		local track = self.Tracks[name]
		if not track then
			warn("[AnimationHandler] animation not loaded: " .. name)
			return nil
		end
		-- a looped track never fires Stopped by itself, the sequence would hang on it
		if track.Looped then
			warn("[AnimationHandler] a looped animation can't be used in a sequence: " .. name)
			return nil
		end
	end

	-- closure locals instead of fields on self, so two sequences can't touch each other's state
	local cancelled = false
	local connection = nil
	local currentTrack = nil
	local sequence = {}

	-- shared by Cancel and the normal ending so cleanup stays in one place
	local function finish()
		cancelled = true
		if connection then
			connection:Disconnect()
			connection = nil
		end
		self.Sequences[sequence] = nil
	end

	function sequence.Cancel()
		-- safe to call twice or after the sequence already ended
		if cancelled then return end
		-- finish() before Stop, otherwise Stopped would fire and start the next step
		local track = currentTrack
		finish()
		if track and track.IsPlaying then
			track:Stop(Options.FadeTime)
		end
	end

	local function playStep(i)
		local name = names[i]
		currentTrack = self.Tracks[name]

		-- Once so no connection is left on a track that gets reused, hooked before Play so it can't be missed
		connection = currentTrack.Stopped:Once(function()
			-- Once already disconnected itself, clear it so finish() doesn't disconnect again
			connection = nil
			-- Stopped also fires when something else stops the track
			if cancelled or self.Destroyed then return end

			if i < #names then
				playStep(i + 1)
			else
				-- finish first so OnComplete can safely start a new sequence
				finish()
				if Options.OnComplete then
					Options.OnComplete()
				end
			end
		end)

		self:Play(name, Options)
	end

	-- the table is the key so finish() can remove it without searching
	self.Sequences[sequence] = true
	playStep(1)
	-- returned so the caller can cancel on stun/interrupt
	return sequence
end

return AnimationHandler
