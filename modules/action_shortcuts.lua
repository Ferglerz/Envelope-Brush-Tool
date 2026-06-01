-- Passthrough undo/redo: bindings from reaper-kb.ini (GetResourcePath) + GetActionShortcutDesc + REAPER defaults.

local M = {}

local MAIN_SECTION = 0
local CMD_UNDO = 40029
local CMD_REDO = 40030

local PASSTHROUGH_ACTIONS = {
    { id = "undo", cmd = CMD_UNDO },
    { id = "redo", cmd = CMD_REDO },
}

--- reaper-kb.ini KEY modifier flags (shift=4, ctrl/cmd=8, alt/opt=16).
local KB_MOD_SHIFT = 4
local KB_MOD_CTRL = 8
local KB_MOD_ALT = 16

local VK_SHIFT = 16
local VK_LSHIFT = 160
local VK_RSHIFT = 161
local VK_CONTROL = 17
local VK_LCONTROL = 162
local VK_RCONTROL = 163
local VK_MENU = 18
local VK_LMENU = 164
local VK_RMENU = 165

local function trim(s)
    return (tostring(s or ""):match("^%s*(.-)%s*$")) or ""
end

local function vkey_down(state, vk)
    if not state or type(vk) ~= "number" or vk < 1 or vk > #state then
        return false
    end
    return state:byte(vk) == 1
end

local function modifier_vk_down(state, main, left, right)
    return vkey_down(state, main) or vkey_down(state, left) or vkey_down(state, right)
end

local function kb_modifier_flags_match(modifier, vkeys_state)
    modifier = tonumber(modifier) or 0
    local need_shift = (modifier & KB_MOD_SHIFT) ~= 0
    local need_ctrl = (modifier & KB_MOD_CTRL) ~= 0
    local need_alt = (modifier & KB_MOD_ALT) ~= 0
    local shift_down = modifier_vk_down(vkeys_state, VK_SHIFT, VK_LSHIFT, VK_RSHIFT)
    local ctrl_down = modifier_vk_down(vkeys_state, VK_CONTROL, VK_LCONTROL, VK_RCONTROL)
    local alt_down = modifier_vk_down(vkeys_state, VK_MENU, VK_LMENU, VK_RMENU)
    return need_shift == shift_down and need_ctrl == ctrl_down and need_alt == alt_down
end

local function binding_active(binding, vkeys_state)
    if not binding or not binding.vk or not vkeys_state then
        return false
    end
    return vkey_down(vkeys_state, binding.vk) and kb_modifier_flags_match(binding.modifier or 0, vkeys_state)
end

local function add_binding(list, modifier, vk)
    if type(vk) ~= "number" or vk < 1 then
        return
    end
    list[#list + 1] = { modifier = modifier or 0, vk = vk }
end

local function parse_desc_modifier_token(token)
    local lower = trim(token):lower()
    if lower == "shift" then
        return KB_MOD_SHIFT
    end
    if lower == "ctrl" or lower == "control" or lower == "cmd" or lower == "command" or lower == "meta" or lower == "win" or lower == "super" then
        return KB_MOD_CTRL
    end
    if lower == "alt" or lower == "opt" or lower == "option" then
        return KB_MOD_ALT
    end
    return nil
end

local function key_token_to_vk(token)
    token = trim(token):gsub("Num plus", "Num +")
    if token == "" then
        return nil
    end
    local upper = token:upper()
    if #upper == 1 and upper:match("[A-Z0-9]") then
        return upper:byte()
    end
    local specials = {
        F1 = 0x70, F2 = 0x71, F3 = 0x72, F4 = 0x73, F5 = 0x74, F6 = 0x75,
        F7 = 0x76, F8 = 0x77, F9 = 0x78, F10 = 0x79, F11 = 0x7A, F12 = 0x7B,
        ENTER = 0x0D, RETURN = 0x0D, ESC = 0x1B, ESCAPE = 0x1B, SPACE = 0x20,
        TAB = 0x09, BACKSPACE = 0x08, DELETE = 0x2E, DEL = 0x2E,
    }
    return specials[upper]
end

--- Convert GetActionShortcutDesc text to reaper-kb.ini-style modifier flags + VK.
local function binding_from_shortcut_desc(desc)
    desc = trim(desc)
    if desc == "" then
        return nil
    end
    local protected = desc:gsub("Num %+", "Num plus")
    local modifier = 0
    local vk = nil
    if protected:find("+", 1, true) then
        for part in protected:gmatch("[^+]+") do
            local flag = parse_desc_modifier_token(part)
            if flag then
                modifier = modifier | flag
            else
                vk = key_token_to_vk(part)
            end
        end
    else
        vk = key_token_to_vk(protected)
    end
    if not vk then
        return nil
    end
    return { modifier = modifier, vk = vk }
end

local function read_kb_ini_bindings(cmd_id)
    local path = (reaper.GetResourcePath and reaper.GetResourcePath() or "") .. "/reaper-kb.ini"
    local file = io.open(path, "r")
    if not file then
        return {}
    end
    local cmd_str = tostring(cmd_id)
    local bindings = {}
    for line in file:lines() do
        if line:sub(1, 4) == "KEY " then
            local mod, key, act, sec = line:match("^KEY%s+([%-%d]+)%s+([%-%d]+)%s+(%S+)%s+([%-%d]+)")
            if mod and key and act and sec then
                local secn = tonumber(sec) or -1
                if secn == MAIN_SECTION and act == cmd_str then
                    add_binding(bindings, tonumber(mod) or 0, tonumber(key))
                end
            end
        end
    end
    file:close()
    return bindings
end

local function read_api_bindings(section, cmd_id)
    if not reaper.CountActionShortcuts or not reaper.GetActionShortcutDesc then
        return {}
    end
    local count = reaper.CountActionShortcuts(section, cmd_id) or 0
    local bindings = {}
    for i = 0, count - 1 do
        local ok, desc = reaper.GetActionShortcutDesc(section, cmd_id, i)
        if ok and desc and desc ~= "" then
            local binding = binding_from_shortcut_desc(desc)
            if binding then
                bindings[#bindings + 1] = binding
            end
        end
    end
    return bindings
end

local function default_bindings_for_cmd(cmd_id)
    local os_name = (reaper.GetOS and reaper.GetOS()) or ""
    local is_mac = os_name:match("OSX") or os_name:match("macOS")
    if cmd_id == CMD_UNDO then
        return { { modifier = KB_MOD_CTRL, vk = 0x5A } }
    end
    if cmd_id == CMD_REDO then
        if is_mac then
            return { { modifier = KB_MOD_CTRL | KB_MOD_SHIFT, vk = 0x5A } }
        end
        return {
            { modifier = KB_MOD_CTRL, vk = 0x59 },
            { modifier = KB_MOD_CTRL | KB_MOD_SHIFT, vk = 0x5A },
        }
    end
    return {}
end

local function merge_bindings(primary, secondary)
    local out = {}
    local seen = {}
    local function push(list)
        for i = 1, #list do
            local b = list[i]
            local key = string.format("%d:%d", b.modifier or 0, b.vk or 0)
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = b
            end
        end
    end
    push(primary)
    push(secondary)
    return out
end

local function load_action_bindings(cmd_id)
    local from_ini = read_kb_ini_bindings(cmd_id)
    local from_api = read_api_bindings(MAIN_SECTION, cmd_id)
    local merged = merge_bindings(from_ini, from_api)
    if #merged == 0 then
        merged = default_bindings_for_cmd(cmd_id)
    end
    return merged
end

--- Cache undo/redo chords from reaper-kb.ini + action API + REAPER defaults.
function M.refresh_main_passthrough_shortcuts(state)
    state.main_passthrough_shortcuts = {}
    for i = 1, #PASSTHROUGH_ACTIONS do
        local act = PASSTHROUGH_ACTIONS[i]
        state.main_passthrough_shortcuts[#state.main_passthrough_shortcuts + 1] = {
            id = act.id,
            cmd = act.cmd,
            bindings = load_action_bindings(act.cmd),
        }
    end
end

local function binding_pressed_edge(state, binding, prev_field)
    if not reaper.JS_VKeys_GetState then
        return false
    end
    local vkeys_state = reaper.JS_VKeys_GetState(0)
    if type(vkeys_state) ~= "string" then
        return false
    end
    local active = binding_active(binding, vkeys_state)
    local prev = state[prev_field]
    state[prev_field] = active
    if prev == nil then
        return false
    end
    return active and not prev
end

local function run_passthrough_action(action_id)
    if not reaper.Main_OnCommand then
        return
    end
    local cmd = (action_id == "undo") and CMD_UNDO or CMD_REDO
    reaper.Main_OnCommand(cmd, MAIN_SECTION)
end

--- ImGui/defer blocks Main accelerators; honor user undo/redo bindings explicitly.
function M.try_passthrough_main_shortcuts(state)
    if state.is_dragging or state.envelope_stroke_dirty then
        return false
    end
    local actions = state.main_passthrough_shortcuts
    if not actions then
        return false
    end
    for ai = 1, #actions do
        local act = actions[ai]
        for bi = 1, #act.bindings do
            local prev_field = string.format("_passthrough_%s_%d_prev", act.id, bi)
            if binding_pressed_edge(state, act.bindings[bi], prev_field) then
                run_passthrough_action(act.id)
                return true
            end
        end
    end
    return false
end

return M
