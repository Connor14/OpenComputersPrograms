--[[
  Branch mining program for OpenComputers robots.

  This program is designed to dig out branches, in a fashion that allows
  players to easily navigate the dug out tunnels. The primary concern was
  not the performance of the mining, only a good detection rate, and nice
  tunnels. Suggested upgrades for this are the geolyzer and inventory
  controller upgrade, and depending on your world gen (ravines?) a hover
  upgrade might be necessary. The rest is up to you (chunkloading, more
  inventory, battery upgrades).

  By Sangar, 2015

  This program is licensed under the MIT license.
  http://opensource.org/licenses/mit-license.php
]]

local component = require("component")
local computer = require("computer")
local robot = require("robot")
local shell = require("shell")
local sides = require("sides")
local args, options = shell.parse(...)

--[[ Config ]]-----------------------------------------------------------------

local wallThickness = 2

-- Every how many blocks to dig a side shaft. The default makes for a
-- two wide wall between tunnels, making sure we don't miss anything.
local shaftInterval = 3

-- Max recursion level for mining ore veins. We abort early because we
-- assume we'll encounter the same vein again from an adjacent tunnel.
local maxVeinRecursion = 8

-- Every how many blocks to place a torch when placing torches.
local torchInverval = 11

--[[ Constants ]]--------------------------------------------------------------

-- Quick look-up table for inverting directions.
local oppositeSides = {
  [sides.north] = sides.south,
  [sides.south] = sides.north,
  [sides.east] = sides.west,
  [sides.west] = sides.east,
  [sides.up] = sides.down,
  [sides.down] = sides.up
}

-- For pushTurn() readability.
local left = false
local right = not left

--[[ State ]]------------------------------------------------------------------

-- Slots we don't want to drop. Filled in during initialization, based
-- on items already in the inventory. Useful for stuff like /dev/null.
local keepSlot = {}

-- Slots that we keep torches in, updated when stocking up on torches.

local toolChestSlot = 1
local torchChestSlot = 2
local oreChestSlot = 3
local chargerSlot = 4
local fluxPointSlot = 5
local redstoneSlot = 6
local torchSlot = 7
local toolSlot = 8

local move = nil

--local torchSlots = {}

--[[ "Passive" logic ]]--------------------------------------------------------

-- Keep track of moves we're away from our origin, and average energy used per
-- move. This is used to compute the threshold at which we have to return to
-- maintenance to recharge.
local preMoveEnergy, averageMoveCost, distanceToOrigin = 0, 15, 0

-- The actual callback called in postMove().
local onMove

-- Called whenever we're about to move, used to compute move cost.
local function preMove()
  preMoveEnergy = computer.energy()
end

-- Called whenever we're done moving, used for automatic torch placement an digging.
local function postMove()
  local moveCost = preMoveEnergy - computer.energy()
  if moveCost > 0 then
    averageMoveCost = (averageMoveCost + moveCost) / 2
  end
  if onMove then
    onMove()
  end
end

--[[ Utility ]]----------------------------------------------------------------

local function prompt(message)
  io.write(message .. " [Y/n] ")
  local result = io.read()
  return result and (result == "" or result:lower() == "y")
end

-- Check if a block with the specified info should be mined.
local function shouldMine(info)
  return info and info.name and (info.name:match(".*ore.*") or info.name:match(".*Ore.*"))
end

-- Number of stacks of torches to keep; default is 1 per inventory upgrade.
local function torchStacks()
  --return math.max(1, math.ceil(robot.inventorySize() / 16))
  return 1
end

-- Look for the first empty slot in our inventory.
local function findEmptySlot()
  for slot = 8, robot.inventorySize() do
    if robot.count(slot) == 0 then
      return slot
    end
  end
end

-- Find the first torch slot that still contains torches.
local function findTorchSlot()
    if robot.count(torchSlot) > 0 then
      return torchSlot
    end
end

-- Since robot.select() is an indirect call, we can speed things up a bit.
local selectedSlot
local function cachedSelect(slot)
  if slot ~= selectedSlot then
    robot.select(slot)
    selectedSlot = slot
  end
end

-- Place a single torch above the robot, if there are any torches left.
local function placeTorch()
  local slot = findTorchSlot()
  local result = false
  if slot then
    cachedSelect(slot)
    result = robot.placeUp(sides.right)
    cachedSelect(toolSlot)
  end
  return result
end

-- Dig out a block on the specified side, without tool if possible.
local function dig(side, callback)
  repeat
    -- Check for maintenance first, to make sure we make the return trip when
    -- our batteries are running low.
    local emptySlot = findEmptySlot()
    if callback then
      callback(not emptySlot) -- Parameter: is inventory full.
      emptySlot = findEmptySlot()
    end
    cachedSelect(toolSlot) -- was 1

    local something, what = component.robot.detect(side)
    if not something or what == "replaceable" or what == "liquid" then
      return true -- We can just move into whatever is there.
    end

    local brokeSomething

    local info = component.isAvailable("geolyzer") and
                 component.geolyzer.analyze(side)
    if info and info.name == "OpenComputers:robot" then
      brokeSomething = true -- Wait for other robot to go away.
      os.sleep(0.5)
    elseif component.isAvailable("inventory_controller") and emptySlot then
      cachedSelect(emptySlot)
      component.inventory_controller.equip() -- Save some tool durability.
      cachedSelect(toolSlot)
      brokeSomething = component.robot.swing(side)
      cachedSelect(emptySlot)
      component.inventory_controller.equip()
      cachedSelect(toolSlot)
    end
    if not brokeSomething then
      brokeSomething = component.robot.swing(side)
    end
  until not brokeSomething
end

-- Force a move towards in the specified direction.
local function forceMove(side, delta)
  preMove()
  local result = component.robot.move(side)
  if result then
    distanceToOrigin = distanceToOrigin + delta
    postMove()
  else
    -- Obstructed, try to clear the way.
    if side == sides.back then
      -- Moving backwards, turn around.
      component.robot.turn(left)
      component.robot.turn(left)
      repeat
        dig(sides.forward)
        preMove()
      until robot.forward()
      distanceToOrigin = distanceToOrigin + delta
      component.robot.turn(left)
      component.robot.turn(left)
      postMove() -- Slightly falsifies move cost, but must ensure we're rotated
                 -- correctly in case postMove() triggers going to maintenance.
    else
      repeat
        dig(side)
        preMove()
      until component.robot.move(side)
      distanceToOrigin = distanceToOrigin + delta
      postMove()
    end
  end
  return true
end

--[[ Navigation ]]-------------------------------------------------------------

-- Keeps track of our moves to allow "undoing" them for returning to the
-- docking station. Format is a list of moves, represented as tables
-- containing the type of move and distance to move, e.g.
--   {move=sides.back, count=10},
--   {turn=true, count=2}
-- means we first moved back 10 blocks, then turned around.
local moves = {}

-- Undo a *single* move, i.e. reduce the count of the latest move type.
local function undoMove(move)
  if move.move then
    local side = oppositeSides[move.move]
    forceMove(side, -1)
  else
    local direction = not move.turn
    component.robot.turn(direction)
  end
  move.count = move.count - 1
end

-- Make a turn in the specified direction.
local function pushTurn(direction)
  component.robot.turn(direction)
  if moves[#moves] and moves[#moves].turn == direction then
    moves[#moves].count = moves[#moves].count + 1
  else
    moves[#moves + 1] = {turn=direction, count=1}
  end
  return true -- Allows for `return pushMove() and pushTurn() and pushMove()`.
end

-- Try to make a move towards the specified side.
local function pushMove(side, force)
  preMove()
  local result, reason = (force and forceMove or component.robot.move)(side, 1)
  if result then
    if moves[#moves] and moves[#moves].move == side then
      moves[#moves].count = moves[#moves].count + 1
    else
      moves[#moves + 1] = {move=side, count=1}
    end
    if not force then
      distanceToOrigin = distanceToOrigin + 1
    end
    postMove()
  end
  return result, reason
end

-- Undo the most recent move *type*. I.e. will undo all moves of the most
-- recent type (say we moved forwards twice, this will go back twice).
local function popMove()
  -- Deep copy the move for returning it.
  local move = moves[#moves] and {move=moves[#moves].move,
                                  turn=moves[#moves].turn,
                                  count=moves[#moves].count}
  while moves[#moves] and moves[#moves].count > 0 do
    undoMove(moves[#moves])
  end
  moves[#moves] = nil
  return move
end

-- Get the current top and count values, to be used as a position snapshot
-- that can be restored later on by calling setTop().
local function getTop()
  if moves[#moves] then
    return #moves, moves[#moves].count
  else
    return 0, 0
  end
end

-- Undo some moves based on a stored top and count received from getTop().
local function setTop(top, count, unsafe)
  assert(top >= 0)
  assert(top <= #moves)
  assert(count >= 0)
  assert(top < #moves or count <= moves[#moves].count)
  while #moves > top do
    if unsafe then
      if moves[#moves].move then
        distanceToOrigin = distanceToOrigin - moves[#moves].count
      end
      moves[#moves] = nil
    else
      popMove()
    end
  end
  local move = moves[#moves]
  if move then
    while move.count > count do
      if unsafe then
        move.count = move.count - 1
        distanceToOrigin = distanceToOrigin - 1
      else
        undoMove(move)
      end
    end
    if move.count < 1 then
      moves[#moves] = nil
    end
  end
end

-- Undo *all* moves made since program start, return the list of moves.
local function popMoves()
  local result = {}
  local move = popMove()
  while move do
    table.insert(result, 1, move)
    move = popMove()
  end
  return result
end

-- Repeat the specified set of moves.
local function pushMoves(moves)
  for _, move in ipairs(moves) do
    if move.move then
      for _ = 1, move.count do
        pushMove(move.move, true)
      end
    else
      for _ = 1, move.count do
        pushTurn(move.turn)
      end
    end
  end
end

--[[ Maintenance ]]------------------------------------------------------------

-- Energy required to return to docking bay.
--MODIFIED
local function costToReturn()
  -- Overestimate a bit, to account for obstacles such as gravel or mobs.
  return 5000 + averageMoveCost * distanceToOrigin * 1.25
end

-- Checks whether we need maintenance.
local function needsMaintenance()
  return not robot.durability() or -- Tool broken?
         computer.energy() < costToReturn() or -- Out of juice?
         not findTorchSlot() -- No more torches?
end

-- Drops all inventory contents that are not marked for keeping.
local function dropMinedBlocks()
  cachedSelect(oreChestSlot)
  robot.placeUp()
  
  if component.isAvailable("inventory_controller") then
	if not component.inventory_controller.getInventorySize(sides.up) then
      --io.write("There doesn't seem to be an inventory below me! Waiting to avoid spilling stuffs into the world.\n")
    end
	repeat os.sleep(5) until component.inventory_controller.getInventorySize(sides.up)
  end
  io.write("Dropping what I found.\n")
  for slot = 8, robot.inventorySize() do
    while robot.count(slot) > 0 do
      cachedSelect(slot)
	  robot.dropUp()
    end
  end
  
  cachedSelect(oreChestSlot)
  move(sides.top)
  move(sides.bottom)
end

-- Ensures we have a tool with durability.
--BUG starts from the first slot (suckUp does this) and only pulls one thing, regardless of the thing.
local function checkTool()
  cachedSelect(toolChestSlot)
  robot.placeUp()
  
  -- place the tool chest above robot
  if not robot.durability() then
    io.write("Tool is broken, getting a new one.\n")
    if component.isAvailable("inventory_controller") then
      --cachedSelect(findEmptySlot()) -- Select an empty slot for working.
	  cachedSelect(toolSlot)
      repeat
        component.inventory_controller.equip() -- Drop whatever's in the tool slot.
        while robot.count() > 0 do
          robot.dropUp()
        end
        robot.suckUp(1) -- Pull something from above and equip it.
        component.inventory_controller.equip()
      until robot.durability()
      cachedSelect(toolSlot)
    else
      -- Can't re-equip autonomously, wait for player to give us a tool.
      io.write("HALP! I need a new tool.\n")
      repeat
        event.pull(10, "inventory_changed")
      until robot.durability()
    end
  end
  
  cachedSelect(toolChestSlot)
  move(sides.top)
  move(sides.bottom)
end

-- Ensures we have some torches.
local function checkTorches()
  -- First, clean up our list and look for empty slots.
  io.write("Getting my fill of torches.\n")
  
  cachedSelect(torchChestSlot)
  robot.placeUp()
  
	if robot.space(torchSlot) > 0 then
	  cachedSelect(torchSlot)
	  repeat
		local before = robot.space(torchSlot)
		--robot.suck(robot.space())
		robot.suckUp(robot.space(torchSlot))
		if robot.space(torchSlot) == before then
		  os.sleep(5) -- Don't busy idle.
		end
	  until robot.space(torchSlot) < 1
	  cachedSelect(toolSlot)
	end

	cachedSelect(torchChestSlot)
	move(sides.top)
	move(sides.bottom)
	
  --end
end

-- Recharge our batteries.
local function recharge()
  cachedSelect(redstoneSlot)
  move(sides.bottom)
  robot.place()
  cachedSelect(chargerSlot)
  move(sides.top)
  robot.place()
  cachedSelect(fluxPointSlot)
  move(sides.top)
  robot.place()
  move(sides.down)
  
  io.write("Waiting until my batteries are full.\n")
  while computer.maxEnergy() - computer.energy() > 100 do
    os.sleep(1)
  end
  
  cachedSelect(redstoneSlot)
  move(sides.bottom)
  move(sides.front)
  move(sides.back)
  cachedSelect(chargerSlot)
  move(sides.top)
  move(sides.front)
  move(sides.back)
  cachedSelect(fluxPointSlot)
  move(sides.top)
  move(sides.front)
  move(sides.back)
  move(sides.bottom)
  
end

-- Go back to the docking bay for general maintenance if necessary.
local function gotoMaintenance(force)
  if not force and not needsMaintenance() then
    return -- No need yet.
  end

  -- Save some values for later, temporarily remove onMove callback.
  local returnCost = costToReturn()
  local moveCallback = onMove
  onMove = nil

  local top, count = getTop()

  io.write("Setting up for maintenance!\n")
  local moves = popMoves()

  assert(distanceToOrigin == 0)

  -- clear the maintenance space
  move(sides.bottom) -- under
  move(sides.front) -- bottom front 
  move(sides.back)
  move(sides.top)
  move(sides.front) -- front
  move(sides.back)
  move(sides.top) -- above
  move(sides.front) -- top front
  move(sides.back)
  move(sides.bottom)
  
  checkTool()
  checkTorches()
  dropMinedBlocks()
  recharge() -- Last so we can charge some during the other operations above.

  if moves and #moves > 0 then
    if returnCost * 2 > computer.maxEnergy() and
       not options.f and
       not prompt("Going back will cost me half my energy. There's a good chance I will not return. Do you want to send me to my doom anyway?")
    then
      os.exit()
    end
    io.write("Returning to where I left off.\n")
    pushMoves(moves)
  end

  local newTop, newCount = getTop()
  assert(top == newTop)
  assert(count == newCount)

  onMove = moveCallback
end

--[[ Mining ]]-----------------------------------------------------------------

-- Move towards the specified direction, digging out blocks as necessary.
-- This is a "soft" version of forceMove in that it will try to clear its path,
-- but fail if it can't.
move = local function move(side)
  local result, reason, retry
  repeat
    retry = false
    if side ~= sides.back then
      retry = dig(side, gotoMaintenance)
    else
      gotoMaintenance()
    end
    result, reason = pushMove(side)
  until result or not retry
  return result, reason
end

-- Turn to face the specified, relative orientation.
local function turnTowards(side)
  if side == sides.left then
    pushTurn(left)
  elseif side == sides.right then
    pushTurn(right)
  elseif side == sides.back then
    pushTurn(left)
    pushTurn(left)
  end
end

--[[ On move callbacks ]]------------------------------------------------------

-- Start automatically placing torches in the configured interval.
local function beginPlacingTorches()
  local counter = 2
  onMove = function()
    if counter < 1 then
      if placeTorch() then
        counter = torchInverval
      end
    else
      counter = counter - 1
    end
  end
end

-- Stop automatically placing torches.
local function clearMoveCallback()
  onMove = nil
end

--[[ Moving ]]-----------------------------------------------------------------

-- Dig out any interesting ores adjacent to the current position, recursively.
-- POST: back to the starting position and facing.
local function digVein(maxDepth)
  if maxDepth < 1 then return end
  --for _, side in ipairs(sides) do
  for sideIndex = 0,5 do
    --side = sides[side]
	side = sideIndex
    if shouldMine(component.geolyzer.analyze(side)) then
      local top, count = getTop()
      turnTowards(side)
      if side == sides.up or side == sides.down then
        move(side)
      else
        move(sides.forward)
      end
      digVein(maxDepth - 1)
      setTop(top, count)
    end
  end
end

-- Dig out any interesting ores adjacent to the current position, recursively.
-- Also checks blocks adjacent to above block in exhaustive mode.
-- POST: back at the starting position and facing.
local function digVeins(exhaustive)
  if component.isAvailable("geolyzer") then
    digVein(maxVeinRecursion)
    if exhaustive and move(sides.up) then
      digVein(maxVeinRecursion)
      popMove()
    end
  end
end

-- Dig a 1x2 tunnel of the specified length. Checks for ores.
-- Also checks upper row for ores in exhaustive mode.
-- PRE: bottom front of tunnel to dig.
-- POST: at the end of the tunnel.
local function dig1x2(length, exhaustive)
  moves = {}
  distanceToOrigin = 0
  while length > 0 and move(sides.forward) do
    dig(sides.up, gotoMaintenance)
    digVeins(exhaustive)
    length = length - 1
  end
  return length < 1
end

--[[ Main ]]-------------------------------------------------------------------
local function stepsInEdge(edge)
	return (wallThickness + 1) * math.ceil(edge / 2)
end

local function main(currentEdge, completedSteps)
  -- Flag slots that contain something as do-not-drop and check
  -- that we have some free inventory space at all.
  local freeSlots = robot.inventorySize()
  for slot = 8, robot.inventorySize() do
    if robot.count(slot) > 0 then
      keepSlot[slot] = true
      freeSlots = freeSlots - 1
    end
  end
  if freeSlots < 2 + torchStacks() then -- Place for mined blocks + torches.
    io.write("Sorry, but I need more empty inventory space to work.\n")
    os.exit()
  end
  gotoMaintenance(true)

  while currentEdge <= 8 do 

	for i = 1, 2, 1 do -- repeat each operation twice
	  local totalSteps = stepsInEdge(currentEdge)
	  --io.write("Total Steps" .. totalSteps .. "\n")
	  local neededSteps = totalSteps - completedSteps

	  beginPlacingTorches()
	  dig1x2(neededSteps, true)
	  pushTurn(right)
	  clearMoveCallback()
			
	  -- we have fully finisehd an edge
	  -- set values for next edge
	  lastFinishedEdge = currentEdge
	  currentEdge = currentEdge + 1
	  completedSteps = 0
	end

  end -- digs 9 edges

  io.write("All done!\n")
  gotoMaintenance(true)
end

if options.h or options.help then
  io.write("Usage: spiral [-hsf] [wallThickness (2) [startingEdge (1) [startingSteps (0)]]]\n")
  io.write("  -h:     this help listing.\n")
  io.write("  -s:     start without prompting.\n")
  io.write("  -f:     force mining to continue even if max\n")
  io.write("          fuel may be insufficient to return.\n")
  os.exit()
end

-- an edge is a full side
local lastFinishedEdge = 0 -- 0 is no edges complete

wallThickness = tonumber(args[1]) or 2
local startingEdge = tonumber(args[2]) or 1
local startingSteps = tonumber (args[3]) or 0

io.write("Will mine in a spiral shape with " .. wallThickness .. " block thick walls.\n")

if not component.isAvailable("geolyzer") then
  io.write("Installing a geolyzer upgrade is strongly recommended.\n")
end
if not component.isAvailable("inventory_controller") then
  io.write("Installing an inventory controller upgrade is strongly recommended.\n")
end

--[[
local toolChestSlot = 1
local torchChestSlot = 2
local oreChestSlot = 3
local chargerSlot = 4
local fluxPointSlot = 5
local redstoneSlot = 6
local torchSlot = 7
local toolSlot = 8
]]

io.write("I need the following in the proper slots\n")
io.write("1: Tool Ender Chest (red)\n2: Torch Ender Chest (green)\n3: Ore Ender Chest (blue)\n4: Charger\n5: Flux Point\n6: Redstone Block\n")
io.write("I will get tools and torches from above me\n")

if component.isAvailable("inventory_controller") then
  --io.write("I'll try to get new tools from above me.\n")
else
  --io.write("You'll need to manually provide me with new tools if they break.\n")
end

io.write("Run with -h or --help for parameter info.\n")

if options.s or prompt("Shall we begin?") then
  main(startingEdge, startingSteps)
end