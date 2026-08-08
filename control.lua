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

local function add_to_plan(plan, name, quality, slot_index)
  for _, p in pairs(plan) do
    if p.id.name == name and (p.id.quality or "normal") == quality then
      table.insert(p.items.in_inventory, {
        inventory = defines.inventory.assembling_machine_modules,
        stack = slot_index - 1,
        count = 1
      })
      return
    end
  end

  table.insert(plan, {
    id = { name = name, quality = quality },
    items = {
      in_inventory = {{
        inventory = defines.inventory.assembling_machine_modules,
        stack = slot_index - 1,
        count = 1
      }}
    }
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

local function restore_inserter_lost_items(new_entity, held_items, player, inventory, position)
  if not held_items or new_entity.type ~= "inserter" then return end

  local new_held = new_entity.held_stack
  local in_new_hand = (new_held and new_held.valid_for_read) and new_held.count or 0
  local lost = held_items.count - in_new_hand

  if lost > 0 then
    give_item_to_player(player, inventory, held_items.name, lost, held_items.quality, position)
  end
end

local function build_slot_plan(insert_plan, removal_plan)
  local slots = {}

  if removal_plan then
    for _, plan in pairs(removal_plan) do
      if plan.items and plan.items.in_inventory then
        for _, inv_pos in pairs(plan.items.in_inventory) do
          local idx = inv_pos.stack + 1
          slots[idx] = slots[idx] or {}
          slots[idx].old_name = plan.id.name
          slots[idx].old_quality = plan.id.quality or "normal"
        end
      end
    end
  end

  if insert_plan then
    for _, plan in pairs(insert_plan) do
      if plan.items and plan.items.in_inventory then
        for _, inv_pos in pairs(plan.items.in_inventory) do
          local idx = inv_pos.stack + 1
          slots[idx] = slots[idx] or {}
          slots[idx].new_name = plan.id.name
          slots[idx].new_quality = plan.id.quality or "normal"
        end
      end
    end
  end

  return slots
end

-- Two-phase: all removals first, then the insertions.
local function process_module_slots(slots, module_inventory, inventory, player, position)
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
          slot.set_stack(item_stack(new_name, 1, new_quality))
          inserted = 1
        else
          inserted = module_inventory.insert(item_stack(new_name, 1, new_quality))
        end

        if inserted > 0 then
          inventory.remove(item_stack(new_name, inserted, new_quality))
          did_something = true
        else
          add_to_plan(new_insert_plan, new_name, new_quality, slot_index)
        end
      elseif new_name and not can_insert then
        add_to_plan(new_insert_plan, new_name, new_quality, slot_index)
        if old_name then
          add_to_plan(new_removal_plan, old_name, old_quality, slot_index)
        end
      elseif new_name then
        -- Item not in the inventory: keep it in the plan for later.
        add_to_plan(new_insert_plan, new_name, new_quality, slot_index)
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
-- CONSTRUCTION
-- ============================================================================

local function update_proxy_after_partial_insert(proxy, target)
  if not (proxy and proxy.valid and target and target.valid) then return end

  local module_inventory = target.get_module_inventory and target.get_module_inventory()
  if not module_inventory then return end

  local insert_plan = proxy.insert_plan
  if not insert_plan or #insert_plan == 0 then
    proxy.destroy()
    return
  end

  local new_insert_plan = {}

  for _, plan in pairs(insert_plan) do
    local item_name = plan.id.name
    local item_quality = plan.id.quality or "normal"

    if plan.items and plan.items.in_inventory then
      local remaining = {}

      for _, inv_pos in pairs(plan.items.in_inventory) do
        local _idx = inv_pos.stack + 1
        local slot = (_idx >= 1 and _idx <= #module_inventory) and module_inventory[_idx] or nil
        local filled = slot and slot.valid_for_read
                       and slot.name == item_name
                       and slot.quality.name == item_quality

        if not filled then
          table.insert(remaining, inv_pos)
        end
      end

      if #remaining > 0 then
        table.insert(new_insert_plan, {
          id = plan.id,
          items = { in_inventory = remaining }
        })
      end
    end
  end

  if #new_insert_plan == 0 then
    proxy.destroy()
  else
    proxy.insert_plan = new_insert_plan
  end
end

-- Refuse to revive a ghost while somebody stands inside its footprint,
-- otherwise a tank that drove through a wall gets instantly walled back in.
-- The footprint is the union of the ghost bounding_box and the prototype
-- collision_box (offset to the ghost position): a union can only cover too
-- much, never less than the real area.
-- ponytail: spider-vehicle is deliberately NOT a blocker - spidertrons walk
-- over buildings, so blocking on them would break normal building for nothing.
local function is_footprint_blocked(entity)
  local box = entity.bounding_box
  local lt = box and (box.left_top or box[1])
  local rb = box and (box.right_bottom or box[2])

  local left, top, right, bottom
  if lt and rb then
    left, top, right, bottom = lt.x, lt.y, rb.x, rb.y
  end

  local prototype = entity.ghost_prototype
  local collision_box = prototype and prototype.collision_box
  local position = entity.position
  local clt = collision_box and (collision_box.left_top or collision_box[1])
  local crb = collision_box and (collision_box.right_bottom or collision_box[2])

  if clt and crb and position then
    local x1, y1 = clt.x + position.x, clt.y + position.y
    local x2, y2 = crb.x + position.x, crb.y + position.y
    left   = left   and math.min(left, x1)   or x1
    top    = top    and math.min(top, y1)    or y1
    right  = right  and math.max(right, x2)  or x2
    bottom = bottom and math.max(bottom, y2) or y2
  end

  if not left then return false end

  local blockers = entity.surface.find_entities_filtered {
    area = { { left, top }, { right, bottom } },
    type = { "character", "car" },
    limit = 1
  }

  return #blockers > 0
end

local function construct(entity, player, inventory)
  if not (entity and entity.valid) then return false end
  if not entity.ghost_name then return false end

  local required_items = entity.ghost_prototype.items_to_place_this
  if not required_items or #required_items == 0 then return false end

  local quality = get_quality_name(entity)
  local is_tile = (entity.type == "tile-ghost")

  -- Tiles cannot trap anybody, so only entity ghosts need the footprint check.
  if not is_tile and is_footprint_blocked(entity) then return false end

  for _, item_data in pairs(required_items) do
    local item_name = item_data.name

    if get_item_count_with_cursor(player, inventory, item_name, quality) > 0 then
      -- Read the ghost data before reviving destroys the ghost.
      local item_requests = (not is_tile) and entity.item_requests or nil
      local entity_position = entity.position

      -- Electric poles go through create_entity instead of revive, so that the
      -- engine wires up the copper connections automatically.
      local collided_items, revived_entity
      if not is_tile and entity.ghost_type == "electric-pole" then
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
        -- raise_revive makes the engine fire script_raised_revive.
        collided_items, revived_entity = entity.revive { raise_revive = true }
      end

      -- For tiles revive returns no entity; a table in collided_items means success.
      local success = is_tile and (collided_items ~= nil) or (revived_entity and revived_entity.valid)

      if success then
        remove_item_with_cursor(player, inventory, item_name, quality, 1)

        -- Items of the tile that got replaced go back to the player.
        if collided_items then
          for _, collided in pairs(collided_items) do
            if collided.count and collided.count > 0 then
              give_item_to_player(player, inventory, collided.name, collided.count, collided.quality or "normal", entity_position)
            end
          end
        end

        if item_requests and #item_requests > 0 and revived_entity and revived_entity.valid then
          local module_inventory = revived_entity.get_module_inventory()
          if module_inventory then
            for _, request in pairs(item_requests) do
              local module_name = request.name
              local module_quality = request.quality or "normal"
              local module_count = request.count or 1

              local available = inventory.get_item_count(item_stack(module_name, 1, module_quality))
              local to_insert = math.min(available, module_count)

              if to_insert > 0 then
                local inserted = module_inventory.insert(item_stack(module_name, to_insert, module_quality))
                if inserted > 0 then
                  inventory.remove(item_stack(module_name, inserted, module_quality))
                end
              end
            end
          end
        end

        return true
      end
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

  for _, item_data in pairs(required_items) do
    local item_name = item_data.name

    if has_item(inventory, item_name, new_quality) then
      local old_quality = get_quality_name(entity)
      local old_place_items = entity.prototype.items_to_place_this
      local old_item = old_place_items and old_place_items[1]
      local position = entity.position

      local held_items = save_inserter_held_items(entity)

      local new_entity = entity.apply_upgrade()

      if new_entity and new_entity.valid then
        inventory.remove(item_stack(item_name, 1, new_quality))
        if old_item then
          give_item_to_player(player, inventory, old_item.name, old_item.count, old_quality, position)
        end

        restore_inserter_lost_items(new_entity, held_items, player, inventory, position)

        return true
      end
      return false
    end
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

  local slots_to_process = build_slot_plan(insert_plan, removal_plan)

  local did_something, new_insert_plan, new_removal_plan = process_module_slots(
    slots_to_process, module_inventory, inventory, player, target.position
  )

  if did_something and proxy.valid then
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
    if player.connected and player.character and player.is_shortcut_toggled("player-toggle-auto-shortcut") and ((game.tick + player.index) % 4) == 0 then
      scan(player)
    end
  end
end)
