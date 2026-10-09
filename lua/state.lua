-- What Game.log made of the session, and the facts. It lives in
-- bururu.state, so rules read it as state.<field>:
--   handle          the player's handle, "" until the log names it
--   in_pu           in the universe, not the main menu
--   spawned         the player's body is in the universe
--   system          "stanton", "pyro", "nyx" or another lower-case name;
--                   "" while unknown
--   ship            the ship in the pilot seat: {vehicle, class, name, id,
--                   since}; id is "" while not piloting
--   armistice       in an armistice zone
--   unmonitored     outside monitored space
--   comms_down      monitored space is down
--   injury          0 none, 1 minor, 2 moderate, 3 major or severe
--   jump_state      the jump drive's state, "" when idle
--   queue_place     the place in a hangar queue, 0 for none
--   weapon_in_hand  something in the player's hand on foot
--   last_vehicle    the ship you last left (seat or death), for a crash
--                   line that comes after it
--   downed_at, dead_at, jump_at, tuning_at, tunnel_at, queue_at,
--   low_fuel_at, left_at
--                   ns since the session started, clock.NEVER for none
--   moment          the moments of the line just read, for the rules
--                   (lib.moment): only live lines make moments
--
-- "Is it me": a line names the local player by handle, and the pilot seat
-- by the ship's id from the control token lines (always the local
-- client's) or from your own quantum target. Lines about other players and
-- other ships change nothing.

local clock = require("clock")

local M = {}
local S = bururu.state

local NEVER = clock.NEVER

-- times in ns
local AFTER_DEATH = 6e9    -- the controller stays active after your death, for the death feel and blink
local ZONE_GAP = 5e9       -- at most one armistice feel in this time: the notice flaps at borders
local JUMP_KEEP = 180e9    -- a jump drive state older than this is forgotten
local TUNNEL_KEEP = 300e9  -- a jump tunnel the log never ends is forgotten
local QUEUE_KEEP = 300e9   -- a hangar queue place
local LOW_FUEL_KEEP = 600e9
local DOWNED_KEEP = 300e9  -- downed without a later line (a revive the log does not show)
local CRASH_LATE = 5e9     -- a crash line this long after you left the ship is still yours

local notes = data.get("notifications")
local states = data.get("states")
local JUMP_STEPS = states.jump_steps

local function set_of(list)
  local set = {}
  for _, s in ipairs(list) do
    set[s] = true
  end
  return set
end

local TUNNEL = set_of(states.tunnel)
local ARRIVED = set_of(states.arrived)
local NOT_SHIPS = states.not_ships

-- the notification prefixes, longest first, so a longer text wins
local PREFIXES = {}
for prefix, name in pairs(notes.prefix) do
  PREFIXES[#PREFIXES + 1] = { prefix = prefix, name = name }
end
table.sort(PREFIXES, function(a, b)
  if #a.prefix ~= #b.prefix then
    return #a.prefix > #b.prefix
  end
  return a.prefix < b.prefix
end)

local function no_ship()
  return { vehicle = "", class = "", name = "", id = "", since = NEVER }
end

S.handle = ""
S.moment = {}

-- leave resets what belongs to one visit of the universe; the handle stays
-- unless forget_handle
local function leave(forget_handle)
  if forget_handle then
    S.handle = ""
  end
  S.in_pu, S.spawned, S.system, S.ship = false, false, "", no_ship()
  S.armistice, S.unmonitored, S.comms_down = false, false, false
  S.injury, S.downed_at, S.dead_at = 0, NEVER, NEVER
  S.jump_state, S.jump_at, S.tuning_at, S.tunnel_at = "", NEVER, NEVER, NEVER
  S.queue_place, S.queue_at, S.low_fuel_at = 0, NEVER, NEVER
  S.weapon_in_hand, S.hand_item = false, ""
  S.zone_felt_at = NEVER
  S.last_vehicle, S.left_at = "", NEVER
end

leave(true)

-- text is a string field of an input, "" when it has none
local function text(ev, key)
  local v = ev[key]
  if type(v) == "string" then
    return v
  end
  return ""
end

-- moment marks a moment of the line just read
local function moment(name)
  S.moment[name] = true
end

-- class_of is a vehicle's class: DRAK_Cutlass_Black_850000000001 gives
-- DRAK_Cutlass_Black
function M.class_of(vehicle)
  return (string.gsub(vehicle, "_%d+$", ""))
end

-- ship_name is a class in words, without the maker's code:
-- DRAK_Cutlass_Black gives "Cutlass Black"
function M.ship_name(class)
  local parts = {}
  for p in string.gmatch(class, "[^_]+") do
    parts[#parts + 1] = p
  end
  if #parts > 1 and string.match(parts[1], "^%u+$") then
    table.remove(parts, 1)
  end
  return table.concat(parts, " ")
end

-- system_name is a system in words: "stanton" gives "Stanton"
function M.system_name(s)
  return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

-- strip_badges leaves out the badges language packs put in front of a
-- notification, such as [BP] or <EM4>
local function strip_badges(s)
  local before
  repeat
    before = s
    s = string.gsub(s, "^%s*%b[]%s*", "", 1)
    s = string.gsub(s, "^%s*%b<>%s*", "", 1)
  until s == before
  return s
end

-- note_of is the name data/notifications.json gives a notification text,
-- "" for one it does not know
function M.note_of(s)
  if type(s) ~= "string" then
    return ""
  end
  s = strip_badges(s)
  for _, p in ipairs(PREFIXES) do
    if kit.has_prefix(s, p.prefix) then
      return p.name
    end
  end
  return ""
end

-- the "is it me" tests
function M.is_me(name)
  return S.handle ~= "" and name == S.handle
end

function M.piloting()
  return S.ship.id ~= ""
end

function M.my_ship(id)
  return S.ship.id ~= "" and id == S.ship.id
end

-- is_ship: a vehicle name from a control token or quantum line is a ship
-- you can fly (data/states.json's not_ships)
function M.is_ship(vehicle)
  if vehicle == "" then
    return false
  end
  local low = kit.lower(vehicle)
  for _, word in ipairs(NOT_SHIPS) do
    if kit.contains(low, word) then
      return false
    end
  end
  return true
end

-- take_seat: you pilot this ship from now on
local function take_seat(vehicle, id, now)
  local class = M.class_of(vehicle)
  S.ship = { vehicle = vehicle, class = class, name = M.ship_name(class), id = id, since = now }
  S.queue_place, S.weapon_in_hand, S.hand_item = 0, false, ""
end

-- leave_seat: out of the pilot seat; the ship is kept for a crash line that
-- comes a moment later
local function leave_seat(now)
  if S.ship.vehicle ~= "" then
    S.last_vehicle, S.left_at = S.ship.vehicle, now
  end
  S.ship, S.low_fuel_at = no_ship(), NEVER
end

-- my_crash: the vehicle of a crash line is the ship you pilot, or the one
-- you left a moment ago
local function my_crash(vehicle, now)
  if vehicle == "" then
    return false
  end
  return vehicle == S.ship.vehicle
      or (vehicle == S.last_vehicle and clock.since(now, S.left_at) < CRASH_LATE)
end

-- the times that run out
function M.downed(now)
  return S.downed_at ~= NEVER and clock.since(now, S.downed_at) < DOWNED_KEEP
end

function M.in_tunnel(now)
  return S.tunnel_at ~= NEVER and clock.since(now, S.tunnel_at) < TUNNEL_KEEP
end

-- jump_leds: how many player LEDs the jump lights: the drive's step, 5 in
-- the tunnel, 0 otherwise
function M.jump_leds(now)
  if M.in_tunnel(now) then
    return 5
  elseif S.jump_state ~= "" and clock.since(now, S.jump_at) < JUMP_KEEP then
    return JUMP_STEPS[S.jump_state] or 0
  end
  return 0
end

function M.in_queue(now)
  return S.queue_place > 0 and clock.since(now, S.queue_at) < QUEUE_KEEP
end

function M.low_fuel(now)
  return M.piloting() and S.low_fuel_at ~= NEVER and clock.since(now, S.low_fuel_at) < LOW_FUEL_KEEP
end

-- active: in the universe and spawned, and for a few seconds after your
-- death, so the death feel and blink play out. The controller rests in the
-- main menu, in loading screens before the first spawn and on the respawn
-- screen.
function M.active(now)
  return S.in_pu and (S.spawned or (S.dead_at ~= NEVER and clock.since(now, S.dead_at) < AFTER_DEATH))
end

-- an armistice notice: a feel only on a real change, and at most one in
-- ZONE_GAP, since the notice flaps at a zone's border
local function zone(inside, live, now)
  if S.armistice == inside then
    return
  end
  S.armistice = inside
  if live and clock.since(now, S.zone_felt_at) >= ZONE_GAP then
    S.zone_felt_at = now
    if inside then
      moment("zone_in")
    else
      moment("zone_out")
    end
  end
end

local function injured(k)
  return function()
    S.injury = gomath.max(S.injury, k)
  end
end

-- what each known notification does to the state
local on_note = {
  armistice_in = function(ev, live, now) zone(true, live, now) end,
  armistice_out = function(ev, live, now) zone(false, live, now) end,
  monitored_in = function() S.unmonitored = false end,
  monitored_out = function() S.unmonitored = true end,
  comms_down = function() S.comms_down = true end,
  comms_back = function() S.comms_down = false end,
  hangar_queue = function(ev, live, now)
    local place = tonumber(string.match(strip_badges(text(ev, "text")), notes.queue_place) or "")
    S.queue_place, S.queue_at = place or 1, now
  end,
  hangar_ready = function() S.queue_place = 0 end,
  low_fuel = function(ev, live, now) S.low_fuel_at = now end,
  -- downed: the Incapacitated notice, or emergency services on their way;
  -- after your death they change nothing
  downed = function(ev, live, now)
    if not M.downed(now) and S.dead_at == NEVER then
      S.downed_at = now
    end
  end,
  injury_1 = injured(1),
  injury_2 = injured(2),
  injury_3 = injured(3),
}

-- what each line rule of sensors.json does to the state; the rules not
-- listed here (qt_arrived, platform, stowing, mission_end, shop, attacked,
-- join_pu) change nothing, and their rules check what they need themselves
local on_line = {
  login = function(ev)
    if text(ev, "handle") ~= "" then
      S.handle = ev.handle
    end
  end,
  nickname = function(ev)
    if S.handle == "" then
      S.handle = text(ev, "handle")
    end
  end,
  -- in the universe, and spawned unless a death waits for its respawn: the
  -- first spawn comes a moment later, and the controller should not wait
  -- for a spawn line that a build might not write
  in_universe = function()
    S.in_pu = true
    if S.dead_at == NEVER then
      S.spawned = true
    end
  end,
  spawned = function(ev, live, now)
    local after_death = S.dead_at ~= NEVER or M.downed(now)
    S.in_pu, S.spawned = true, true
    if after_death then
      S.injury, S.dead_at, S.downed_at = 0, NEVER, NEVER
      if live then
        moment("respawned")
      end
    end
  end,
  -- a loading screen names the system; a jump still going on is over
  loading_done = function(ev)
    S.system = kit.lower(text(ev, "system"))
    S.jump_state, S.jump_at, S.tuning_at, S.tunnel_at = "", NEVER, NEVER, NEVER
  end,
  -- the system from a zone or location name, while it is not known: before
  -- the loading screen names it, and after a jump
  system_hint = function(ev)
    if S.system == "" then
      S.system = kit.lower(text(ev, "a") .. text(ev, "b") .. text(ev, "c") .. text(ev, "d") .. text(ev, "e"))
    end
  end,
  disconnected = function() leave(false) end,
  quit = function() leave(false) end,
  crash = function() leave(false) end,

  seat_in = function(ev, live, now)
    local vehicle = text(ev, "vehicle")
    if not M.is_ship(vehicle) then
      return
    end
    take_seat(vehicle, text(ev, "id"), now)
    if live then
      moment("seat_in")
    end
  end,
  -- only the seat you hold: a release of another ship's token is not yours
  seat_out = function(ev, live, now)
    if not M.my_ship(text(ev, "id")) then
      return
    end
    leave_seat(now)
    if live then
      moment("seat_out")
    end
  end,
  -- only the player who picks a quantum target writes this line, so it
  -- names the ship you fly. Some builds do not log taking the pilot seat;
  -- then this is where the mod learns your ship.
  qt_target = function(ev, live, now)
    local vehicle = text(ev, "vehicle")
    if M.is_ship(vehicle) and not M.my_ship(text(ev, "id")) then
      take_seat(vehicle, text(ev, "id"), now)
    end
  end,

  -- the jump drive's steps, then the tunnel: the drive's tunnel states
  -- start it, and any other state ends it; Exiting or Idle is an arrival
  jump_drive = function(ev, live, now)
    local st = text(ev, "state")
    if TUNNEL[st] then
      if S.tunnel_at == NEVER then
        S.tunnel_at = now
      end
      S.jump_state, S.jump_at = st, now
      return
    end
    if S.tunnel_at ~= NEVER then
      if ARRIVED[st] then
        -- another system: the next line that names one tells which
        S.system = ""
        if live and M.in_tunnel(now) then
          moment("jump_arrived")
        end
      end
      S.tunnel_at = NEVER
    end
    if st == "Idle" then
      S.jump_state = ""
      return
    elseif st == S.jump_state then
      return
    end
    S.jump_state, S.jump_at = st, now
    if st == "Tuning" then
      S.tuning_at = now
    end
    if live and JUMP_STEPS[st] then
      moment("jump_step")
    end
  end,

  -- your death: the actor is you, or, while the handle is unknown, it is
  -- thrown out of the ship you pilot
  dead = function(ev, live, now)
    local me = M.is_me(text(ev, "actor")) or (S.handle == "" and M.my_ship(text(ev, "zone_id")))
    if not me then
      return
    end
    leave_seat(now)
    S.dead_at, S.spawned, S.downed_at = now, false, NEVER
    S.weapon_in_hand, S.hand_item = false, ""
    if live then
      moment("died")
    end
  end,
  -- a fatal collision of the ship you fly (PlayerPilot 1); the line may
  -- come just after the game took you out of the seat
  collision = function(ev, live, now)
    if live and text(ev, "pilot") == "1" and my_crash(text(ev, "vehicle"), now) then
      moment("crash")
    end
  end,
  med_bed = function(ev, live)
    if not M.is_me(text(ev, "actor")) then
      return
    end
    S.injury, S.downed_at = 0, NEVER
    if live then
      moment("healed")
    end
  end,
  -- something in your hand: an item put on a hand port; the same item on
  -- another port is put away
  attachment = function(ev)
    if not M.is_me(text(ev, "player")) then
      return
    end
    local item = text(ev, "item")
    if kit.contains(kit.lower(text(ev, "port")), "hand") then
      S.weapon_in_hand, S.hand_item = true, item
    elseif item == S.hand_item then
      S.weapon_in_hand, S.hand_item = false, ""
    end
  end,

  notification = function(ev, live, now)
    local apply = on_note[M.note_of(ev.text)]
    if apply then
      apply(ev, live, now)
    end
  end,
}

-- the state@1 hook point: after each line that changed the state, a copy
-- for add-ons (read only: what they change is dropped)
local function state_hook(ev)
  hook.run("state@1", {
    input = ev.input, live = ev.live, at = ev.at,
    in_pu = S.in_pu, spawned = S.spawned, system = S.system, ship = S.ship.class,
    armistice = S.armistice, unmonitored = S.unmonitored, comms_down = S.comms_down,
    injury = S.injury, downed = M.downed(ev.at), dead = S.dead_at ~= NEVER,
    jump_state = S.jump_state, in_tunnel = M.in_tunnel(ev.at),
    queue_place = S.queue_place, weapon_in_hand = S.weapon_in_hand,
  })
end

local PREFIX = "gamelog:"

-- on_line takes every Game.log input. Lines read while catching up at
-- start (live false) rebuild the state and make no moments.
function M.on_line(ev)
  S.moment = {}
  local apply = on_line[string.sub(text(ev, "input"), #PREFIX + 1)]
  if apply then
    apply(ev, ev.live, ev.at)
    state_hook(ev)
  end
end

-- on_game: the game started or closed; a new Game.log starts a new session
function M.on_game(ev)
  leave(true)
end

-- on_sensor_status sets the Controller page's item: Game.log found
function M.on_sensor_status(ev)
  if text(ev, "id") ~= "gamelog" then
    return
  end
  local st = text(ev, "state")
  if st == "ok" then
    setup.item("log", "ok")
  elseif st == "unavailable" then
    setup.item("log", "warn", "Star Citizen's folder is not known yet. Start the game, or set its folder on the Settings page.")
  elseif st == "error" then
    setup.item("log", "fail", text(ev, "text"))
  else
    setup.item("log", "warn", text(ev, "text"))
  end
end

-- the Home card's facts, sent when they change
local sent = {}
local INJURY = { [0] = "None", "Minor", "Moderate", "Major" }

local function fact(id, value)
  if sent[id] ~= value then
    sent[id] = value
    status.fact(id, value)
  end
end

local function live_facts()
  if M.piloting() then
    fact("ship", S.ship.name)
  else
    fact("ship", "None")
  end
  if S.system ~= "" then
    fact("system", M.system_name(S.system))
  else
    fact("system", "Unknown")
  end
  fact("injury", INJURY[S.injury] or "None")
end

-- context is a short description of the situation, for the window and the
-- log
function M.context(now)
  if not S.in_pu then
    return "In the main menu"
  end
  local where = ""
  if S.system ~= "" then
    where = " in " .. M.system_name(S.system)
  end
  if S.dead_at ~= NEVER then
    return "Waiting to respawn"
  elseif not S.spawned then
    return "Loading"
  elseif M.downed(now) then
    return "Downed" .. where
  elseif M.piloting() then
    local a = "a "
    if string.match(S.ship.name, "^[AEIOU]") then
      a = "an "
    end
    return "Piloting " .. a .. S.ship.name .. where
  end
  return "On foot" .. where
end

-- facts ends the reading: active, menu and context. Menu holds gyro aim in
-- the main menu, and in the pilot seat with gyro_in_seat off.
function M.facts(t)
  live_facts()
  local menu = not S.in_pu or (M.piloting() and t.settings.gyro_in_seat == false)
  return { active = M.active(t.now), menu = menu, context = M.context(t.now) }
end

return M
