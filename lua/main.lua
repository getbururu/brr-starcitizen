-- Star Citizen as a mod: every handler, in the order a tick runs them.
-- Handlers of one kind run in the order they are registered. For each
-- Game.log line, state.lua runs first, then the rules in rules/.

local state  = require("state")  -- what Game.log made of the session, the facts
local flight = require("flight") -- the controller's own feels: turns, boost, fire, the heartbeat
require("lib")                   -- the rule expressions' lib (rule_env)

-- Reading: every Game.log line, the game starting and closing, the
-- sensor's state for the Controller page; then the facts
bururu.on("gamelog:*", state.on_line)
bururu.on("game:started", state.on_game)
bururu.on("game:closed", state.on_game)
bururu.on("sensor:status", state.on_sensor_status)
bururu.facts(state.facts)

-- Idle ticks: the game is not in front, or haptics are off
bururu.on_idle(flight.silence)

-- Driving: the pad, then the feels; the layer rules (the jump swell and
-- pulse) follow on_tick
bururu.on_pad(flight.on_pad)
bururu.on_tick(flight.tick)
