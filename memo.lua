-- memo.lua
--
-- A recent files menu for mpv

local options = {
    -- File path gets extended
    history_path = "~~/memo-history.log",

    -- How many entries to display in menu
    entries = 10,

    -- Display navigation to older/newer entries
    pagination = false,

    -- Display files only once
    hide_duplicates = true,

    -- Check if files still exist
    hide_deleted = true,

    -- Display only the latest file from each directory
    hide_same_dir = false,

    -- Date format https://www.lua.org/pil/22.1.html
    timestamp_format = "%Y-%m-%d %H:%M:%S",

    -- Display titles instead of filenames when available
    use_titles = true,

    -- Truncate titles to n characters, 0 to disable
    truncate_titles = 60,

    -- Meant for use in auto profiles
    enabled = true,

    -- Keybinds for vanilla menu
    up_binding = "UP WHEEL_UP",
    down_binding = "DOWN WHEEL_DOWN",
    select_binding = "RIGHT ENTER",
    close_binding = "LEFT ESC",
}

local script_name = mp.get_script_name()

mp.utils = require "mp.utils"
mp.options = require "mp.options"
mp.options.read_options(options, "memo")

local assdraw = require "mp.assdraw"

local osd = mp.create_osd_overlay("ass-events")
osd.z = 2000
local osd_update = nil
local width, height
local margin_top, margin_bottom = 0, 0
local font_size = mp.get_property_number("osd-font-size") or 55

local history_path = mp.command_native({"expand-path", options.history_path})
local history = io.open(history_path, "a+")
local last_state = nil

local event_loop_exhausted = false
local uosc_available = false
local menu_shown = false
local menu_data = nil

function utf8_char_bytes(str, i)
    local char_byte = str:byte(i)
    if char_byte < 0xC0 then
        return 1
    elseif char_byte < 0xE0 then
        return 2
    elseif char_byte < 0xF0 then
        return 3
    elseif char_byte < 0xF8 then
        return 4
    else
        return 1
    end
end

function utf8_iter(str)
    local byte_start = 1
    return function()
        local start = byte_start
        if #str < start then return nil end
        local byte_count = utf8_char_bytes(str, start)
        byte_start = start + byte_count
        return start, str:sub(start, byte_start - 1)
    end
end

function utf8_table(str)
    local t = {}
    local width = 0
    for _, char in utf8_iter(str) do
        width = width + (#char > 2 and 2 or 1)
        table.insert(t, char)
    end
    return t, width
end

function utf8_subwidth(t, start_index, end_index)
    local index = 1
    local substr = ""
    for _, char in ipairs(t) do
        if start_index <= index and index <= end_index then
            local width = #char > 2 and 2 or 1
            index = index + width
            substr = substr .. char
        end
    end
    return substr, index
end

function utf8_subwidth_back(t, num_chars)
    local index = 0
    local substr = ""
    for i = #t, 1, -1 do
        if num_chars > index then
            local width = #t[i] > 2 and 2 or 1
            index = index + width
            substr = t[i] .. substr
        end
    end
    return substr
end

function ass_clean(str)
    str = str:gsub("\\", "\\\239\187\191")
    str = str:gsub("{", "\\{")
    str = str:gsub("}", "\\}")
    return str
end

function shallow_copy(t)
    local t2 = {}
    for k,v in pairs(t) do
        t2[k] = v
    end
    return t2
end

function menu_json(menu_items, native)
    local menu = {
        type = "memo-history",
        title = "History (memo)",
        items = menu_items,
        selected_index = 1,
        on_close = {"script-message-to", script_name, "memo-clear"}
    }

    if native then
        return menu
    end

    local json = mp.utils.format_json(menu)
    return json or "{}"
end

function update_dimensions()
    width, height = mp.get_osd_size()
    osd.res_x = width
    osd.res_y = height
    draw_menu()
end

function update_margins()
    local shared_props = mp.get_property_native("shared-script-properties")
    local val = shared_props["osc-margins"]
    if val then
        -- formatted as "%f,%f,%f,%f" with left, right, top, bottom, each
        -- value being the border size as ratio of the window size (0.0-1.0)
        local vals = {}
        for v in string.gmatch(val, "[^,]+") do
            vals[#vals + 1] = tonumber(v)
        end
        margin_top = vals[3] -- top
        margin_bottom = vals[4] -- bottom
    else
        margin_top = 0
        margin_bottom = 0
    end
    draw_menu()
end

function bind_keys(keys, name, func, opts)
    if not keys then
        mp.add_forced_key_binding(keys, name, func, opts)
        return
    end
    local i = 1
    for key in keys:gmatch("[^%s]+") do
        local prefix = i == 1 and "" or i
        mp.add_forced_key_binding(key, name .. prefix, func, opts)
        i = i + 1
    end
end

function unbind_keys(keys, name)
    if not keys then
        mp.remove_key_binding(name)
        return
    end
    local i = 1
    for key in keys:gmatch("[^%s]+") do
        local prefix = i == 1 and "" or i
        mp.remove_key_binding(name .. prefix)
        i = i + 1
    end
end

function close_menu()
    mp.unobserve_property(update_dimensions)
    mp.unobserve_property(update_margins)
    unbind_keys(options.up_binding, "move_up")
    unbind_keys(options.down_binding, "move_down")
    unbind_keys(options.select_binding, "select")
    unbind_keys(options.close_binding, "close")
    last_state = nil
    menu_data = nil
    menu_shown = false
    osd:update()
    osd.hidden = true
    osd:update()
end

function open_menu()
    menu_shown = true

    update_dimensions()
    mp.observe_property("osd-dimensions", "native", update_dimensions)
    mp.observe_property("video-out-params", "native", update_dimensions)
    mp.observe_property("shared-script-properties", "native", update_margins)

    bind_keys(options.up_binding, "move_up", function()
        menu_data.selected_index = math.max(menu_data.selected_index - 1, 1)
        draw_menu()
    end, { repeatable = true })
    bind_keys(options.down_binding, "move_down", function()
        menu_data.selected_index = math.min(menu_data.selected_index + 1, #menu_data.items)
        draw_menu()
    end, { repeatable = true })
    bind_keys(options.close_binding, "close", close_menu)
    bind_keys(options.select_binding, "select", function()
        local item = menu_data.items[menu_data.selected_index]
        if not item.keep_open then
            close_menu()
        end
        mp.commandv(unpack(item.value))
    end)
    osd.hidden = false
    draw_menu()
end

function draw_menu(delay)
    if not menu_data then return end
    if not menu_shown then
        open_menu()
    end

    local num_options = #menu_data.items > 0 and #menu_data.items + 1 or 1
    menu_data.selected_index = math.min(menu_data.selected_index, #menu_data.items)

    local function get_scrolled_lines()
        local output_height = height - margin_top * height - margin_bottom * height
        local screen_lines = math.max(math.floor(output_height / font_size), 1)
        local max_scroll = math.max(num_options - screen_lines, 0)
        return math.min(math.max(menu_data.selected_index - math.ceil(screen_lines / 2), 0), max_scroll) - 1
    end

    local ass = assdraw.ass_new()
    local curtain_opacity = 0.7

    local alpha = 255 - math.ceil(255 * curtain_opacity)
    ass.text = string.format("{\\pos(0,0)\\r\\an7\\1c&H000000&\\alpha&H%X&}", alpha)
    ass:draw_start()
    ass:rect_cw(0, 0, width, height)
    ass:draw_stop()
    ass:new_event()

    ass:append("{\\pos(10," .. (0.1 * font_size) .. ")\\fs" .. font_size .. "\\bord2\\q2\\b1}History (memo){\\b0}\\N")
    ass:new_event()

    local scrolled_lines = get_scrolled_lines()
    local pos_y = margin_top * height - scrolled_lines * font_size
    local clip_top = math.floor(margin_top * height + font_size + 0.2 * font_size + 0.5)
    local clip_bottom = math.floor((1 - margin_bottom) * height + 0.5)
    local clipping_coordinates = "0," .. clip_top .. "," .. width .. "," .. clip_bottom

    if #menu_data.items > 0 then
        local menu_index = 0
        for i=1, #menu_data.items do
            local item = menu_data.items[i]
            if item.title then
                local icon
                if item.icon == "spinner" then
                    icon = "⟳ "
                elseif item.icon == "navigate_next" then
                    icon = menu_data.selected_index == i and "▶ - " or "▷- "
                elseif item.icon == "navigate_before" then
                    icon = menu_data.selected_index == i and "◀ - " or "◁- "
                else
                    icon = menu_data.selected_index == i and "●  - " or "○ - "
                end
                ass:new_event()
                ass:pos(10, pos_y + menu_index * font_size)
                ass:append("{\\fnmonospace\\an7\\fs" .. font_size .. "\\bord2\\q2}" .. icon .. "{\\r\\an7\\fs" .. font_size .. "\\bord2\\q2\\clip(" .. clipping_coordinates .. ")}" .. ass_clean(item.title) .. "\\N")
                menu_index = menu_index + 1
            end
        end
    else
        ass:pos(10, pos_y)
        ass:append("{\\an7\\fs" .. font_size .. "\\bord2\\q2\\clip(" .. clipping_coordinates .. ")}")
        ass:append("No entries")
    end

    osd_update = nil
    osd.data = ass.text
    osd:update()
end

function get_full_path()
    local path = mp.get_property("path")
    if path == nil then return end

    local directory = path:find("^%a[%a%d-_]+:") == nil and mp.get_property("working-directory", "") or ""
    local full_path = mp.utils.join_path(directory, path)

    return full_path
end

function write_history()
    local full_path = get_full_path()
    local playlist_pos = mp.get_property_number("playlist-pos") or -1
    local title = playlist_pos > -1 and mp.get_property("playlist/"..playlist_pos.."/title") or ""
    local title_length = #title
    local timestamp = os.time()

    -- format: <timestamp>,<title length>,<title>,<path>,<entry length>
    local entry = timestamp .. "," .. (title_length > 0 and title_length or "") .. "," .. title .. "," .. full_path
    local entry_length = #entry

    history:write(entry .. "," .. entry_length, "\n")
    history:flush()
end

function show_history(entries, next_page, prev_page, update, return_items)
    if event_loop_exhausted then return end
    event_loop_exhausted = true

    local should_close = menu_shown and not prev_page and not next_page and not update
    if should_close then
        menu_shown = false
        if uosc_available then
            mp.commandv("script-message-to", "uosc", "open-menu", menu_json({}))
        else
            close_menu()
        end
        if not return_items then
            return
        end
    end

    local max_digits_length = 4 + 1
    local retry_offset = 512
    local menu_items = {}
    local state = (prev_page or next_page) and last_state or {
        known_dirs = {},
        known_files = {},
        existing_files = {},
        lines = {},
        retry = 0,
        pages = {},
        current_page = 1
    }

    history:seek("set")
    for line in history:lines() do
        table.insert(state.lines, line)
    end
    
    if update then
        state.pages = {}
    end

    if last_state then
        if prev_page then
            if state.current_page == 1 then
                return
            end
            state.current_page = state.current_page - 1
        elseif next_page then
            if state.cursor == 0 and not state.pages[state.current_page + 1] then
                return
            end

            state.current_page = state.current_page + 1
        end
    end

    if state.pages[state.current_page] then
        if uosc_available then
            mp.commandv("script-message-to", "uosc", menu_shown and "update-menu" or "open-menu", menu_json(state.pages[state.current_page]))
        elseif menu_data then
            menu_data.items = state.pages[state.current_page]
            draw_menu()
        else
            menu_data = menu_json(state.pages[state.current_page], true)
            draw_menu()
        end
        return
    end

    -- all of these error cases can only happen if the user messes with the history file externally
    local function read_line()
        local line = table.remove(state.lines)
        local timestamp_str, _, title, full_path, _ = line:match("(.*),(.*),(.*),(.*),(.*)")
        if not timestamp_str then
            mp.msg.debug("invalid entry data @ " .. state.cursor)
            return
        end

        local timestamp = tonumber(timestamp_str)
        timestamp = timestamp and os.date(options.timestamp_format, timestamp) or timestamp_str

        local title_length = title_length_str ~= "" and tonumber(title_length_str) or 0

        if options.hide_duplicates and state.known_files[full_path] then
            return
        end
        local dirname, basename

        if full_path:find("^%a[%a%d-_]+:") ~= nil then
            state.existing_files[full_path] = true
            state.known_files[full_path] = true
        elseif options.hide_same_dir then
            dirname, basename = mp.utils.split_path(full_path)
            if state.known_dirs[dirname] then
                return
            end
            if dirname ~= "." then
                state.known_dirs[dirname] = true
            end
        end

        if options.hide_deleted then
            if state.known_files[full_path] and not state.existing_files[full_path] then
                return
            end
            if not state.known_files[full_path] then
                local stat = mp.utils.file_info(full_path)
                if stat then
                    state.existing_files[full_path] = true
                else
                    return
                end
            end
        end

        if not options.use_titles then
            title = ""
        end

        if title == "" then
            local protocol_stripped, matches = full_path:gsub("^%a[%a%d-_]+:[/\\]*", "")
            if matches > 0 then
                title = protocol_stripped
            else
                if not dirname then
                    dirname, basename = mp.utils.split_path(full_path)
                end
                title = basename ~= "" and basename or full_path
            end
        end

        title = title:gsub("\n", " ")

        local title_chars, title_width = utf8_table(title)
        if options.truncate_titles > 0 and title_width > options.truncate_titles then
            local extension = string.match(title, "%.([^.][^.][^.]?[^.]?)$") or ""
            local extra = #extension + 4
            local title_sub, end_index = utf8_subwidth(title_chars, 1, options.truncate_titles - 3 - extra)
            local title_trim = title_sub:gsub("[] ._'()?![]+$", "")
            local around_extension = ""
            if title_trim == "" then
                title_trim = utf8_subwidth(title_chars, 1, options.truncate_titles - 3)
            else
                extra = extra + #title_sub - #title_trim
                around_extension = utf8_subwidth_back(title_chars, extra)
            end
            if title_trim == "" then
                title = utf8_subwidth(title_chars, 1, options.truncate_titles)
            else
                title = title_trim .. "..." .. around_extension
            end
        end

        state.known_files[full_path] = true
        table.insert(menu_items, {title = title, hint = timestamp, value = {"loadfile", full_path}})
    end

    local item_count = -1
    local attempts = 0

    while #menu_items < entries do
        if #state.lines == 0 then
            break
        end

        if osd_update then
            local time = mp.get_time()
            if time > osd_update then
                draw_menu()
            end
        end
        if not return_items and attempts > 0 and attempts % options.entries == 0 and #menu_items ~= item_count then
            item_count = #menu_items
            local temp_items = {unpack(menu_items)}
            for i=1, options.entries - item_count do
                table.insert(temp_items, {value = "ignore", keep_open = true})
            end

            table.insert(temp_items, {title = "Loading...", value = "ignore", italic = "true", muted = "true", icon = "spinner", keep_open = true})

            if next_page and last_state then
                table.insert(temp_items, {value = "ignore", keep_open = true})
            end

            if uosc_available then
                mp.commandv("script-message-to", "uosc", menu_shown and "update-menu" or "open-menu", menu_json(temp_items))
                menu_shown = true
            elseif menu_data then
                menu_data.items = temp_items
                osd_update = mp.get_time() + 0.1
            else
                menu_data = menu_json(temp_items, true)
                osd_update = mp.get_time() + 0.1
            end
        end

        read_line()

        attempts = attempts + 1
    end

    if return_items then
        return menu_items
    end

    if options.pagination and #menu_items > 0 then
        if #state.lines > 0 then
            table.insert(menu_items, {title = "Older entries", value = {"script-binding", "memo-next"}, italic = "true", muted = "true", icon = "navigate_next", keep_open = true})
        end
        if state.current_page ~= 1 then
            table.insert(menu_items, {title = "Newer entries", value = {"script-binding", "memo-prev"}, italic = "true", muted = "true", icon = "navigate_before", keep_open = true})
        end
    end

    state.pages[state.current_page] = menu_items
    last_state = state

    if uosc_available then
        mp.commandv("script-message-to", "uosc", menu_shown and "update-menu" or "open-menu", menu_json(menu_items))
    elseif menu_data then
        menu_data.items = menu_items
        draw_menu()
    else
        menu_data = menu_json(menu_items, true)
        draw_menu()
    end

    menu_shown = true
end

function file_load()
    mp.options.read_options(options, "memo")

    if options.enabled then
        write_history()
    end

    if menu_shown and last_state and last_state.current_page == 1 then
        show_history(options.entries, false, false, true)
    end
end

function idle()
    event_loop_exhausted = false
    if osd_update then
        osd_update = nil
        osd:update()
    end
end

mp.register_script_message("uosc-version", function(version)
    local function semver_comp(v1, v2)
        local v1_iterator = v1:gmatch("%d+")
        local v2_iterator = v2:gmatch("%d+")
        for v2_num_str in v2_iterator do
            local v1_num_str = v1_iterator()
            if not v1_num_str then return true end
            local v1_num = tonumber(v1_num_str)
            local v2_num = tonumber(v2_num_str)
            if v1_num < v2_num then return true end
            if v1_num > v2_num then return false end
        end
        return false
    end

    local min_version = "4.6.0"
    uosc_available = not semver_comp(version, min_version)
end)

function memo_clear()
    if event_loop_exhausted then return end
    last_state = nil
    menu_shown = false
end

function memo_prev()
    show_history(options.entries, false, true)
end

function memo_next()
    show_history(options.entries, true)
end

mp.register_script_message("memo-clear", memo_clear)

mp.command_native_async({"script-message-to", "uosc", "get-version", script_name}, function() end)

mp.add_key_binding(nil, "memo-next", memo_next)
mp.add_key_binding(nil, "memo-prev", memo_prev)
mp.add_key_binding(nil, "memo-last", function()
    if event_loop_exhausted then return end

    local items
    if last_state and last_state.current_page == 1 and options.hide_duplicates and options.hide_deleted and options.entries >= 2 then
        -- menu is open and we for sure have everything we need
        items = last_state.pages[1]
        last_state = nil
        show_history(0, false, false, false, true)
    else
        -- menu is closed or we may not have everything
        local options_bak = shallow_copy(options)
        options.pagination = false
        options.hide_duplicates = true
        options.hide_deleted = true
        last_state = nil
        items = show_history(2, false, false, false, true)
        options = options_bak
    end
    if items then
        local item
        local full_path = get_full_path()
        if #items >= 1 and not items[1].keep_open then
            if items[1].value[2] ~= full_path then
                item = items[1]
            elseif #items >= 2 and not items[2].keep_open and items[2].value[2] ~= full_path then
                item = items[2]
            end
        end

        if item then
            mp.commandv(unpack(item.value))
            return
        end
    end
    mp.osd_message("[memo] no recent files to open")
end)
mp.add_key_binding("h", "memo-history", function()
    if event_loop_exhausted then return end
    last_state = nil
    show_history(options.entries, false)
end)

mp.register_event("file-loaded", file_load)
mp.register_idle(idle)
