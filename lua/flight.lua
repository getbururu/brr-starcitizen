-- The feels that come from the controller itself: in the pilot seat the
-- turn feel, the boost and the fire texture; on foot the heartbeat while
-- downed. They assume Star Citizen's default gamepad layout: the right
-- stick pitches and yaws, L1 with the left stick rolls, L3 boosts, R2 and
-- L2 fire weapon groups 1 and 2.
--
-- The turn feel (turn_feel). In Star Citizen the right stick aims all the
-- time, so only hard turns are felt: a stick that turns the ship past 60%,
-- or, with gyro aim on in the seat, the controller turning faster than
-- 90 deg/s. "push": a soft push when a hard turn starts, changes or ends,
-- and nothing while it holds; "waves": a soft swell about every 2 s during
-- a hard turn; "off". Both glide out. The actuators are smooth around
-- 170 Hz, and a steady tone of any pitch soon grates, so nothing here is
-- steady.
--
-- The state lives in bururu.state.turn (rules read state.turn.<field>):
--   amount   the smoothed hardness of the turn, 0-1
--   vec      the turn with its direction: pitch, yaw, roll, gyro yaw,
--            gyro pitch, each -1..1
--   settled  the same followed slowly; a push is the difference, so a
--            reversal is felt like a start
--   phase    "waves": the swell's phase in cycles (0 is a crest)
--   swell    the swell level, eased so a restart does not click
--   felt     the turn feel's level this tick
-- and bururu.state.fired_at (R2 or L2 last held) and heart_at (the last
-- heartbeat), in ns since the session started.
--
-- Hook point turn@1 (scalars), on every tick the turn feel can play
-- (native haptics, turn_feel not "off"), before it plays:
--   mode    the player's turn_feel, "push" or "waves"; "off" plays nothing
--   feel    the voice: "turn_push" or "turn_waves"
--   level   the turn level 0-1, after the step back under one-shots and
--           firing; the layer plays when > 0
--   swell   what the level is multiplied by (1 for "push")
--   amount  the turn's hardness (read only)
-- A value of the wrong type keeps the mod's own.

local state = require("state")
local clock = require("clock")

local M = {}
local S = bururu.state

-- a stick turns hard past STICK_HARD, fully at 1; the controller past
-- GYRO_HARD deg/s, fully at GYRO_FULL
local STICK_HARD = 0.6
local GYRO_HARD = 90
local GYRO_FULL = 300
local TWO_PI = 6.283185307179586 -- 2*pi
local AXES = 5

-- times in ns
local FIRING = 2e8 -- the turn steps back for 200 ms after a trigger was held
-- the heartbeat while downed: every 1.1 s, slowing to every 1.6 s over a
-- minute
local BEAT_FIRST, BEAT_LAST, BEAT_SLOWING = 1.1e9, 1.6e9, 60e9

local function zeros(n)
  local t = {}
  for i = 1, n do
    t[i] = 0
  end
  return t
end

S.turn = { amount = 0, vec = zeros(AXES), settled = zeros(AXES), phase = 0, swell = 0, felt = 0 }
S.fired_at, S.heart_at = clock.NEVER, clock.NEVER
local T = S.turn

-- the tick's turn with its direction, refilled by turn_vector
local now_vec = zeros(AXES)

-- hard: how hard x turns, with its sign: 0 up to from, 1 at full
local function hard(x, from, full)
  if type(x) ~= "number" then
    return 0
  end
  local a = gomath.max(0, gomath.min(1, (gomath.abs(x) - from) / (full - from)))
  return gomath.copysign(a, x)
end

-- turn_vector: the turn with its direction. gyro: gyro aim moves the ship.
local function turn_vector(p, gyro)
  local v, s = now_vec, p.sticks
  v[1] = hard(s.ry, STICK_HARD, 1)
  v[2] = hard(s.rx, STICK_HARD, 1)
  v[3] = 0
  if p.held.l1 then
    v[3] = hard(s.lx, STICK_HARD, 1)
  end
  v[4], v[5] = 0, 0
  local g = p.gyro_dps
  if gyro and type(g) == "table" then
    v[4] = hard(g[2], GYRO_HARD, GYRO_FULL)
    v[5] = hard(g[1], GYRO_HARD, GYRO_FULL)
  end
  return v
end

-- turn_level: silent when not turning, then felt from the start of a hard
-- turn and rising with it (0.12 at the start, about 0.3 at half, 0.45 at
-- full)
local function turn_level(x)
  if x < 0.02 then
    return 0
  end
  return (0.12 + 0.33 * gomath.pow(x, 0.9)) * gomath.min(1, (x - 0.02) / 0.04)
end

local function moving(list)
  for i = 1, #list do
    if list[i] ~= 0 then
      return true
    end
  end
  return false
end

-- stop: no turn feel; it starts again from rest
local function stop()
  if T.amount > 0 or moving(T.vec) or moving(T.settled) then
    T.amount = 0
    for i = 1, AXES do
      T.vec[i], T.settled[i] = 0, 0
    end
  end
  T.phase, T.swell, T.felt = 0, 0, 0
end

local function number_or(v, default)
  if type(v) == "number" then
    return v
  end
  return default
end

-- turning is the turn feel of a tick in the pilot seat
local function turning(t)
  local p, dt, now = t.pad, t.dt, t.now
  local gyro = t.core.gyro_aim == true and t.settings.gyro_in_seat ~= false and not p.touch and not t.gyro.held
  local v = turn_vector(p, gyro)
  local target = 0
  for i = 1, AXES do
    target = gomath.max(target, gomath.abs(v[i]))
  end
  local tau = 0.15 -- eases in, glides out when the turn ends
  if target < T.amount then
    tau = 0.45
  end
  T.amount = T.amount + (target - T.amount) * (1 - gomath.exp(-dt / tau))
  local change = 0
  for i = 1, AXES do
    T.vec[i] = T.vec[i] + (v[i] - T.vec[i]) * (1 - gomath.exp(-dt / tau))
    T.settled[i] = T.settled[i] + (T.vec[i] - T.settled[i]) * (1 - gomath.exp(-dt / 0.35))
    change = change + (T.vec[i] - T.settled[i]) * (T.vec[i] - T.settled[i])
  end
  -- a swell about every 2.2 s; a turn that starts, or grows much harder in
  -- a trough, brings the next crest forward
  local crest = 0.5 + 0.5 * gomath.cos(TWO_PI * T.phase)
  if T.amount < 0.02 or (target - T.amount > 0.15 and crest < 0.5) then
    T.phase, crest = 0, 1
  end
  T.phase = gomath.mod(T.phase + 0.45 * dt, 1)
  T.swell = T.swell + (crest - T.swell) * (1 - gomath.exp(-dt / 0.1))
  local mode = t.settings.turn_feel
  T.felt = 0
  if not t.native or mode == "off" then
    return
  end
  local felt, swell, voice = T.amount, T.swell, "turn_waves"
  if mode == "push" then
    -- about a second per push, fading out; a small change is not felt
    felt = gomath.max(0, gomath.min(1, 2 * gomath.sqrt(change)) - 0.1) / 0.9
    swell, voice = 1, "turn_push"
  end
  local level = turn_level(felt)
  if level > 0 then
    -- stay under the other feels: step back while a one-shot plays and
    -- while firing
    if t.ducked.turn then
      level = level * 0.4
    elseif clock.since(now, S.fired_at) < FIRING then
      level = level * 0.6
    end
  end
  local h = hook.run("turn@1", { mode = mode, feel = voice, level = level, swell = swell, amount = T.amount })
  if h.mode == "off" then
    return
  end
  level, swell = number_or(h.level, level), number_or(h.swell, swell)
  if type(h.feel) == "string" then
    voice = h.feel
  end
  T.felt = level * swell
  if T.felt > 0 then
    feel.layer("turn", voice, T.felt, { gain = "turn" })
  end
end

-- fire is the fire texture (fire_feel "light"): light ticks while R2 or L2
-- is held in the pilot seat outside an armistice zone. Off by default: the
-- mod cannot see whether the guns fire.
local function fire(t)
  if t.settings.fire_feel ~= "light" or S.armistice then
    return
  end
  if t.pad.r2_held then
    feel.layer("fire_r", "fire_light", 1, { side = "right", gain = "fire_light" })
  end
  if t.pad.l2_held then
    feel.layer("fire_l", "fire_light", 1, { side = "left", gain = "fire_light" })
  end
end

-- heartbeat plays the heartbeat while downed (downed_feel "heartbeat")
local function heartbeat(t)
  if not state.downed(t.now) or t.settings.downed_feel ~= "heartbeat" then
    S.heart_at = clock.NEVER
    return
  end
  local slowing = gomath.min(1, clock.since(t.now, S.downed_at) / BEAT_SLOWING)
  local every = BEAT_FIRST + (BEAT_LAST - BEAT_FIRST) * slowing
  if clock.since(t.now, S.heart_at) >= every then
    S.heart_at = t.now
    feel.play("heartbeat")
  end
end

-- on_pad: when a fire trigger was last held, for the turn's step back
function M.on_pad(t)
  if t.pad.r2_held or t.pad.l2_held then
    S.fired_at = t.now
  end
end

-- tick is the pad part of every active tick: in the pilot seat the turn
-- feel, the boost (L3) and the fire texture; else the turn feel rests.
-- Then the heartbeat.
function M.tick(t)
  if t.pad.ok and state.piloting() then
    turning(t)
    if t.pad.pressed.l3 then
      feel.play("boost")
    end
    fire(t)
  else
    stop()
  end
  heartbeat(t)
end

-- silence is the idle tick's: the turn and the heartbeat start over
function M.silence(t)
  stop()
  S.heart_at = clock.NEVER
end

return M
