-- Desktop battle facade for stock Gen1Recomp hosts that lack mod.battle /
-- src.battle.BattleAPI (those live in the Android Kanto Gear host fork).
-- Provides the same snapshot/submit surface Kanto Gear already uses.

local Battle = {}
Battle.__index = Battle

-- Android Kanto Gear host sets BattleState.isBattleState = true. Stock
-- Gen1Recomp does not; detect via battleKind()/kind instead.
function Battle.isBattleState(state)
  if type(state) ~= "table" then return false end
  if state.isBattleState then return true end
  if type(state.battleKind) == "function" then return true end
  local kind = state.kind
  return kind == "wild" or kind == "trainer" or kind == "safari"
    or kind == "link" or kind == "oldman"
end

local function activeBattle(game)
  local states = game and game.stack and game.stack.states or {}
  local battle
  for i = #states, 1, -1 do
    if Battle.isBattleState(states[i]) then
      battle = states[i]
      break
    end
  end
  return battle, states[#states]
end

local function monName(data, mon)
  local def = mon and data.pokemon[mon.species]
  return (mon and mon.nickname) or (def and def.name) or (mon and mon.species)
end

local function monCopy(data, mon, active)
  if not mon then return nil end
  return {
    species = mon.species,
    name = monName(data, mon),
    level = mon.level,
    hp = mon.hp,
    maxHp = mon.stats and mon.stats.hp or mon.hp,
    status = mon.status,
    active = active and true or false,
  }
end

local function visibleMessage(battle, top)
  local source = top and top.isTextBox and top or top == battle and battle
  local lines = source and source.visibleText and source:visibleText()
  if not lines then return nil end
  local copy = {}
  for i, line in ipairs(lines) do copy[i] = tostring(line) end
  return copy
end

local function battleSignature(game, battle, top)
  if not battle then return "none" end
  local parts = {
    tostring(battle), tostring(top), battle.phase or "",
    tostring(battle.turnCount or 0), tostring(#(battle.queue or {})),
    tostring(battle.current), tostring(battle.msgWaiting),
    tostring(battle.msgPrompt),
    tostring(battle.menuIndex), tostring(battle.mimicIndex),
    tostring(battle.safari and battle.safari.balls),
    tostring(top and top.isTextBox and top.waiting),
    tostring(top and top.isTextBox and top.done),
    table.concat(visibleMessage(battle, top) or {}, "\n"),
  }
  return table.concat(parts, "|")
end

local function loadItemEffects()
  local ok, mod = pcall(require, "src.inventory.ItemEffects")
  if ok then return mod end
end

local function isBattleItem(ItemEffects, id)
  if not ItemEffects then return false end
  if ItemEffects.isBall and ItemEffects.isBall(id) then return true end
  if ItemEffects.isBattleMedicine and ItemEffects.isBattleMedicine(id) then
    return true
  end
  if ItemEffects.healsHP and ItemEffects.healsHP(id) then return true end
  return id == "FULL_HEAL" or id == "FULL_RESTORE" or id == "REVIVE"
    or id == "MAX_REVIVE" or id == "ANTIDOTE" or id == "AWAKENING"
    or id == "BURN_HEAL" or id == "ICE_HEAL" or id == "PARLYZ_HEAL"
end

local function moveCopies(game, battle)
  local out = {}
  local TypeChart, Damage
  pcall(function() TypeChart = require("src.battle.TypeChart") end)
  pcall(function() Damage = require("src.battle.Damage") end)
  for slot, move in ipairs((battle.player and battle.player.curMoves) or {}) do
    local def = game.data.moves[move.id] or {}
    local power = def.power or 0
    local typeMult, hitChance, displayPower
    if TypeChart and power > 0 and move.id ~= "COUNTER" and battle.enemy then
      pcall(function()
        typeMult = TypeChart.effectiveness(def.type, battle.enemy.curTypes or {})
      end)
      displayPower = power
    end
    if Damage and battle.enemy and (power > 0) then
      pcall(function()
        hitChance = battle.enemy.invulnerable and 0
          or Damage.accuracyChance(battle.ruleset, def,
                                   battle.player, battle.enemy)
      end)
    end
    out[#out + 1] = {
      slot = slot,
      id = move.id,
      name = def.name or move.id,
      pp = move.pp,
      maxPp = (def.pp or move.pp or 0)
        + (move.ppUps or 0) * math.floor((def.pp or 0) / 5),
      type = def.type,
      power = def.power,
      accuracy = def.accuracy,
      displayPower = displayPower,
      hitChance = hitChance,
      effectiveness = typeMult,
      disabled = battle.player and battle.player.disabledSlot == slot,
    }
  end
  return out
end

local function itemCopies(game, battle, catchable)
  local ItemEffects = loadItemEffects()
  local out = {}
  for id, count in pairs(game.save.inventory or {}) do
    if count > 0 and isBattleItem(ItemEffects, id) then
      local def = game.data.items[id] or {}
      local ball = ItemEffects and ItemEffects.isBall and ItemEffects.isBall(id)
      local catchChance
      if ball and catchable and battle.catchChance then
        pcall(function() catchChance = battle:catchChance(id) end)
      end
      out[#out + 1] = {
        id = id,
        name = def.name or id,
        count = count,
        ball = ball and true or false,
        needsTarget = not ball,
        catchChance = catchChance,
      }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function mimicCopies(game, battle)
  local out = {}
  for i, move in ipairs(battle.mimicMoves or {}) do
    local def = game.data.moves[move.id] or {}
    out[i] = { index = i, slot = move.slot, id = move.id,
      name = def.name or move.id }
  end
  return out
end

local function pressA(game)
  if game.input and game.input.overlayPressed then
    game.input:overlayPressed("a")
    game.input:overlayReleased("a")
  elseif game.input and game.input.pressQueue then
    table.insert(game.input.pressQueue, "a")
  end
end

local function pressB(game)
  if game.input and game.input.overlayPressed then
    game.input:overlayPressed("b")
    game.input:overlayReleased("b")
  elseif game.input and game.input.pressQueue then
    table.insert(game.input.pressQueue, "b")
  end
end

function Battle.new(getGame)
  return setmetatable({
    getGame = getGame,
    revision = 0,
    signature = nil,
    lastIntentId = nil,
  }, Battle)
end

function Battle:_game()
  return self.getGame and self.getGame() or nil
end

function Battle:_revision(battle, top)
  local game = self:_game()
  local signature = battleSignature(game, battle, top)
  if signature ~= self.signature then
    self.signature = signature
    self.revision = self.revision + 1
  end
  return self.revision
end

function Battle:snapshot()
  local game = self:_game()
  local battle, top = activeBattle(game)
  if not battle then return nil end
  local kind = battle.battleKind and battle:battleKind() or battle.kind or "wild"
  local catchable = kind == "wild" and not battle.ghost and not battle.noCatch
  local supported = kind ~= "oldman" and kind ~= "link"
  local forcedParty = top and top.isPartyMenu and top.battle == battle
                      and top.forceSwitch
  local canAdvance = supported and (
    (top == battle and battle.phase == "messages"
      and battle.current and (battle.msgWaiting or battle.msgPrompt))
    or (top and top.isTextBox and not top.choice
      and (top.waiting or top.done)))
  local prompt = "locked"
  if canAdvance then
    prompt = "advance"
  elseif supported and forcedParty then
    prompt = "party"
  elseif supported and top == battle and kind == "safari"
      and battle.phase == "menu" then
    prompt = "safari"
  elseif supported and top == battle and battle.phase == "mimicSelect" then
    prompt = "mimic"
  elseif supported and top == battle and battle.phase == "menu" then
    prompt = "menu"
  elseif supported and top == battle and battle.phase == "moveSelect" then
    prompt = "moves"
  end

  local party = {}
  for i, mon in ipairs(game.save.party or {}) do
    party[i] = monCopy(game.data, mon, battle.player
      and battle.player.mon == mon)
    party[i].slot = i
  end
  return {
    revision = self:_revision(battle, top),
    kind = kind,
    catchable = catchable,
    prompt = prompt,
    message = visibleMessage(battle, top),
    turn = battle.turnCount or 0,
    player = monCopy(game.data, battle.player and battle.player.mon, true),
    enemy = monCopy(game.data, battle.enemy and battle.enemy.mon, true),
    party = party,
    moves = moveCopies(game, battle),
    items = itemCopies(game, battle, catchable),
    safariBalls = battle.safari and battle.safari.balls or nil,
    mimicMoves = mimicCopies(game, battle),
    mimicIndex = battle.mimicIndex,
  }
end

function Battle:_switch(battle, top, slot)
  local game = self:_game()
  if type(slot) ~= "number" or slot % 1 ~= 0 then
    return nil, "invalid party slot"
  end
  local mon = game.save.party and game.save.party[slot]
  if not mon then return nil, "invalid party slot" end
  if mon.hp <= 0 then return nil, "pokemon has fainted" end
  if battle.player and battle.player.mon == mon then
    return nil, "pokemon is already active"
  end
  if top and top.isPartyMenu and top.battle == battle and top.forceSwitch then
    if top.onSwitch then
      game.stack:pop()
      top.onSwitch(mon)
      return true
    end
  end
  if top ~= battle or battle.phase ~= "menu" then
    return nil, "party choice is not active"
  end
  if battle.resolveSwitch then
    battle:resolveSwitch(mon)
    return true
  end
  return nil, "switch unavailable"
end

function Battle:_useItem(battle, top, itemId, targetSlot)
  local game = self:_game()
  if top ~= battle or battle.phase ~= "menu" then
    return nil, "item choice is not active"
  end
  local ItemEffects = loadItemEffects()
  if not ItemEffects then return nil, "item effects unavailable" end
  local count = game.save.inventory and game.save.inventory[itemId] or 0
  if count <= 0 then return nil, "item is not in the bag" end
  local isBall = ItemEffects.isBall and ItemEffects.isBall(itemId)
  if not isBattleItem(ItemEffects, itemId) then
    return nil, "item is not supported in battle"
  end
  local target
  if not isBall then
    if type(targetSlot) ~= "number" then return nil, "invalid item target" end
    target = game.save.party and game.save.party[targetSlot]
    if not target then return nil, "invalid item target" end
  end
  local result, messages = ItemEffects.use(
    game.data, game.save, itemId, target, battle)
  local Bag = require("src.inventory.Bag")
  if result == "ball" then
    Bag.remove(game.save, itemId, 1)
    battle.phase = "messages"
    battle.afterQueue = "menu"
    if battle.throwBall then battle:throwBall(itemId) end
    return true
  elseif result == "consumed" then
    Bag.remove(game.save, itemId, 1)
    battle.phase = "messages"
    battle.afterQueue = "menu"
    if battle.itemUsed then
      local TextBox = require("src.render.TextBox")
      if messages and #messages > 0 then
        game.stack:push(TextBox.new(game, table.concat(messages, "\f"),
          function() battle:itemUsed({}) end))
      else
        battle:itemUsed({})
      end
    end
    return true
  elseif result == "failed" then
    return true
  end
  return nil, "item cannot be used here"
end

function Battle:submit(intent)
  if type(intent) ~= "table" then return nil, "intent must be a table" end
  if type(intent.id) ~= "number" or intent.id % 1 ~= 0 then
    return nil, "intent id must be an integer"
  end
  if intent.id == self.lastIntentId then return nil, "duplicate intent" end

  local game = self:_game()
  local battle, top = activeBattle(game)
  if not battle then return nil, "no battle" end
  if intent.revision ~= self:_revision(battle, top) then
    return nil, "stale battle context"
  end
  local kind = battle.battleKind and battle:battleKind() or battle.kind
  if kind == "oldman" or kind == "link" then
    return nil, "battle kind is not controllable"
  end

  local ok, err
  if intent.kind == "safari" then
    local action = intent.action
    if kind ~= "safari" or top ~= battle or battle.phase ~= "menu" then
      return nil, "safari menu is not active"
    end
    local index = ({ ball = 1, bait = 2, rock = 3, run = 4 })[action]
    if not index then return nil, "invalid safari action" end
    battle.menuIndex = index
    if battle.safariAction then
      battle:safariAction(action)
      ok = true
    else
      pressA(game)
      ok = true
    end
  elseif intent.kind == "mimic" then
    if top ~= battle or battle.phase ~= "mimicSelect" then
      return nil, "mimic menu is covered"
    end
    local index = intent.index
    if type(index) ~= "number" or not (battle.mimicMoves and battle.mimicMoves[index]) then
      return nil, "invalid mimic slot"
    end
    battle.mimicIndex = index
    pressA(game)
    ok = true
  elseif intent.kind == "advance" then
    local canAdvance = (top == battle and battle.phase == "messages"
      and battle.current and (battle.msgWaiting or battle.msgPrompt))
      or (top and top.isTextBox and not top.choice
        and (top.waiting or top.done))
    if not canAdvance then return nil, "battle text is not waiting" end
    pressA(game)
    ok = true
  elseif intent.kind == "fight" or intent.kind == "run" then
    if top ~= battle or battle.phase ~= "menu" then
      return nil, "battle menu is covered"
    end
    if battle.chooseMenu then
      ok, err = battle:chooseMenu(intent.kind)
    else
      local index = ({ fight = 1, run = 4 })[intent.kind]
      battle.menuIndex = index
      pressA(game)
      ok = true
    end
  elseif intent.kind == "move" then
    if top ~= battle then return nil, "move menu is covered" end
    if battle.chooseMove then
      ok, err = battle:chooseMove(intent.slot)
    else
      if battle.phase ~= "moveSelect" then
        return nil, "move menu is covered"
      end
      local slot = intent.slot
      if type(slot) ~= "number" or not (battle.player and battle.player.curMoves
          and battle.player.curMoves[slot]) then
        return nil, "invalid move slot"
      end
      battle.moveIndex = slot
      pressA(game)
      ok = true
    end
  elseif intent.kind == "back" then
    if top ~= battle then return nil, "move menu is covered" end
    if battle.cancelMove then
      ok, err = battle:cancelMove()
    else
      if battle.phase ~= "moveSelect" then
        return nil, "move menu is covered"
      end
      battle.moveSwapIndex = nil
      battle.phase = "menu"
      ok = true
    end
  elseif intent.kind == "switch" then
    ok, err = self:_switch(battle, top, intent.slot)
  elseif intent.kind == "item" then
    ok, err = self:_useItem(battle, top, intent.item, intent.target)
  else
    return nil, "unknown battle intent"
  end
  if not ok then return nil, err end
  self.lastIntentId = intent.id
  self.signature = nil
  return true
end

return Battle
