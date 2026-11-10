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
AnimationHandler.__index = AnimationHandler

function AnimationHandler.new(character)

	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:FindFirstChildOfClass("AnimationController")
	if not humanoid then
		error("No humanoid or AnimationController found in character")
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local self = setmetatable({}, AnimationHandler)

	self.Animator = animator
	self.Character = character
	self.Tracks = {}
	self.Connections = {}
	self.Sequences = {}
	self.Destroyed = false

	return self
end

function AnimationHandler:Load(name, animationId, options)
	if self.Destroyed then
		warn("[AnimationHandler] Load called after Destroy")
		return nil
	end
	if self.Tracks[name] then
		return self.Tracks[name]
	end

	local Options = options or {}

	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	animation.Name = name

	local track = self.Animator:LoadAnimation(animation)
	track.Priority = Options.Priority or Enum.AnimationPriority.Action
	if Options.Looped ~= nil then
		track.Looped = Options.Looped
	end
	self.Tracks[name] = track
	return track
end

function AnimationHandler:Play(name, options)
	if self.Destroyed then return nil end
	if not self.Tracks[name] then
		warn("[AnimationHandler] animation not loaded: " .. name)
		return nil
	end

	local track = self.Tracks[name]
	local Options = options or {}
	if Options.StopOthers then
		self:StopAll(Options.FadeTime or 0.1, name)
	end
	track:Play(Options.FadeTime or 0.1, Options.Weight or 1, Options.Speed or 1)
	if self.OnPlay then
		task.spawn(self.OnPlay, name)
	end
	return track
end

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
		if name ~= except and track.IsPlaying then
			track:Stop(fadeTime or 0.1)
		end
	end
	self.LoopCanceled = true
end

function AnimationHandler:IsPlaying(name)
	if not self.Tracks[name] then
		return false
	end
	return self.Tracks[name].IsPlaying
end

function AnimationHandler:UnloadAll(fadeTime)
	if self.Destroyed then return end
	for name, track in pairs(self.Tracks) do
		if track.IsPlaying then
			track:Stop(fadeTime or 0)
		end
		track:Destroy()
		self.Tracks[name] = nil
	end
end

function AnimationHandler:Destroy()
	self:StopAll(0)
	for _, track in self.Tracks do
		track:Destroy()
	end
	for _, connection in self.Connections do
		connection:Disconnect()
	end
	self.Tracks = {}
	self.Connections = {}
	self.Animator = nil
	self.Character = nil
	self.Sequences = {}
	self.Destroyed = true
end

function AnimationHandler:OnMarker(name, markerName, callback)
	if self.Destroyed then return nil end
	if not self.Tracks[name] then
		warn("[AnimationHandler] animation not loaded: " .. name)
		return nil
	end
	local connection = self.Tracks[name]:GetMarkerReachedSignal(markerName):Connect(callback)
	table.insert(self.Connections, connection)
	return connection
end

function AnimationHandler:PlayExclusive(name, options)
	if self.Destroyed then return nil end
	local Options = options or {}
	if not self.Tracks[name] then
		warn("[AnimationHandler] animation not loaded: " .. name)
		return nil
	end
	local thisTrack = self.Tracks[name]
	for Name, track in self.Tracks do
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
	for _, name in ipairs(names) do
		local track = self.Tracks[name]
		if not track then
			warn("[AnimationHandler] animation not loaded: " .. name)
			return nil
		end
		if track.Looped then
			warn("[AnimationHandler] a looped animation can't be used in a sequence: " .. name)
			return nil
		end
	end

	local cancelled = false
	local connection = nil
	local currentTrack = nil
	local sequence = {}

	local function finish()
		cancelled = true
		if connection then
			connection:Disconnect()
			connection = nil
		end
		self.Sequences[sequence] = nil
	end

	function sequence.Cancel()
		if cancelled then return end
		local track = currentTrack
		finish()
		if track and track.IsPlaying then
			track:Stop(Options.FadeTime)
		end
	end

	local function playStep(i)
		local name = names[i]
		currentTrack = self.Tracks[name]

		connection = currentTrack.Stopped:Once(function()
			connection = nil
			if cancelled or self.Destroyed then return end

			if i < #names then
				playStep(i + 1)
			else
				finish()
				if Options.OnComplete then
					Options.OnComplete()
				end
			end
		end)

		self:Play(name, Options)
	end

	self.Sequences[sequence] = true
	playStep(1)
	return sequence
end

return AnimationHandler
