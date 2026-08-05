-- Detection helpers for stock Gen1Recomp battle states.
-- Run with: lua mod/kanto_gear/tests/battle_bridge_test.lua

local path = arg and arg[0] or "?"
local root = path:match("(.*/)") or "./"
local bridgePath = root .. "../battle_bridge.lua"
local f = assert(io.open(bridgePath, "r"), "missing " .. bridgePath)
local source = f:read("*a")
f:close()

local Battle = assert(load(source, "@battle_bridge.lua"))()

local failures = 0
local function check(cond, msg)
  if cond then
    io.write("ok  - ", msg, "\n")
  else
    failures = failures + 1
    io.write("FAIL - ", msg, "\n")
  end
end

check(not Battle.isBattleState(nil), "nil is not a battle")
check(not Battle.isBattleState({}), "empty table is not a battle")
check(Battle.isBattleState({ isBattleState = true }), "android flag")
check(Battle.isBattleState({ battleKind = function() return "wild" end }),
  "stock battleKind()")
check(Battle.isBattleState({ kind = "wild" }), "stock wild kind")
check(Battle.isBattleState({ kind = "trainer" }), "stock trainer kind")
check(not Battle.isBattleState({ kind = "overworld" }), "overworld rejected")

local api = Battle.new(function()
  return {
    stack = {
      states = {
        { kind = "overworld" },
        { kind = "wild", phase = "menu", turnCount = 1,
          player = { mon = { species = "PIKACHU", level = 5, hp = 19,
            stats = { hp = 19 } }, curMoves = {} },
          enemy = { mon = { species = "EEVEE", level = 5, hp = 20,
            stats = { hp = 20 } } },
          battleKind = function(self) return self.kind end,
        },
      },
    },
    save = { party = {
      { species = "PIKACHU", level = 5, hp = 19, stats = { hp = 19 } },
    }, inventory = {} },
    data = { pokemon = { PIKACHU = { name = "PIKACHU" },
                         EEVEE = { name = "EEVEE" } },
             moves = {}, items = {} },
  }
end)

local snap = api:snapshot()
check(snap ~= nil, "snapshot finds stock battle")
check(snap and snap.prompt == "menu", "menu prompt while phase=menu")
check(snap and snap.kind == "wild", "wild kind")
check(snap and snap.player and snap.player.name == "PIKACHU", "player copy")
check(snap and snap.enemy and snap.enemy.name == "EEVEE", "enemy copy")

if failures > 0 then
  io.write(string.format("%d failure(s)\n", failures))
  os.exit(1)
end
io.write("battle bridge detection tests passed\n")
