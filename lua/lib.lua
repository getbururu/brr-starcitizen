-- The helpers Star Citizen's rule expressions call as lib.<name> (the
-- manifest's rule_env): what a line means and questions on the game
-- state. t is the tick context. Another module of this mod may add its own
-- helpers while the mod loads:
--   local lib = require("lib")
--   function lib.my_helper(t) ... end

local clock = require("clock")
local state = require("state")

local lib = {}
local S = bururu.state

-- since and secs: times in ns, for rule expressions (clock.lua)
lib.since = clock.since
lib.secs = clock.secs

-- note: the name data/notifications.json gives a notification input's
-- text, "" for a text it does not know
function lib.note(ev)
  return state.note_of(ev and ev.text)
end

-- moment: the line just read made this moment (state.lua decides: your
-- own death, a real change of the armistice zone, ...)
function lib.moment(name)
  return S.moment[name] == true
end

-- is_me: a line's name is the player's handle
lib.is_me = state.is_me

-- my_ship: an id is the ship in your pilot seat. The quantum lines name
-- the ship whose drive is used, so an arrival of a ship you only ride in
-- is not yours.
lib.my_ship = state.my_ship

-- piloting: in the pilot seat of a ship
lib.piloting = state.piloting

-- on_foot: spawned and out of the pilot seat (a passenger counts as on foot)
function lib.on_foot()
  return S.spawned and not state.piloting()
end

-- active: the player is in the game (bururu.facts' active)
function lib.active(t)
  return state.active(t.now)
end

-- downed: incapacitated, until a respawn, a med bed or death
function lib.downed(t)
  return state.downed(t.now)
end

-- dead: your death, until the respawn
function lib.dead()
  return S.dead_at ~= clock.NEVER
end

-- in_tunnel: in a jump tunnel, until the jump drive leaves it
function lib.in_tunnel(t)
  return state.in_tunnel(t.now)
end

local function smooth(x)
  return x * x * (3 - 2 * x)
end

-- tunnel_swell: the level of the swell into the jump tunnel. It rises for
-- half a second and dies away by 2.5 s.
function lib.tunnel_swell(t)
  if not state.in_tunnel(t.now) then
    return 0
  end
  local s = clock.secs(clock.since(t.now, S.tunnel_at))
  if s < 0 or s >= 2.5 then
    return 0
  elseif s < 0.5 then
    return smooth(s / 0.5)
  end
  return 1 - smooth((s - 0.5) / 2)
end

-- tuning: the jump drive tunes; tuning_secs: for how long, in seconds
function lib.tuning(t)
  return S.jump_state == "Tuning" and state.jump_leds(t.now) > 0
end

function lib.tuning_secs(t)
  return clock.secs(clock.since(t.now, S.tuning_at))
end

-- jump_leds: the player LEDs of a jump: the drive's step 1 to 4, 5 in the
-- tunnel, 0 otherwise
function lib.jump_leds(t)
  return state.jump_leds(t.now)
end

-- in_queue: waiting in a hangar queue
function lib.in_queue(t)
  return state.in_queue(t.now)
end

-- low_fuel: in the pilot seat after a Low Fuel notice, for up to 10 minutes
function lib.low_fuel(t)
  return state.low_fuel(t.now)
end

return lib
