-- MHR Immersive Haptics v1.0.0
-- Production runtime. Read-only game-state access + haptic event bridge.

local H = {
    bridge_seq = 0,
    states = {},

    player = nil,
    player_pos = nil,
    player_hp_last = nil,
    last_player_hit_time = -9999.0,

    outgoing_pending_count = 0,
    outgoing_pending_sum = 0.0,
    outgoing_pending_max = 0.0,
    outgoing_pending_red = false,

    player_last_pos = nil,
    player_last_sample_time = nil,
    player_raw_vy = 0.0,
    player_prev_raw_vy = 0.0,
    player_smoothed_vy = 0.0,

    player_falling = false,
    player_fall_start_time = nil,
    player_fall_start_y = nil,
    player_lowest_y = nil,
    player_fall_drop = 0.0,
    player_peak_down_speed = 0.0,
    player_last_landing_time = -9999.0,
}

local BRIDGE_FILE = "mhr_haptics_event.txt"
local MAX_BOSS_SLOTS = 6

local component_type = sdk.find_type_definition("via.Component")
local gameobject_type = sdk.find_type_definition("via.GameObject")
local transform_type = sdk.find_type_definition("via.Transform")

local component_get_gameobject =
    component_type ~= nil and component_type:get_method("get_GameObject") or nil
local gameobject_get_transform =
    gameobject_type ~= nil and gameobject_type:get_method("get_Transform") or nil
local transform_get_position =
    transform_type ~= nil and transform_type:get_method("get_Position") or nil

-- Roar
local ROAR_EVENT_COOLDOWN = 0.75
local ROAR_NEAR_DISTANCE = 5.0
-- Practical haptic cutoff is ~30 m because events below 10% are discarded.
local ROAR_MAX_DISTANCE = 32.7

-- Monster landing
local FALL_START_SPEED = -0.75
local HARD_IMPACT_MIN_SPEED = 5.0
local FULL_IMPACT_SPEED = 12.0
local LANDING_WINDOW_MIN_VY = -1.35
local LANDING_WINDOW_MAX_VY = 2.50
local IMPACT_DECELERATION_DELTA = 4.0
local MIN_DROP_DISTANCE = 0.25
local MIN_FALL_SECONDS = 0.08
local MAX_FALL_SECONDS = 6.0
local LANDING_COOLDOWN = 0.30
local LAND_NEAR_DISTANCE = 5.0
local LAND_MAX_DISTANCE = 32.0
local MIN_OUTPUT_STRENGTH = 0.10

-- Incoming player damage
local PLAYER_HIT_COOLDOWN = 0.075
local PLAYER_HIT_MIN_ABSOLUTE_DAMAGE = 1.5
local PLAYER_HIT_FULL_DAMAGE_FRACTION = 0.40

-- Outgoing player damage
local PLAYER_ATTACK_DAMAGE_SCALE = 90.0
local PLAYER_ATTACK_MIN_STRENGTH = 0.33
local PLAYER_ATTACK_MULTI_HIT_BONUS = 0.03
local PLAYER_ATTACK_MAX_MULTI_BONUS = 0.12

-- Damage-number categories verified during testing.
local LOCAL_PLAYER_DAMAGE_COLOR_TYPES = {
    [0] = true, -- normal / white
    [1] = true, -- red / stronger hit
}

-- Player landing
local PLAYER_FALL_START_SPEED = -1.25
local PLAYER_HARD_LAND_MIN_SPEED = 7.0
local PLAYER_FULL_LAND_SPEED = 18.0
local PLAYER_MIN_LAND_DROP = 2.0
local PLAYER_FULL_LAND_DROP = 8.0
local PLAYER_LANDING_WINDOW_MIN_VY = -1.50
local PLAYER_LANDING_WINDOW_MAX_VY = 3.50
local PLAYER_LANDING_DECEL_DELTA = 5.0
local PLAYER_MIN_FALL_SECONDS = 0.10
local PLAYER_MAX_FALL_SECONDS = 8.0
local PLAYER_LANDING_COOLDOWN = 0.35

-- Roar signature fallback. Getter-based detection remains primary.
local seed_roar_signatures = {
    ["snow.enemy.em060.Em060_00Character"] = {
        ["24:102"] = true,
    },
}

local learned_roar_signatures = {}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function safe_call(obj, method_name)
    if obj == nil then return nil end
    local ok, result = pcall(function() return obj:call(method_name) end)
    if ok then return result end
    return nil
end

local function safe_handle_call(method, obj)
    if method == nil or obj == nil then return nil end
    local ok, result = pcall(function() return method:call(obj) end)
    if ok then return result end
    return nil
end

local function get_type_name(obj)
    if obj == nil then return "nil" end
    local ok, td = pcall(function() return obj:get_type_definition() end)
    if not ok or td == nil then return "?" end
    local ok2, name = pcall(function() return td:get_full_name() end)
    if ok2 and name ~= nil then return tostring(name) end
    return "?"
end

local function get_boss_enemy(index)
    local mgr = sdk.get_managed_singleton("snow.enemy.EnemyManager")
    if mgr == nil then return nil end

    local ok, monster = pcall(function()
        return mgr:call("getBossEnemy", index)
    end)

    if ok then return monster end
    return nil
end

local function get_local_player()
    local mgr = sdk.get_managed_singleton("snow.player.PlayerManager")
    if mgr == nil then return nil end

    local ok_master, master = pcall(function()
        return mgr:call("findMasterPlayer")
    end)

    if ok_master and master ~= nil then
        return master
    end

    local ok_player, player = pcall(function()
        return mgr:call("getPlayer", 0)
    end)

    if ok_player then return player end
    return nil
end

local function vector_to_xyz(v)
    if v == nil then return nil end

    local ok, x, y, z = pcall(function()
        return v.x, v.y, v.z
    end)

    if ok and x ~= nil and y ~= nil and z ~= nil then
        return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
    end

    return nil
end

local function get_world_position(obj)
    if obj == nil then return nil end

    local go_direct = safe_call(obj, "get_GameObject")
    if go_direct ~= nil then
        local tr_direct = safe_call(go_direct, "get_Transform")
        if tr_direct ~= nil then
            local xyz = vector_to_xyz(safe_call(tr_direct, "get_Position"))
            if xyz ~= nil then return xyz end
        end
    end

    local go = safe_handle_call(component_get_gameobject, obj)
    if go ~= nil then
        local tr = safe_handle_call(gameobject_get_transform, go)
        if tr ~= nil then
            local xyz = vector_to_xyz(safe_handle_call(transform_get_position, tr))
            if xyz ~= nil then return xyz end
        end
    end

    return nil
end

local function distance3(a, b)
    if a == nil or b == nil then return nil end
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function distance_strength(distance, near_distance, max_distance)
    if distance == nil then return 1.0 end
    if distance <= near_distance then return 1.0 end
    if distance >= max_distance then return 0.0 end
    return 1.0 - ((distance - near_distance) / (max_distance - near_distance))
end

local function impact_strength_from_speed(peak_down_speed)
    local speed = math.abs(peak_down_speed)
    if speed < HARD_IMPACT_MIN_SPEED then return 0.0 end

    local t =
        (speed - HARD_IMPACT_MIN_SPEED) /
        (FULL_IMPACT_SPEED - HARD_IMPACT_MIN_SPEED)

    return 0.35 + 0.65 * clamp(t, 0.0, 1.0)
end

local function player_hit_strength(damage, max_hp)
    if max_hp == nil or max_hp <= 0 then
        return 0.50
    end

    local fraction = clamp(damage / max_hp, 0.0, 1.0)
    local t = clamp(
        fraction / PLAYER_HIT_FULL_DAMAGE_FRACTION,
        0.0,
        1.0
    )

    return clamp(1.0 - ((1.0 - t) * (1.0 - t)), 0.0, 1.0)
end

local function player_attack_hit_strength(max_damage, hit_count)
    local damage = math.max(0.0, tonumber(max_damage) or 0.0)
    local count = math.max(1, tonumber(hit_count) or 1)

    local strength =
        0.25 +
        0.75 * (1.0 - math.exp(-damage / PLAYER_ATTACK_DAMAGE_SCALE))

    local multi_bonus = math.min(
        PLAYER_ATTACK_MAX_MULTI_BONUS,
        math.max(0, count - 1) * PLAYER_ATTACK_MULTI_HIT_BONUS
    )

    return clamp(
        math.max(PLAYER_ATTACK_MIN_STRENGTH, strength + multi_bonus),
        0.0,
        1.0
    )
end

local function send_event(name, detail)
    H.bridge_seq = H.bridge_seq + 1

    local payload =
        tostring(H.bridge_seq) .. "|" ..
        tostring(name) .. "|" ..
        string.format("%.6f", os.clock()) .. "|" ..
        tostring(detail or "-")

    pcall(function()
        fs.write(BRIDGE_FILE, payload)
    end)
end

-- Outgoing attack hook
local function install_damage_display_hook()
    local gui_type = sdk.find_type_definition("snow.gui.GuiManager")
    if gui_type == nil then return end

    local damage_method = gui_type:get_method("setDamageDisp")
    if damage_method == nil then return end

    sdk.hook(
        damage_method,
        function(args)
            local ok_damage, damage = pcall(function()
                return sdk.to_int64(args[4])
            end)

            local ok_type, raw_color_type = pcall(function()
                return sdk.to_int64(args[5])
            end)

            if not ok_damage or damage == nil
                or not ok_type or raw_color_type == nil
            then
                return
            end

            damage = tonumber(damage)
            if damage == nil or damage <= 0 then return end

            local color_type = raw_color_type & 0xFFFFFFFF

            local stock_marionette = false
            local ok_stock, raw_stock = pcall(function()
                return sdk.to_int64(args[6])
            end)

            if ok_stock and raw_stock ~= nil then
                stock_marionette = ((raw_stock & 0xFFFFFFFF) ~= 0)
            end

            if not LOCAL_PLAYER_DAMAGE_COLOR_TYPES[color_type]
                or stock_marionette
            then
                return
            end

            if color_type == 1 then
                H.outgoing_pending_red = true
            end

            H.outgoing_pending_count = H.outgoing_pending_count + 1
            H.outgoing_pending_sum = H.outgoing_pending_sum + damage

            if damage > H.outgoing_pending_max then
                H.outgoing_pending_max = damage
            end
        end,
        function(retval)
            return retval
        end
    )
end

local function flush_outgoing_attack_hits()
    if H.outgoing_pending_count <= 0 then return end

    local count = H.outgoing_pending_count
    local max_damage = H.outgoing_pending_max
    local sum_damage = H.outgoing_pending_sum
    local is_red = H.outgoing_pending_red == true

    H.outgoing_pending_count = 0
    H.outgoing_pending_max = 0.0
    H.outgoing_pending_sum = 0.0
    H.outgoing_pending_red = false

    local strength = player_attack_hit_strength(max_damage, count)
    local event_name = is_red
        and "PLAYER_ATTACK_HIT_RED"
        or "PLAYER_ATTACK_HIT_WHITE"

    send_event(
        event_name,
        string.format(
            "strength=%.3f,maxDamage=%.3f,sumDamage=%.3f,hitCount=%d",
            strength,
            max_damage,
            sum_damage,
            count
        )
    )
end

-- Roar signatures / monster state
local function ensure_roar_signatures(type_name)
    if learned_roar_signatures[type_name] == nil then
        learned_roar_signatures[type_name] = {}

        local seeds = seed_roar_signatures[type_name]
        if seeds ~= nil then
            for k, v in pairs(seeds) do
                learned_roar_signatures[type_name][k] = v
            end
        end
    end

    return learned_roar_signatures[type_name]
end

local function sig_key(action_no, motion_id)
    return tostring(action_no) .. ":" .. tostring(motion_id)
end

local function state_key(index, monster)
    return tostring(index) .. ":" .. tostring(monster)
end

local function create_state(index, monster)
    local type_name = get_type_name(monster)

    ensure_roar_signatures(type_name)

    return {
        index = index,
        monster = monster,
        type_name = type_name,

        action_no = nil,
        motion_id = nil,
        last_action_no = nil,

        roar_raw = false,
        roar_constant = false,
        roar_signal = false,
        last_roar_signal = false,
        last_roar_time = -9999.0,

        distance_to_player = nil,

        last_pos = nil,
        last_sample_time = nil,
        vertical_speed = 0.0,
        raw_vertical_speed = 0.0,
        previous_raw_vertical_speed = 0.0,

        falling = false,
        fall_start_time = nil,
        fall_start_y = nil,
        lowest_y = nil,
        fall_drop = 0.0,
        max_down_speed = 0.0,
        last_landing_time = -9999.0,
    }
end

local function get_state(index, monster)
    local key = state_key(index, monster)

    if H.states[key] == nil then
        H.states[key] = create_state(index, monster)
    end

    return H.states[key]
end

local function learn_roar_signature(s)
    if s.action_no == nil or s.motion_id == nil then return end
    ensure_roar_signatures(s.type_name)[sig_key(s.action_no, s.motion_id)] = true
end

local function is_known_roar_signature(s)
    if s.action_no == nil or s.motion_id == nil then return false end
    return ensure_roar_signatures(s.type_name)[sig_key(s.action_no, s.motion_id)] == true
end

local function trigger_roar(s, source)
    local now = os.clock()
    if now - s.last_roar_time < ROAR_EVENT_COOLDOWN then return end
    s.last_roar_time = now

    local distance = s.distance_to_player
    local strength = distance_strength(
        distance,
        ROAR_NEAR_DISTANCE,
        ROAR_MAX_DISTANCE
    )

    if strength < MIN_OUTPUT_STRENGTH then return end

    send_event(
        "ROAR",
        string.format(
            "strength=%.3f,distance=%.3f,slot=%d,type=%s,source=%s",
            strength,
            distance or -1,
            s.index,
            s.type_name,
            source
        )
    )
end

-- Monster landing
local function reset_fall_state(s)
    s.falling = false
    s.fall_start_time = nil
    s.fall_start_y = nil
    s.lowest_y = nil
    s.fall_drop = 0.0
    s.max_down_speed = 0.0
end

local function begin_fall(s, now, current_y)
    s.falling = true
    s.fall_start_time = now
    s.fall_start_y = s.last_pos ~= nil and s.last_pos.y or current_y
    s.lowest_y = current_y
    s.fall_drop = math.max(0.0, s.fall_start_y - current_y)
    s.max_down_speed = s.raw_vertical_speed
end

local function evaluate_landing(s, now, reason)
    local duration = now - (s.fall_start_time or now)
    local impact_strength = impact_strength_from_speed(s.max_down_speed)
    local distance = s.distance_to_player
    local distance_scale = distance_strength(
        distance,
        LAND_NEAR_DISTANCE,
        LAND_MAX_DISTANCE
    )
    local final_strength = impact_strength * distance_scale

    if impact_strength <= 0.0 or final_strength < MIN_OUTPUT_STRENGTH then
        reset_fall_state(s)
        return
    end

    s.last_landing_time = now

    send_event(
        "HEAVY_LAND",
        string.format(
            "strength=%.3f,distance=%.3f,impact=%.3f,peakVy=%.3f,drop=%.3f,duration=%.3f,reason=%s,slot=%d,type=%s",
            final_strength,
            distance or -1,
            impact_strength,
            s.max_down_speed,
            s.fall_drop,
            duration,
            reason,
            s.index,
            s.type_name
        )
    )

    reset_fall_state(s)
end

local function update_monster_vertical_motion(s)
    local now = os.clock()
    local pos = get_world_position(s.monster)
    if pos == nil then return end

    s.distance_to_player = distance3(pos, H.player_pos)

    if s.last_pos == nil or s.last_sample_time == nil then
        s.last_pos = pos
        s.last_sample_time = now
        return
    end

    local dt = now - s.last_sample_time
    if dt <= 0.0005 or dt > 0.25 then
        s.last_pos = pos
        s.last_sample_time = now
        return
    end

    local raw_vy = (pos.y - s.last_pos.y) / dt

    s.previous_raw_vertical_speed = s.raw_vertical_speed
    s.raw_vertical_speed = raw_vy
    s.vertical_speed = s.vertical_speed * 0.40 + raw_vy * 0.60

    if not s.falling then
        if s.vertical_speed <= FALL_START_SPEED then
            begin_fall(s, now, pos.y)
        end
    else
        if pos.y < (s.lowest_y or pos.y) then
            s.lowest_y = pos.y
        end

        if s.fall_start_y ~= nil and s.lowest_y ~= nil then
            s.fall_drop = math.max(0.0, s.fall_start_y - s.lowest_y)
        end

        if raw_vy < s.max_down_speed then
            s.max_down_speed = raw_vy
        end

        local duration = now - (s.fall_start_time or now)
        local enough_motion =
            duration >= MIN_FALL_SECONDS and
            duration <= MAX_FALL_SECONDS and
            s.fall_drop >= MIN_DROP_DISTANCE

        local cooldown_ok =
            now - s.last_landing_time >= LANDING_COOLDOWN

        local in_landing_window =
            raw_vy >= LANDING_WINDOW_MIN_VY and
            raw_vy <= LANDING_WINDOW_MAX_VY

        local deceleration = raw_vy - s.previous_raw_vertical_speed
        local sharp_stop =
            s.max_down_speed <= -HARD_IMPACT_MIN_SPEED and
            deceleration >= IMPACT_DECELERATION_DELTA and
            raw_vy >= LANDING_WINDOW_MIN_VY

        if enough_motion and cooldown_ok and in_landing_window then
            evaluate_landing(s, now, "velocity-window")
        elseif enough_motion and cooldown_ok and sharp_stop then
            evaluate_landing(s, now, "sharp-deceleration")
        elseif duration > MAX_FALL_SECONDS then
            reset_fall_state(s)
        end
    end

    s.last_pos = pos
    s.last_sample_time = now
end

-- Player landing
local function reset_player_fall()
    H.player_falling = false
    H.player_fall_start_time = nil
    H.player_fall_start_y = nil
    H.player_lowest_y = nil
    H.player_fall_drop = 0.0
    H.player_peak_down_speed = 0.0
end

local function player_landing_strength(drop, peak_vy)
    local speed = math.abs(peak_vy)

    if drop < PLAYER_MIN_LAND_DROP
        or speed < PLAYER_HARD_LAND_MIN_SPEED
    then
        return 0.0
    end

    local drop_t = clamp(
        (drop - PLAYER_MIN_LAND_DROP) /
        (PLAYER_FULL_LAND_DROP - PLAYER_MIN_LAND_DROP),
        0.0,
        1.0
    )

    local speed_t = clamp(
        (speed - PLAYER_HARD_LAND_MIN_SPEED) /
        (PLAYER_FULL_LAND_SPEED - PLAYER_HARD_LAND_MIN_SPEED),
        0.0,
        1.0
    )

    local combined = (speed_t * 0.62) + (drop_t * 0.38)
    local curved = combined * combined * (3.0 - 2.0 * combined)

    return clamp(0.30 + (0.70 * curved), 0.30, 1.00)
end

local function trigger_player_landing(now, reason)
    local duration = now - (H.player_fall_start_time or now)
    local strength = player_landing_strength(
        H.player_fall_drop,
        H.player_peak_down_speed
    )

    if strength > 0.0 then
        H.player_last_landing_time = now

        send_event(
            "PLAYER_LAND",
            string.format(
                "strength=%.3f,drop=%.3f,peakVy=%.3f,duration=%.3f,reason=%s",
                strength,
                H.player_fall_drop,
                H.player_peak_down_speed,
                duration,
                reason
            )
        )
    end

    reset_player_fall()
end

local function update_player_landing(pos)
    if pos == nil then
        H.player_last_pos = nil
        H.player_last_sample_time = nil
        reset_player_fall()
        return
    end

    local now = os.clock()

    if H.player_last_pos == nil or H.player_last_sample_time == nil then
        H.player_last_pos = pos
        H.player_last_sample_time = now
        return
    end

    local dt = now - H.player_last_sample_time
    if dt <= 0.0005 or dt > 0.25 then
        H.player_last_pos = pos
        H.player_last_sample_time = now
        return
    end

    local raw_vy = (pos.y - H.player_last_pos.y) / dt

    H.player_prev_raw_vy = H.player_raw_vy
    H.player_raw_vy = raw_vy
    H.player_smoothed_vy = H.player_smoothed_vy * 0.40 + raw_vy * 0.60

    if not H.player_falling then
        if H.player_smoothed_vy <= PLAYER_FALL_START_SPEED then
            H.player_falling = true
            H.player_fall_start_time = now
            H.player_fall_start_y = H.player_last_pos.y
            H.player_lowest_y = pos.y
            H.player_fall_drop = math.max(
                0.0,
                H.player_fall_start_y - pos.y
            )
            H.player_peak_down_speed = raw_vy
        end
    else
        if pos.y < (H.player_lowest_y or pos.y) then
            H.player_lowest_y = pos.y
        end

        if H.player_fall_start_y ~= nil and H.player_lowest_y ~= nil then
            H.player_fall_drop = math.max(
                0.0,
                H.player_fall_start_y - H.player_lowest_y
            )
        end

        if raw_vy < H.player_peak_down_speed then
            H.player_peak_down_speed = raw_vy
        end

        local duration = now - (H.player_fall_start_time or now)
        local in_landing_window =
            raw_vy >= PLAYER_LANDING_WINDOW_MIN_VY and
            raw_vy <= PLAYER_LANDING_WINDOW_MAX_VY

        local deceleration = raw_vy - H.player_prev_raw_vy
        local sharp_stop =
            H.player_peak_down_speed <= -PLAYER_HARD_LAND_MIN_SPEED and
            deceleration >= PLAYER_LANDING_DECEL_DELTA and
            raw_vy >= PLAYER_LANDING_WINDOW_MIN_VY

        local minimums_met =
            duration >= PLAYER_MIN_FALL_SECONDS and
            H.player_fall_drop >= PLAYER_MIN_LAND_DROP and
            math.abs(H.player_peak_down_speed) >= PLAYER_HARD_LAND_MIN_SPEED

        local cooldown_ok =
            now - H.player_last_landing_time >= PLAYER_LANDING_COOLDOWN

        if minimums_met and cooldown_ok and in_landing_window then
            trigger_player_landing(now, "velocity-window")
        elseif minimums_met and cooldown_ok and sharp_stop then
            trigger_player_landing(now, "sharp-deceleration")
        elseif duration > PLAYER_MAX_FALL_SECONDS then
            reset_player_fall()
        end
    end

    H.player_last_pos = pos
    H.player_last_sample_time = now
end

-- Player position / incoming damage
local function update_player()
    H.player = get_local_player()

    if H.player == nil then
        H.player_pos = nil
        H.player_hp_last = nil
        H.player_last_pos = nil
        H.player_last_sample_time = nil
        reset_player_fall()
        return
    end

    local pos = get_world_position(H.player)
    H.player_pos = pos
    update_player_landing(pos)

    local player_data = safe_call(H.player, "get_PlayerData")
    if player_data == nil then return end

    local ok_hp, hp = pcall(function()
        return player_data:get_field("_r_Vital")
    end)

    local ok_max, max_hp = pcall(function()
        return player_data:get_field("_vitalMax")
    end)

    if not ok_hp or hp == nil then return end

    hp = tonumber(hp)
    max_hp = ok_max and tonumber(max_hp) or nil

    if H.player_hp_last ~= nil and hp < H.player_hp_last then
        local damage = H.player_hp_last - hp
        local now = os.clock()

        if damage >= PLAYER_HIT_MIN_ABSOLUTE_DAMAGE
            and now - H.last_player_hit_time >= PLAYER_HIT_COOLDOWN
        then
            local strength = player_hit_strength(damage, max_hp)
            local damage_fraction =
                (max_hp ~= nil and max_hp > 0)
                and clamp(damage / max_hp, 0.0, 1.0)
                or 0.0

            H.last_player_hit_time = now

            send_event(
                "PLAYER_HIT",
                string.format(
                    "strength=%.3f,damage=%.3f,maxhp=%.3f,damagePct=%.3f",
                    strength,
                    damage,
                    max_hp or -1,
                    damage_fraction
                )
            )
        end
    end

    H.player_hp_last = hp
end

local function sample_monster(index, monster)
    local s = get_state(index, monster)
    local action_param = safe_call(monster, "get_ActionParam")
    local motion_param = safe_call(monster, "get_MotionParam")

    if action_param ~= nil then
        s.action_no = safe_call(action_param, "get_ActionNo")
        s.roar_raw = safe_call(action_param, "get_IsRoarAction") == true
        s.roar_constant =
            safe_call(action_param, "get_IsRoarActionConstantTime") == true
        s.roar_signal = s.roar_raw or s.roar_constant
    end

    if motion_param ~= nil then
        s.motion_id = safe_call(motion_param, "get_CurrentMotionId")
    end

    local action_changed =
        s.action_no ~= nil and
        s.last_action_no ~= nil and
        s.action_no ~= s.last_action_no

    if s.roar_signal and not s.last_roar_signal then
        learn_roar_signature(s)
        trigger_roar(s, "getter-edge")
    end

    if action_changed
        and is_known_roar_signature(s)
        and not s.roar_signal
    then
        trigger_roar(s, "learned-signature")
    end

    update_monster_vertical_motion(s)

    s.last_roar_signal = s.roar_signal
    s.last_action_no = s.action_no
end

local function sample_all()
    update_player()
    flush_outgoing_attack_hits()

    for i = 0, MAX_BOSS_SLOTS - 1 do
        local monster = get_boss_enemy(i)
        if monster ~= nil then
            sample_monster(i, monster)
        end
    end
end

install_damage_display_hook()

re.on_pre_application_entry("UpdateBehavior", function()
    sample_all()
end)
