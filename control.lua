-- ============================================================================
-- HELPERS
-- ============================================================================

local function get_quality_name(obj)
  return obj and obj.quality and obj.quality.name or "normal"
end

local function item_stack(name, count, quality)
  return { name = name, count = count or 1, quality = quality or "normal" }
end

-- Insert into the inventory; whatever does not fit is spilled on the ground.
local function give_item_to_player(player, inventory, name, count, quality, position)
  local stack = item_stack(name, count, quality)
  local inserted = inventory.insert(stack)
  if inserted < count then
    player.surface.spill_item_stack({ position = position, stack = item_stack(name, count - inserted, quality), enable_looted = true, force = player.force })
  end
  return inserted
end

-- Script inventory handed to the engine as apply_upgrade `buffer` / revive
-- `overflow`, so leftover items land there instead of being deleted.
local function get_buffer()
  local buffer = storage.buffer
  if not (buffer and buffer.valid) then
    buffer = game.create_inventory(100)
    storage.buffer = buffer
  end
  return buffer
end

-- The docs do not say which items the engine puts into the buffer, so the
-- player gets the whole buffer plus only the part of `expected` (items the
-- mod has to refund) that is not already in it - never both.
local function settle_buffer(buffer, expected, player, inventory, position)
  local missing = {}
  for _, e in pairs(expected) do
    local key = e.name .. "/" .. e.quality
    if not missing[key] then
      missing[key] = { name = e.name, quality = e.quality, count = -buffer.get_item_count(item_stack(e.name, 1, e.quality)) }
    end
    missing[key].count = missing[key].count + e.count
  end
  for _, m in pairs(missing) do
    if m.count > 0 then
      give_item_to_player(player, inventory, m.name, m.count, m.quality, position)
    end
  end

  for i = 1, #buffer do
    local stack = buffer[i]
    if stack.valid_for_read then
      -- Inserting the LuaItemStack itself keeps item data (grids, labels, ...).
      local inserted = inventory.insert(stack)
      if inserted < stack.count then
        stack.count = stack.count - inserted
        player.surface.spill_item_stack({ position = position, stack = stack, enable_looted = true, force = player.force })
      end
    end
  end
  buffer.clear()
end

local function has_item(inventory, name, quality)
  return inventory.get_item_count(item_stack(name, 1, quality)) > 0
end

local function get_item_count_with_cursor(player, inventory, name, quality)
  local count = inventory.get_item_count(item_stack(name, 1, quality))
  local cursor = player.cursor_stack
  if cursor and cursor.valid_for_read and cursor.name == name then
    if get_quality_name(cursor) == quality then
      count = count + cursor.count
    end
  end
  return count
end

local function remove_item_with_cursor(player, inventory, name, quality, count)
  local removed = 0
  local in_inventory = inventory.get_item_count(item_stack(name, 1, quality))

  if in_inventory > 0 then
    local to_remove = math.min(in_inventory, count)
    removed = inventory.remove(item_stack(name, to_remove, quality))
  end

  if removed < count then
    local cursor = player.cursor_stack
    if cursor and cursor.valid_for_read and cursor.name == name then
      if get_quality_name(cursor) == quality then
        local need = count - removed
        if cursor.count <= need then
          removed = removed + cursor.count
          cursor.clear()
        else
          cursor.count = cursor.count - need
          removed = removed + need
        end
      end
    end
  end

  return removed
end

-- `stack_index` is 0-based, as in InventoryPosition.
local function add_to_plan(plan, name, quality, inventory_id, stack_index, count)
  local position = { inventory = inventory_id, stack = stack_index, count = count or 1 }

  for _, p in pairs(plan) do
    if p.id.name == name and (p.id.quality or "normal") == quality then
      table.insert(p.items.in_inventory, position)
      return
    end
  end

  table.insert(plan, {
    id = { name = name, quality = quality },
    items = { in_inventory = { position } }
  })
end

local function save_inserter_held_items(entity)
  if entity.type ~= "inserter" then return nil end
  if not entity.held_stack or not entity.held_stack.valid_for_read then return nil end

  return {
    name = entity.held_stack.name,
    count = entity.held_stack.count,
    quality = get_quality_name(entity.held_stack)
  }
end

-- Held items the upgraded inserter did not keep in its hand, or nil.
local function inserter_lost_items(new_entity, held_items)
  if not held_items or new_entity.type ~= "inserter" then return nil end

  local new_held = new_entity.held_stack
  local in_new_hand = (new_held and new_held.valid_for_read) and new_held.count or 0
  local lost = held_items.count - in_new_hand

  if lost > 0 then
    return { name = held_items.name, count = lost, quality = held_items.quality }
  end
  return nil
end

-- Splits the proxy plans into module slots (handled here) and requests for
-- other inventories (fuel, ammo, ...) which are passed back to the proxy
-- untouched so the bots can still fulfill them.
local function build_slot_plan(insert_plan, removal_plan, module_inventory_id)
  local slots = {}
  local foreign_insert_plan = {}
  local foreign_removal_plan = {}

  local function collect(source, foreign, name_key, quality_key)
    for _, plan in pairs(source or {}) do
      if plan.items and plan.items.in_inventory then
        local quality = plan.id.quality or "normal"
        for _, inv_pos in pairs(plan.items.in_inventory) do
          if inv_pos.inventory == module_inventory_id then
            local idx = inv_pos.stack + 1
            slots[idx] = slots[idx] or {}
            slots[idx][name_key] = plan.id.name
            slots[idx][quality_key] = quality
          else
            add_to_plan(foreign, plan.id.name, quality, inv_pos.inventory, inv_pos.stack, inv_pos.count)
          end
        end
      end
    end
  end

  collect(removal_plan, foreign_removal_plan, "old_name", "old_quality")
  collect(insert_plan, foreign_insert_plan, "new_name", "new_quality")

  return slots, foreign_insert_plan, foreign_removal_plan
end

-- Two-phase: all removals first, then the insertions.
local function process_module_slots(slots, module_inventory, module_inventory_id, inventory, player, position)
  local did_something = false
  local new_insert_plan = {}
  local new_removal_plan = {}
  local slot_count = #module_inventory

  -- Phase 1: removals (including the removal half of a replacement).
  for slot_index, data in pairs(slots) do
    local slot = (slot_index >= 1 and slot_index <= slot_count) and module_inventory[slot_index] or nil
    if not slot then goto continue_removal end

    local old_name, old_quality = data.old_name, data.old_quality

    if old_name and slot.valid_for_read and slot.name == old_name then
      local slot_quality = get_quality_name(slot)
      if slot_quality == old_quality then
        local old_count = slot.count
        slot.clear()
        give_item_to_player(player, inventory, old_name, old_count, old_quality, position)
        did_something = true
        data.removal_done = true
      end
    end

    ::continue_removal::
  end

  -- Phase 2: insertions.
  for slot_index, data in pairs(slots) do
    local slot = (slot_index >= 1 and slot_index <= slot_count) and module_inventory[slot_index] or nil
    if not slot then goto continue_insert end

    local new_name, new_quality = data.new_name, data.new_quality
    local old_name, old_quality = data.old_name, data.old_quality

    if new_name then
      -- On a replacement, insert only if the removal actually happened -
      -- otherwise the slot still holds a different module.
      local can_insert = true
      if old_name and not data.removal_done then
        can_insert = false
      end

      if can_insert and has_item(inventory, new_name, new_quality) then
        -- Target the exact slot when it is free, otherwise take any free one.
        local inserted = 0
        if not slot.valid_for_read then
          inserted = slot.set_stack(item_stack(new_name, 1, new_quality)) and 1 or 0
        else
          inserted = module_inventory.insert(item_stack(new_name, 1, new_quality))
        end

        if inserted > 0 then
          inventory.remove(item_stack(new_name, inserted, new_quality))
          did_something = true
        else
          add_to_plan(new_insert_plan, new_name, new_quality, module_inventory_id, slot_index - 1)
        end
      elseif new_name and not can_insert then
        add_to_plan(new_insert_plan, new_name, new_quality, module_inventory_id, slot_index - 1)
        if old_name then
          add_to_plan(new_removal_plan, old_name, old_quality, module_inventory_id, slot_index - 1)
        end
      elseif new_name then
        -- Item not in the inventory: keep it in the plan for later.
        add_to_plan(new_insert_plan, new_name, new_quality, module_inventory_id, slot_index - 1)
      end
    end

    ::continue_insert::
  end

  return did_something, new_insert_plan, new_removal_plan
end

-- ============================================================================
-- AUTO-BUILD TOGGLE
-- ============================================================================

local function toggle_auto_build(player_index)
  local player = game.players[player_index]
  local state = not player.is_shortcut_toggled("player-toggle-auto-shortcut")
  player.set_shortcut_toggled("player-toggle-auto-shortcut", state)
end

script.on_event("player-toggle-auto-input", function(event)
  toggle_auto_build(event.player_index)
end)

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name == "player-toggle-auto-shortcut" then
    toggle_auto_build(event.player_index)
  end
end)

-- ============================================================================
-- DECONSTRUCTION
-- ============================================================================

local function deconstruct(entity, player, player_settings)
  local deconstruct_stones_trees = player_settings["deconstruct-stones-trees"].value

  if not (entity and entity.valid) then return false end

  -- Tile deconstruction
  if entity.name == "deconstructible-tile-proxy" then
    local surface = entity.surface
    local tile = surface.get_tile(entity.position.x, entity.position.y)

    -- mine_tile handles the item transfer and the mining events by itself.
    local success = player.mine_tile(tile)

    -- Destroy the proxy if mine_tile did not already remove it.
    if entity.valid then
      entity.destroy({ raise_destroy = true, player = player })
    end

    return success
  end

  -- Regular entity deconstruction
  local can_deconstruct = (entity.force == player.force)
  if deconstruct_stones_trees and entity.force == game.forces["neutral"] then
    can_deconstruct = true
  end

  if can_deconstruct and entity.minable then
    return player.mine_entity(entity)
  end

  return false
end

-- ============================================================================
-- MODULE REQUEST HANDLING
-- ============================================================================

local function fulfill_item_request(proxy, player, inventory)
  if not (proxy and proxy.valid) then return false end

  local target = proxy.proxy_target
  if not (target and target.valid) then return false end

  local module_inventory = target.get_module_inventory and target.get_module_inventory()
  if not module_inventory then return false end

  local insert_plan = proxy.insert_plan
  local removal_plan = proxy.removal_plan

  if (not insert_plan or #insert_plan == 0) and (not removal_plan or #removal_plan == 0) then
    return false
  end

  local module_inventory_id = module_inventory.index or defines.inventory.crafter_modules

  local slots_to_process, foreign_insert_plan, foreign_removal_plan =
    build_slot_plan(insert_plan, removal_plan, module_inventory_id)

  local did_something, new_insert_plan, new_removal_plan = process_module_slots(
    slots_to_process, module_inventory, module_inventory_id, inventory, player, target.position
  )

  if did_something and proxy.valid then
    for _, p in pairs(foreign_insert_plan) do table.insert(new_insert_plan, p) end
    for _, p in pairs(foreign_removal_plan) do table.insert(new_removal_plan, p) end

    if #new_insert_plan == 0 and #new_removal_plan == 0 then
      proxy.destroy()
    else
      proxy.insert_plan = new_insert_plan
      proxy.removal_plan = new_removal_plan
    end
  end

  return did_something
end

-- ============================================================================
-- CONSTRUCTION
-- ============================================================================

-- Refuse to revive a ghost while somebody who would really collide with the
-- finished entity stands inside its footprint, otherwise a tank that drove
-- through a wall gets instantly walled back in. Walking over belt or rail
-- ghosts must keep building them, so an overlap only counts when the two
-- collision masks share at least one layer.
-- bounding_box is the only documented box that respects entity orientation,
-- and it works on ghosts too ("Most functions on LuaEntity also work when the
-- entity is contained in a ghost"), so the unrotated collision_box is not used.
-- ponytail: spider-vehicle is deliberately NOT a blocker - spidertrons walk
-- over buildings, so blocking on them would break normal building for nothing.
local function is_footprint_blocked(entity)
  local box = entity.bounding_box
  local lt = box and (box.left_top or box[1])
  local rb = box and (box.right_bottom or box[2])
  if not (lt and rb) then return false end

  local ghost_prototype = entity.ghost_prototype
  local ghost_mask = ghost_prototype and ghost_prototype.collision_mask
  local ghost_layers = ghost_mask and ghost_mask.layers

  local blockers = entity.surface.find_entities_filtered {
    area = { { lt.x, lt.y }, { rb.x, rb.y } },
    type = { "character", "car" }
  }

  for _, blocker in pairs(blockers) do
    local prototype = blocker.prototype
    local mask = prototype and prototype.collision_mask
    local layers = mask and mask.layers

    if not (ghost_layers and layers) then
      -- Mask unavailable: cannot prove they miss each other, so stay safe.
      return true
    end

    for layer in pairs(ghost_layers) do
      if layers[layer] then return true end
    end
  end

  return false
end

-- True when any wire connector of the entity (or ghost) has a wire, ghost wires
-- included.
local function has_wires(entity)
  for _, connector in pairs(entity.get_wire_connectors(false)) do
    if connector.connection_count > 0 then return true end
  end
  return false
end

local function construct(entity, player, inventory)
  if not (entity and entity.valid) then return false end
  if not entity.ghost_name then return false end

  local required_items = entity.ghost_prototype.items_to_place_this
  if not required_items or #required_items == 0 then return false end

  local quality = get_quality_name(entity)
  local is_tile = (entity.type == "tile-ghost")

  for _, item_data in pairs(required_items) do
    local item_name = item_data.name
    -- ItemToPlace.count: e.g. a curved rail takes several rail items.
    local item_count = item_data.count or 1

    if get_item_count_with_cursor(player, inventory, item_name, quality) >= item_count then
      -- Tiles cannot trap anybody, so only entity ghosts need the footprint
      -- check. It runs after the item count so it costs an area search only
      -- for ghosts that would really be built now, and still before any
      -- inventory or ghost mutation below.
      if not is_tile and is_footprint_blocked(entity) then return false end

      -- Read the ghost data before reviving destroys the ghost.
      local entity_position = entity.position
      local buffer = get_buffer()

      -- Electric poles without wires (e.g. Ctrl+Z undo ghosts) go through
      -- create_entity instead of revive, so that the engine wires up the copper
      -- connections automatically. Pole ghosts that already carry wires (from
      -- a blueprint paste) are revived normally: destroying the ghost would
      -- drop those wires, revive keeps them.
      local collided_items, revived_entity, request_proxy
      if not is_tile and entity.ghost_type == "electric-pole" and not has_wires(entity) then
        local surface = entity.surface
        local create_params = {
          name = entity.ghost_name,
          position = entity.position,
          direction = entity.direction,
          force = entity.force,
          quality = quality,
          player = player,
          raise_built = true,
          create_build_effect_smoke = false,
        }
        entity.destroy()
        revived_entity = surface.create_entity(create_params)
      else
        -- raise_revive makes the engine fire script_raised_revive; items it
        -- would delete go to `overflow`. The ghost's item requests (modules,
        -- fuel, ...) come back as an item request proxy.
        collided_items, revived_entity, request_proxy = entity.revive { raise_revive = true, overflow = buffer }
      end

      -- For tiles revive returns no entity; a table in collided_items means success.
      local success = is_tile and (collided_items ~= nil) or (revived_entity and revived_entity.valid)

      if success then
        remove_item_with_cursor(player, inventory, item_name, quality, item_count)

        -- Items the new entity or tile collided with go back to the player.
        local expected = {}
        for _, collided in pairs(collided_items or {}) do
          if collided.count and collided.count > 0 then
            table.insert(expected, { name = collided.name, count = collided.count, quality = collided.quality or "normal" })
          end
        end
        settle_buffer(buffer, expected, player, inventory, entity_position)

        -- Fill the requested module slots right away; other requests stay
        -- on the proxy for the bots.
        if request_proxy and request_proxy.valid then
          fulfill_item_request(request_proxy, player, inventory)
        end

        return true
      end
      settle_buffer(buffer, {}, player, inventory, entity_position)
      return false
    end
  end

  return false
end

-- ============================================================================
-- UPGRADE
-- ============================================================================

local function upgrade(entity, player, inventory)
  if not (entity and entity.valid) then return false end

  local upgrade_prototype, upgrade_quality = entity.get_upgrade_target()
  if not upgrade_prototype then return false end

  local new_quality = upgrade_quality and upgrade_quality.name or "normal"
  local required_items = upgrade_prototype.items_to_place_this
  if not required_items or #required_items == 0 then return false end

  -- apply_upgrade also upgrades the paired underground belt end (its second
  -- return value), so both ends have to be paid for.
  local old_entities = { entity }
  if entity.type == "underground-belt" then
    local pair = entity.underground_belt_neighbour
    if pair and pair.valid and pair.to_be_upgraded() then
      table.insert(old_entities, pair)
    end
  end

  for _, item_data in pairs(required_items) do
    local item_name = item_data.name
    local item_count = item_data.count or 1

    if inventory.get_item_count(item_stack(item_name, 1, new_quality)) >= item_count * #old_entities then
      -- Items the replaced entities give back.
      local expected = {}
      for _, old in pairs(old_entities) do
        local old_place_items = old.prototype.items_to_place_this
        local old_item = old_place_items and old_place_items[1]
        if old_item then
          table.insert(expected, { name = old_item.name, count = old_item.count, quality = get_quality_name(old) })
        end
      end
      local position = entity.position

      local held_items = save_inserter_held_items(entity)

      local buffer = get_buffer()
      local new_entity, new_pair = entity.apply_upgrade(nil, buffer)

      if new_entity and new_entity.valid then
        local upgraded = (new_pair and new_pair.valid) and 2 or 1
        inventory.remove(item_stack(item_name, item_count * upgraded, new_quality))
        if upgraded < #old_entities then expected[2] = nil end

        local lost = inserter_lost_items(new_entity, held_items)
        if lost then table.insert(expected, lost) end

        settle_buffer(buffer, expected, player, inventory, position)

        return true
      end
      settle_buffer(buffer, {}, player, inventory, position)
      return false
    end
  end

  return false
end

-- ============================================================================
-- MAIN SCAN LOOP
-- ============================================================================

local function scan(player)
  local player_settings = settings.get_player_settings(player)
  local radius
  if player_settings["default-radius"].value then
    radius = player.character.build_distance
  else
    radius = player_settings["custom-radius"].value
  end

  local inventory = player.get_main_inventory()
  if not inventory or not inventory.valid then return false end

  local surface = player.surface
  local position = player.position

  local instant_deconstruct = player_settings["instant-deconstruction"].value
  local instant_construct = player_settings["instant-construction"].value
  local instant_upgrade = player_settings["instant-upgrade"].value
  local nearest_first = player_settings["nearest-first"].value

  -- Returns true when scan must stop (non-instant mode and something was done).
  local function process_all(filter_params, handler, instant)
    filter_params.position = position
    filter_params.radius = radius

    local entities = surface.find_entities_filtered(filter_params)

    -- Nearest first: sort by squared distance, no sqrt needed.
    -- A full sort rather than a single minimum lookup, to keep the old behaviour
    -- of "act on the first entity that succeeds" - when the closest one fails
    -- (not enough items, for example), fall through to the next closest.
    if nearest_first then
      local by_distance = {}
      for i, entity in pairs(entities) do
        local entity_position = entity.position
        local dx = entity_position.x - position.x
        local dy = entity_position.y - position.y
        by_distance[i] = { entity = entity, distance = dx * dx + dy * dy }
      end
      table.sort(by_distance, function(a, b) return a.distance < b.distance end)
      for i, item in pairs(by_distance) do entities[i] = item.entity end
    end

    for _, entity in pairs(entities) do
      if entity.valid and handler(entity) then
        if not instant then return true end
      end
    end
    return false
  end

  -- 1. Deconstruction
  if process_all(
    { to_be_deconstructed = true },
    function(e) return deconstruct(e, player, player_settings) end,
    instant_deconstruct
  ) then return true end

  -- 2. Upgrades
  if process_all(
    { to_be_upgraded = true },
    function(e) return upgrade(e, player, inventory) end,
    instant_upgrade
  ) then return true end

  -- 3. Entity ghosts
  if process_all(
    { type = "entity-ghost" },
    function(e) return construct(e, player, inventory) end,
    instant_construct
  ) then return true end

  -- 4. Tile ghosts
  if process_all(
    { type = "tile-ghost" },
    function(e) return construct(e, player, inventory) end,
    instant_construct
  ) then return true end

  -- 5. Module requests
  if process_all(
    { type = "item-request-proxy" },
    function(e) return fulfill_item_request(e, player, inventory) end,
    instant_construct
  ) then return true end

  return false
end

script.on_event(defines.events.on_tick, function(event)
  for _, player in pairs(game.players) do
    -- controller_type check: in remote view player.surface/position follow the
    -- camera while player.character stays set, so the mod would otherwise
    -- build and mine at the camera with the body's inventory.
    if player.connected and player.character
      and player.controller_type == defines.controllers.character
      and player.is_shortcut_toggled("player-toggle-auto-shortcut")
      and ((game.tick + player.index) % 4) == 0 then
      scan(player)
    end
  end
end)
