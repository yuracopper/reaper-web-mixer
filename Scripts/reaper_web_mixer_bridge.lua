-- REAPER Web Mixer Bridge (ReaScript Daemon)
-- Connects REAPER Web Remote to advanced FX management, plugin parameter tweaks, and send routing.

local APP_VERSION = "1.0.0"
local EXT_SECTION = "reaper_web_mixer"

-- Unique instance ID to ensure only one instance runs at a time
local INSTANCE_ID = tostring(reaper.time_precise()) .. "_" .. tostring(math.random(100000, 999999))
reaper.SetExtState(EXT_SECTION, "running_instance", INSTANCE_ID, false)

-- System metrics & dropout tracking
local current_cpu = 0
local audio_dropouts = 0
local media_dropouts = 0
local last_audio_xrun = 0
local last_media_xrun = 0
if reaper.GetUnderrunTime then
  local ax, mx = reaper.GetUnderrunTime()
  last_audio_xrun = ax or 0
  last_media_xrun = mx or 0
end
local last_clock = os.clock and os.clock() or 0
local last_precise = reaper.time_precise()
local last_heartbeat = 0

-- ============================================================
-- JSON Encoder & Decoder
-- ============================================================

local MAX_DEPTH = 30
local function json_encode(val, depth, visited)
  depth = depth or 0
  if depth > MAX_DEPTH then return '"<max depth>"' end

  local t = type(val)
  if t == "nil" then return "null"
  elseif t == "boolean" then return val and "true" or "false"
  elseif t == "number" then
    if val ~= val or val == math.huge or val == -math.huge then return "null" end
    if val == math.floor(val) and val >= -2147483648 and val <= 2147483647 then
      return string.format("%d", val)
    end
    return string.format("%.6f", val)
  elseif t == "string" then
    val = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return '"' .. val .. '"'
  elseif t == "table" then
    visited = visited or {}
    if visited[val] then return '"<circular>"' end
    visited[val] = true
    local n = #val
    local is_array = true
    if n == 0 and next(val) ~= nil then
      is_array = false
    else
      local count = 0
      for _ in pairs(val) do count = count + 1 end
      if count ~= n then is_array = false end
    end
    if is_array then
      local parts = {}
      for i = 1, n do
        parts[i] = json_encode(val[i], depth + 1, visited)
      end
      visited[val] = nil
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(val) do
        parts[#parts+1] = json_encode(tostring(k), depth + 1, visited) .. ":" .. json_encode(v, depth + 1, visited)
      end
      visited[val] = nil
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

local function json_decode(str)
  if not str or str == "" then return nil end
  local len = #str
  local pos = 1
  local byte = string.byte
  local sub = string.sub
  local find = string.find

  local B_SPACE = 32
  local B_TAB = 9
  local B_NL = 10
  local B_CR = 13
  local B_QUOTE = 34
  local B_BSLASH = 92
  local B_LBRACE = 123
  local B_RBRACE = 125
  local B_LBRACK = 91
  local B_RBRACK = 93
  local B_COLON = 58
  local B_COMMA = 44
  local B_t = 116
  local B_f = 102
  local B_n = 110
  local B_MINUS = 45

  local function skip_ws()
    while pos <= len do
      local b = byte(str, pos)
      if b == B_SPACE or b == B_TAB or b == B_NL or b == B_CR then
        pos = pos + 1
      else
        return
      end
    end
  end

  local parse_value

  local esc_map = {n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/'}

  local function parse_string()
    pos = pos + 1
    local result = {}
    local chunk_start = pos
    while pos <= len do
      local special = find(str, '["\\]', pos)
      if not special then
        pos = len + 1
        return table.concat(result)
      end
      if special > chunk_start then
        result[#result+1] = sub(str, chunk_start, special - 1)
      end
      local b = byte(str, special)
      if b == B_QUOTE then
        pos = special + 1
        return table.concat(result)
      else
        local next_char = sub(str, special + 1, special + 1)
        if esc_map[next_char] then
          result[#result+1] = esc_map[next_char]
          pos = special + 2
          chunk_start = pos
        elseif next_char == 'u' then
          local hex = sub(str, special + 2, special + 5)
          local code = tonumber(hex, 16)
          if code and code < 128 then
            result[#result+1] = string.char(code)
          else
            result[#result+1] = "?"
          end
          pos = special + 6
          chunk_start = pos
        else
          result[#result+1] = next_char
          pos = special + 2
          chunk_start = pos
        end
      end
    end
    return table.concat(result)
  end

  local function parse_number()
    local s = pos
    if byte(str, pos) == B_MINUS then pos = pos + 1 end
    while pos <= len do
      local b = byte(str, pos)
      if (b >= 48 and b <= 57) or b == 46 or b == 101 or b == 69 or b == 43 or b == 45 then
        pos = pos + 1
      else
        break
      end
    end
    return tonumber(sub(str, s, pos - 1))
  end

  local function parse_array()
    pos = pos + 1
    local arr = {}
    skip_ws()
    if pos <= len and byte(str, pos) == B_RBRACK then
      pos = pos + 1
      return arr
    end
    while pos <= len do
      arr[#arr+1] = parse_value()
      skip_ws()
      local b = byte(str, pos)
      if b == B_COMMA then
        pos = pos + 1
      elseif b == B_RBRACK then
        pos = pos + 1
        return arr
      else
        return arr
      end
    end
    return arr
  end

  local function parse_object()
    pos = pos + 1
    local obj = {}
    skip_ws()
    if pos <= len and byte(str, pos) == B_RBRACE then
      pos = pos + 1
      return obj
    end
    while pos <= len do
      skip_ws()
      if byte(str, pos) ~= B_QUOTE then return obj end
      local key = parse_string()
      skip_ws()
      if byte(str, pos) ~= B_COLON then return obj end
      pos = pos + 1
      obj[key] = parse_value()
      skip_ws()
      local b = byte(str, pos)
      if b == B_COMMA then
        pos = pos + 1
      elseif b == B_RBRACE then
        pos = pos + 1
        return obj
      else
        return obj
      end
    end
    return obj
  end

  function parse_value()
    skip_ws()
    if pos > len then return nil end
    local b = byte(str, pos)
    if b == B_QUOTE then return parse_string()
    elseif b == B_LBRACE then return parse_object()
    elseif b == B_LBRACK then return parse_array()
    elseif (b >= 48 and b <= 57) or b == B_MINUS then return parse_number()
    elseif b == B_t and sub(str, pos, pos+3) == "true" then pos = pos + 4; return true
    elseif b == B_f and sub(str, pos, pos+4) == "false" then pos = pos + 5; return false
    elseif b == B_n and sub(str, pos, pos+3) == "null" then pos = pos + 4; return nil
    end
    pos = pos + 1
    return nil
  end

  return parse_value()
end

local function url_decode(str)
  if not str then return "" end
  return str:gsub("+", " "):gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
end

-- ============================================================
-- Track Helper
-- ============================================================

local function get_track_by_index(idx)
  if idx == 0 then
    return reaper.GetMasterTrack(0)
  elseif idx and idx > 0 then
    return reaper.GetTrack(0, idx - 1)
  end
  return nil
end

local function parse_fx_info(raw_name)
  if not raw_name then return "Unknown FX", "" end
  local prefix, body = raw_name:match("^([A-Za-z0-9]+):%s*(.*)$")
  if not prefix then
    prefix = ""
    body = raw_name
  end
  local clean_name, dev = body:match("^(.-)%s*%((.-)%)%s*$")
  if not clean_name then
    clean_name = body
    dev = ""
  end
  if dev == "" and prefix == "JS" then dev = "Cockos JS" end
  return clean_name, dev, prefix
end

local function clean_fx_name(raw_name)
  local clean, _ = parse_fx_info(raw_name)
  return clean
end

local function format_input_name(recinput)
  if recinput == nil or recinput < 0 then
    return "None"
  elseif (recinput & 4096) ~= 0 then
    local dev = (recinput >> 5) & 31
    local ch = recinput & 31
    local dev_str = "All MIDI"
    if dev > 0 and reaper.GetMIDIInputName then
      local _, name = reaper.GetMIDIInputName(dev - 1, "")
      if name and name ~= "" then dev_str = name end
    end
    if ch == 0 then
      return "MIDI: " .. dev_str
    else
      return "MIDI: " .. dev_str .. " (Ch " .. ch .. ")"
    end
  elseif (recinput & 1024) ~= 0 then
    local ch = recinput & 511
    local n1 = reaper.GetInputChannelName and reaper.GetInputChannelName(ch) or ("In " .. tostring(ch + 1))
    local n2 = reaper.GetInputChannelName and reaper.GetInputChannelName(ch + 1) or ("In " .. tostring(ch + 2))
    return n1 .. " / " .. n2
  else
    local n = reaper.GetInputChannelName and reaper.GetInputChannelName(recinput) or ("In " .. tostring(recinput + 1))
    return n
  end
end

-- ============================================================
-- Actions API
-- ============================================================

local actions = {}

function actions.reload()
  reaper.defer(function()
    dofile(reaper.GetResourcePath() .. "/Scripts/reaper_web_mixer_bridge.lua")
  end)
  return { status = "reloading" }
end

function actions.ping()
  return {
    version = APP_VERSION,
    reaper_version = reaper.GetAppVersion(),
    project_tracks = reaper.CountTracks(0)
  }
end

function actions.get_system_stats()
  local ax, mx, cur = 0, 0, 0
  if reaper.GetUnderrunTime then
    ax, mx, cur = reaper.GetUnderrunTime()
  end
  return {
    cpu = current_cpu or 0,
    drops = (audio_dropouts or 0) + (media_dropouts or 0),
    audio_drops = audio_dropouts or 0,
    media_drops = media_dropouts or 0,
    tracks = reaper.CountTracks(0),
    is_playing = (reaper.GetPlayState() & 1) ~= 0,
    is_recording = (reaper.GetPlayState() & 4) ~= 0,
    curtime = cur
  }
end

function actions.reset_dropouts()
  audio_dropouts = 0
  media_dropouts = 0
  if reaper.GetUnderrunTime then
    local ax, mx = reaper.GetUnderrunTime()
    last_audio_xrun = ax or 0
    last_media_xrun = mx or 0
  end
  return { success = true, drops = 0 }
end

function actions.get_track_fx_chain(p)
  local tr_idx = tonumber(p.track_index or 0)
  local tr = get_track_by_index(tr_idx)
  if not tr then return { error = "Track not found" } end

  local count = reaper.TrackFX_GetCount(tr)
  local fx_list = {}
  for i = 0, count - 1 do
    local _, raw_name = reaper.TrackFX_GetFXName(tr, i, "")
    local enabled = reaper.TrackFX_GetEnabled(tr, i)
    local open = reaper.TrackFX_GetOpen(tr, i)
    local _, preset = reaper.TrackFX_GetPreset(tr, i, "")
    local num_params = reaper.TrackFX_GetNumParams(tr, i)

    table.insert(fx_list, {
      index = i,
      raw_name = raw_name,
      name = clean_fx_name(raw_name),
      enabled = enabled,
      open = open,
      preset = preset or "",
      num_params = num_params
    })
  end

  local _, tr_name = reaper.GetTrackName(tr)
  return {
    track_index = tr_idx,
    track_name = tr_name,
    fx_count = count,
    fx = fx_list
  }
end

function actions.get_fx_params(p)
  local tr_idx = tonumber(p.track_index or 0)
  local fx_idx = tonumber(p.fx_index or 0)
  local tr = get_track_by_index(tr_idx)
  if not tr then return { error = "Track not found" } end

  local total = reaper.TrackFX_GetNumParams(tr, fx_idx)
  local offset = tonumber(p.offset or 0)
  local count = tonumber(p.count or 24) -- limit per page to keep JSON light
  if count > 40 then count = 40 end

  local params = {}
  local limit = math.min(total - 1, offset + count - 1)
  for i = offset, limit do
    local _, name = reaper.TrackFX_GetParamName(tr, fx_idx, i, "")
    local val, minval, maxval = reaper.TrackFX_GetParam(tr, fx_idx, i)
    local _, fmt = reaper.TrackFX_FormatParamValueNormalized(tr, fx_idx, i, val, "")
    if not fmt or fmt == "" then
      fmt = string.format("%.2f", val)
    end
    table.insert(params, {
      index = i,
      name = name,
      value = val,
      min = minval,
      max = maxval,
      formatted = fmt
    })
  end

  local _, raw_name = reaper.TrackFX_GetFXName(tr, fx_idx, "")
  local _, preset = reaper.TrackFX_GetPreset(tr, fx_idx, "")
  local enabled = reaper.TrackFX_GetEnabled(tr, fx_idx)

  return {
    track_index = tr_idx,
    fx_index = fx_idx,
    name = clean_fx_name(raw_name),
    preset = preset or "",
    enabled = enabled,
    total_params = total,
    offset = offset,
    params = params
  }
end

function actions.set_fx_param(p)
  local tr = get_track_by_index(tonumber(p.track_index or 0))
  if not tr then return { error = "Track not found" } end
  local fx_idx = tonumber(p.fx_index or 0)
  local param_idx = tonumber(p.param_index or 0)
  local val = tonumber(p.value or 0)

  reaper.TrackFX_SetParam(tr, fx_idx, param_idx, val)
  local _, fmt = reaper.TrackFX_FormatParamValueNormalized(tr, fx_idx, param_idx, val, "")
  return {
    track_index = p.track_index,
    fx_index = fx_idx,
    param_index = param_idx,
    value = val,
    formatted = fmt
  }
end

function actions.toggle_fx(p)
  local tr = get_track_by_index(tonumber(p.track_index or 0))
  if not tr then return { error = "Track not found" } end
  local fx_idx = tonumber(p.fx_index or 0)
  local enabled = p.enabled
  if enabled == nil then
    enabled = not reaper.TrackFX_GetEnabled(tr, fx_idx)
  end
  reaper.TrackFX_SetEnabled(tr, fx_idx, enabled)
  return {
    track_index = p.track_index,
    fx_index = fx_idx,
    enabled = reaper.TrackFX_GetEnabled(tr, fx_idx)
  }
end

function actions.add_fx(p)
  local tr = get_track_by_index(tonumber(p.track_index or 0))
  if not tr then return { error = "Track not found" } end
  local fx_name = tostring(p.fx_name or "")
  if fx_name == "" then return { error = "Empty fx_name" } end

  -- instantiate = -1 appends to chain
  local res_idx = reaper.TrackFX_AddByName(tr, fx_name, false, -1)
  if res_idx < 0 then
    -- Try without VST/AU prefix if failed
    res_idx = reaper.TrackFX_AddByName(tr, clean_fx_name(fx_name), false, -1)
  end

  reaper.Undo_OnStateChangeEx2(0, "Add FX " .. fx_name, -1, -1)
  return {
    success = (res_idx >= 0),
    fx_index = res_idx,
    track_index = p.track_index
  }
end

function actions.remove_fx(p)
  local tr = get_track_by_index(tonumber(p.track_index or 0))
  if not tr then return { error = "Track not found" } end
  local fx_idx = tonumber(p.fx_index or 0)
  local deleted = reaper.TrackFX_Delete(tr, fx_idx)
  reaper.Undo_OnStateChangeEx2(0, "Remove FX", -1, -1)
  return { success = deleted, track_index = p.track_index }
end

function actions.reorder_fx(p)
  local tr = get_track_by_index(tonumber(p.track_index or 0))
  if not tr then return { error = "Track not found" } end
  local src = tonumber(p.src_index or 0)
  local dst = tonumber(p.dst_index or 0)
  local res = reaper.TrackFX_CopyToTrack(tr, src, tr, dst, true)
  return { success = res, track_index = p.track_index }
end

function actions.show_fx_ui(p)
  local tr = get_track_by_index(tonumber(p.track_index or 0))
  if not tr then return { error = "Track not found" } end
  local fx_idx = tonumber(p.fx_index or 0)
  local show = p.show
  if show == nil then
    show = not reaper.TrackFX_GetOpen(tr, fx_idx)
  end
  -- 3 = show floating window, 2 = hide floating window
  reaper.TrackFX_Show(tr, fx_idx, show and 3 or 2)
  return { success = true, open = show }
end

function actions.navigate_preset(p)
  local tr = get_track_by_index(tonumber(p.track_index or 0))
  if not tr then return { error = "Track not found" } end
  local fx_idx = tonumber(p.fx_index or 0)
  local dir = tonumber(p.dir or 1)
  reaper.TrackFX_NavigatePresets(tr, fx_idx, dir)
  local _, preset = reaper.TrackFX_GetPreset(tr, fx_idx, "")
  return { success = true, preset = preset or "" }
end

function actions.get_detailed_sends(p)
  local tr_idx = tonumber(p.track_index or 0)
  local tr = get_track_by_index(tr_idx)
  if not tr then return { error = "Track not found" } end

  local num_sends = reaper.GetTrackNumSends(tr, 0)
  local sends = {}
  for i = 0, num_sends - 1 do
    local dst_tr = reaper.GetTrackSendInfo_Value(tr, 0, i, "P_DESTTRACK")
    local dst_idx = -1
    local dst_name = "Hardware Out"
    if dst_tr and dst_tr ~= 0 then
      dst_idx = math.floor(reaper.GetMediaTrackInfo_Value(dst_tr, "IP_TRACKNUMBER"))
      local _, name = reaper.GetTrackName(dst_tr)
      dst_name = name
    end
    local vol = reaper.GetTrackSendInfo_Value(tr, 0, i, "D_VOL")
    local pan = reaper.GetTrackSendInfo_Value(tr, 0, i, "D_PAN")
    local mute = reaper.GetTrackSendInfo_Value(tr, 0, i, "B_MUTE") > 0

    table.insert(sends, {
      send_index = i,
      dest_track_index = dst_idx,
      dest_track_name = dst_name,
      volume = vol,
      pan = pan,
      mute = mute
    })
  end

  local num_recvs = reaper.GetTrackNumSends(tr, -1)
  local recvs = {}
  for i = 0, num_recvs - 1 do
    local src_tr = reaper.GetTrackSendInfo_Value(tr, -1, i, "P_SRCTRACK")
    local src_idx = -1
    local src_name = "Unknown"
    if src_tr and src_tr ~= 0 then
      src_idx = math.floor(reaper.GetMediaTrackInfo_Value(src_tr, "IP_TRACKNUMBER"))
      local _, name = reaper.GetTrackName(src_tr)
      src_name = name
    end
    local vol = reaper.GetTrackSendInfo_Value(tr, -1, i, "D_VOL")
    local pan = reaper.GetTrackSendInfo_Value(tr, -1, i, "D_PAN")
    local mute = reaper.GetTrackSendInfo_Value(tr, -1, i, "B_MUTE") > 0
    table.insert(recvs, {
      recv_index = i,
      src_track_index = src_idx,
      src_track_name = src_name,
      volume = vol,
      pan = pan,
      mute = mute
    })
  end

  return {
    track_index = tr_idx,
    sends = sends,
    receives = recvs
  }
end

function actions.create_send(p)
  local src_idx = tonumber(p.src_track or 0)
  local dst_idx = tonumber(p.dst_track or 0)
  local src = get_track_by_index(src_idx)
  local dst = get_track_by_index(dst_idx)
  if not src or not dst then return { error = "Invalid track index" } end

  local send_idx = reaper.CreateTrackSend(src, dst)
  reaper.Undo_OnStateChangeEx2(0, "Create Track Send", -1, -1)
  return {
    success = (send_idx >= 0),
    send_index = send_idx,
    src_track = src_idx,
    dst_track = dst_idx
  }
end

function actions.remove_send(p)
  local src_idx = tonumber(p.src_track or 0)
  local send_idx = tonumber(p.send_index or 0)
  local src = get_track_by_index(src_idx)
  if not src then return { error = "Track not found" } end

  local ok = reaper.RemoveTrackSend(src, 0, send_idx)
  reaper.Undo_OnStateChangeEx2(0, "Remove Track Send", -1, -1)
  return { success = ok }
end

function actions.search_fx(p)
  local q = tostring(p.query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local category = tostring(p.category or ""):lower()
  local offset = tonumber(p.offset or 0)
  if offset < 0 then offset = 0 end
  local limit = tonumber(p.limit or 100)
  if limit > 150 then limit = 150 end
  if limit < 1 then limit = 50 end

  local results = {}
  local total_matches = 0

  if reaper.EnumInstalledFX then
    local i = 0
    while true do
      local retval, name, ident = reaper.EnumInstalledFX(i)
      if not retval or not name or name == "" then break end
      local name_lower = name:lower()

      local match = true
      if q ~= "" and not name_lower:find(q, 1, true) then
        match = false
      end

      if match and category ~= "" and category ~= "all" then
        if category == "waves" and not name_lower:find("waves", 1, true) then
          match = false
        elseif category == "fabfilter" and not name_lower:find("fabfilter", 1, true) then
          match = false
        elseif category == "cockos" and not (name_lower:find("cockos", 1, true) or name_lower:find("rea", 1, true)) then
          match = false
        elseif category == "valhalla" and not name_lower:find("valhalla", 1, true) then
          match = false
        elseif category == "izotope" and not (name_lower:find("ozone", 1, true) or name_lower:find("rx 11", 1, true) or name_lower:find("izotope", 1, true)) then
          match = false
        elseif category == "js" and not name:find("^JS:") then
          match = false
        elseif category == "instruments" and not (name_lower:find("kontakt", 1, true) or name_lower:find("synth", 1, true) or name_lower:find("serum", 1, true) or name_lower:find("vital", 1, true) or name_lower:find("piano", 1, true) or name_lower:find("drum", 1, true) or name_lower:find("omnisphere", 1, true)) then
          match = false
        end
      end

      if match then
        total_matches = total_matches + 1
        if total_matches > offset and #results < limit then
          local clean_name, dev = parse_fx_info(name)
          table.insert(results, {
            name = clean_name,
            full = name,
            dev = dev
          })
        end
      end
      i = i + 1
      if i > 35000 then break end
    end
  end
  return {
    query = q,
    category = category,
    offset = offset,
    limit = limit,
    count = #results,
    total = total_matches,
    has_more = (offset + #results < total_matches),
    results = results
  }
end

-- Curated list of popular installed FX + quick categories
function actions.get_popular_fx(p)
  local list = {
    { category = "Cockos Essentials", plugins = {
      { name = "ReaEQ", full = "VST: ReaEQ (Cockos)", desc = "Parametric EQ" },
      { name = "ReaComp", full = "VST: ReaComp (Cockos)", desc = "Versatile Compressor" },
      { name = "ReaDelay", full = "VST: ReaDelay (Cockos)", desc = "Multi-tap Delay" },
      { name = "ReaGate", full = "VST: ReaGate (Cockos)", desc = "Noise Gate" },
      { name = "ReaLimit", full = "VST: ReaLimit (Cockos)", desc = "Brickwall Limiter" },
      { name = "ReaXcomp", full = "VST: ReaXcomp (Cockos)", desc = "Multiband Compressor" },
      { name = "ReaTune", full = "VST: ReaTune (Cockos)", desc = "Pitch Correction & Tuner" },
      { name = "ReaPitch", full = "VST: ReaPitch (Cockos)", desc = "Pitch Shifter" },
      { name = "ReaVerbate", full = "VST: ReaVerbate (Cockos)", desc = "Algorithmic Reverb" }
    }},
    { category = "Waves Classics", plugins = {
      { name = "CLA-76 Compressor", full = "VST3: CLA-76 Stereo (Waves)", desc = "Fast FET Compressor" },
      { name = "CLA-2A Compressor", full = "VST3: CLA-2A Stereo (Waves)", desc = "Smooth Optical Compressor" },
      { name = "SSL G-Master Bus Comp", full = "VST3: SSL G-Master Buss Compressor Stereo (Waves)", desc = "Classic Mixbus Glue" },
      { name = "SSL E-Channel", full = "VST3: SSL E-Channel Stereo (Waves)", desc = "Console Strip (EQ/Dyn)" },
      { name = "H-Delay Hybrid Delay", full = "VST3: H-Delay Stereo (Waves)", desc = "Versatile Analog/Digital Delay" },
      { name = "Renaissance Compressor", full = "VST3: Renaissance Compressor Stereo (Waves)", desc = "Warm Track Compressor" },
      { name = "Renaissance Vox", full = "VST3: Renaissance Vox Stereo (Waves)", desc = "One-knob Vocal Dynamics" },
      { name = "Renaissance Bass", full = "VST3: Renaissance Bass Stereo (Waves)", desc = "Low-end Enhancement" },
      { name = "L2 Ultramaximizer", full = "VST3: L2 Stereo (Waves)", desc = "Peak Limiter" },
      { name = "API-2500 Compressor", full = "VST3: API-2500 Stereo (Waves)", desc = "Punchy VCA Bus Compressor" },
      { name = "API-550A EQ", full = "VST3: API-550A Stereo (Waves)", desc = "3-Band Vintage EQ" },
      { name = "PuigTec EQP1A", full = "VST3: PuigTec EQP1A Stereo (Waves)", desc = "Passive Tube Equalizer" },
      { name = "Vocal Rider", full = "VST3: Vocal Rider Stereo (Waves)", desc = "Automatic Vocal Leveler" },
      { name = "Abbey Road TG12345", full = "VST3: Abbey Road EMI TG12345 Ch Stereo (Waves)", desc = "Abbey Road Desk" },
      { name = "Abbey Road J37 Tape", full = "VST3: Abbey Road J37 Tape Stereo (Waves)", desc = "Analog Tape Saturation" }
    }},
    { category = "FabFilter Pro", plugins = {
      { name = "FabFilter Pro-Q 3", full = "VST: FabFilter Pro-Q 3 (FabFilter)", desc = "Industry Standard EQ" },
      { name = "FabFilter Pro-C 2", full = "VST: FabFilter Pro-C 2 (FabFilter)", desc = "Mastering & Track Compressor" },
      { name = "FabFilter Pro-L 2", full = "VST: FabFilter Pro-L 2 (FabFilter)", desc = "True Peak Limiter" },
      { name = "FabFilter Pro-MB", full = "VST: FabFilter Pro-MB (FabFilter)", desc = "Multiband Dynamics" },
      { name = "FabFilter Pro-R 2", full = "VST: FabFilter Pro-R 2 (FabFilter)", desc = "Acoustic Reverb" },
      { name = "FabFilter Saturn 2", full = "VST: FabFilter Saturn 2 (FabFilter)", desc = "Multiband Saturation" },
      { name = "FabFilter Pro-DS", full = "VST: FabFilter Pro-DS (FabFilter)", desc = "Intelligent De-Esser" },
      { name = "FabFilter Pro-G", full = "VST: FabFilter Pro-G (FabFilter)", desc = "Expander / Gate" }
    }},
    { category = "Valhalla DSP", plugins = {
      { name = "ValhallaVintageVerb", full = "VST3: ValhallaVintageVerb (Valhalla DSP)", desc = "Classic 70s/80s Reverb" },
      { name = "ValhallaDelay", full = "VST3: ValhallaDelay (Valhalla DSP)", desc = "Tape/BBD/Digital Delay" },
      { name = "ValhallaRoom", full = "VST3: ValhallaRoom (Valhalla DSP)", desc = "Algorithmic Room Reverb" },
      { name = "ValhallaPlate", full = "VST3: ValhallaPlate (Valhalla DSP)", desc = "Real Plate Reverb" },
      { name = "ValhallaSupermassive", full = "VST3: ValhallaSupermassive (Valhalla DSP)", desc = "Massive Space & Delays" }
    }},
    { category = "iZotope & Creative", plugins = {
      { name = "Ozone 12 Maximizer", full = "AU: Ozone 12 Maximizer (iZotope)", desc = "Ozone Limiter" },
      { name = "Ozone 12 Equalizer", full = "AU: Ozone 12 Equalizer (iZotope)", desc = "Mastering EQ" },
      { name = "Ozone 12 Dynamics", full = "AU: Ozone 12 Dynamics (iZotope)", desc = "Multiband Dynamics" },
      { name = "Kickstart 2", full = "AU: Kickstart 2 (Nicky Romero)", desc = "Sidechain Pumping" },
      { name = "Fresh Air", full = "AU: Fresh Air (Slate Digital)", desc = "High Frequency Exciter" },
      { name = "Melodyne", full = "AU: Melodyne (Celemony )", desc = "Vocal Pitch & Timing" }
    }},
    { category = "JS Utilities", plugins = {
      { name = "Volume/Pan Smoother", full = "JS: utility/volsmooth", desc = "Smooth volume/pan" },
      { name = "3-Band EQ", full = "JS: 3bandeq", desc = "Classic DJ 3-Band EQ" },
      { name = "Guitar Amp / Distortion", full = "JS: distortion", desc = "Warm saturation" },
      { name = "Chorus", full = "JS: chorus", desc = "Stereo modulation" }
    }}
  }
  return { categories = list }
end

-- ============================================================
-- Track Inputs API
-- ============================================================

function actions.get_project_inputs()
  local num_audio = reaper.GetNumAudioInputs and reaper.GetNumAudioInputs() or 0
  local audio_mono = {}
  local audio_stereo = {}
  for i = 0, num_audio - 1 do
    local name = reaper.GetInputChannelName(i)
    if not name or name == "" then name = "Input " .. tostring(i + 1) end
    table.insert(audio_mono, { id = i, name = name })
  end
  for i = 0, num_audio - 1, 2 do
    if i + 1 < num_audio then
      local n1 = reaper.GetInputChannelName(i)
      local n2 = reaper.GetInputChannelName(i + 1)
      if not n1 or n1 == "" then n1 = "In " .. tostring(i + 1) end
      if not n2 or n2 == "" then n2 = "In " .. tostring(i + 2) end
      table.insert(audio_stereo, { id = 1024 + i, name = n1 .. " / " .. n2 })
    end
  end

  local num_midi = reaper.GetNumMIDIInputs and reaper.GetNumMIDIInputs() or 0
  local midi_devs = {}
  table.insert(midi_devs, { id = 4096, name = "All MIDI Inputs (All Channels)" })
  table.insert(midi_devs, { id = 4096 + 1, name = "All MIDI Inputs (Channel 1)" })

  for i = 0, num_midi - 1 do
    local retval, name = reaper.GetMIDIInputName(i, "")
    if retval and name and name ~= "" then
      table.insert(midi_devs, { id = 4096 | ((i + 1) << 5), name = name .. " (All Channels)" })
    end
  end

  return {
    num_audio = num_audio,
    mono = audio_mono,
    stereo = audio_stereo,
    midi = midi_devs
  }
end

function actions.set_track_input(p)
  local tr_idx = tonumber(p.track_index or 1)
  local recinput = tonumber(p.input_id or -1)
  local tr = get_track_by_index(tr_idx)
  if not tr then return { error = "Track not found" } end

  reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", recinput)
  if p.recmon ~= nil then
    reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", tonumber(p.recmon))
  end
  local name = format_input_name(recinput)
  reaper.Undo_OnStateChangeEx2(0, "Set Track Input", -1, -1)
  return { success = true, track_index = tr_idx, recinput = recinput, name = name }
end

function actions.get_track_inputs_batch()
  local num_tracks = reaper.CountTracks(0)
  local list = {}
  for i = 0, num_tracks do
    local tr = get_track_by_index(i)
    if tr then
      local recinput = reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT")
      local recmon = reaper.GetMediaTrackInfo_Value(tr, "I_RECMON")
      local recarm = reaper.GetMediaTrackInfo_Value(tr, "I_RECARM")
      table.insert(list, {
        track_index = i,
        recinput = recinput,
        name = format_input_name(recinput),
        recmon = recmon,
        recarm = recarm
      })
    end
  end
  return { tracks = list }
end

-- ============================================================
-- Main Bridge Event Loop & System Monitor
-- ============================================================

local function bridge_loop()
  -- Check if another newer instance took over
  local current_instance = reaper.GetExtState(EXT_SECTION, "running_instance")
  if current_instance ~= "" and current_instance ~= INSTANCE_ID then
    return -- Exit cleanly
  end

  -- Update heartbeat and system statistics every ~500ms
  local now = reaper.time_precise()
  if now - last_heartbeat >= 0.5 then
    -- 1. CPU calculation
    local dt = now - last_precise
    if dt >= 0.2 and os.clock then
      local clk = os.clock()
      local dclk = clk - last_clock
      if dclk >= 0 and dt > 0 then
        -- Multi-threaded CPU load percentage
        local raw_cpu = (dclk / dt) * 100
        -- Smooth with exponential moving average
        current_cpu = math.floor((0.7 * current_cpu + 0.3 * raw_cpu) * 10 + 0.5) / 10
      end
      last_clock = clk
      last_precise = now
    end

    -- 2. Audio Dropouts (Underruns / Xruns)
    if reaper.GetUnderrunTime then
      local ax, mx, cur = reaper.GetUnderrunTime()
      if ax and ax > 0 then
        if last_audio_xrun > 0 and ax ~= last_audio_xrun then
          audio_dropouts = audio_dropouts + 1
        end
        last_audio_xrun = ax
      end
      if mx and mx > 0 then
        if last_media_xrun > 0 and mx ~= last_media_xrun then
          media_dropouts = media_dropouts + 1
        end
        last_media_xrun = mx
      end
    end

    reaper.SetExtState(EXT_SECTION, "heartbeat", tostring(math.floor(now)), false)
    reaper.SetExtState(EXT_SECTION, "stats", json_encode({
      cpu = current_cpu,
      drops = audio_dropouts + media_dropouts,
      audio_drops = audio_dropouts,
      media_drops = media_dropouts,
      last_xrun = last_audio_xrun
    }), false)
    last_heartbeat = now
  end

  -- Check for incoming command
  local raw_cmd = reaper.GetExtState(EXT_SECTION, "cmd")
  if raw_cmd and raw_cmd ~= "" then
    -- Immediately clear to prevent re-execution
    reaper.SetExtState(EXT_SECTION, "cmd", "", false)

    local decoded = url_decode(raw_cmd)
    local req = json_decode(decoded)
    if req and req.action and actions[req.action] then
      local ok, res = pcall(actions[req.action], req.params or {})
      local resp = {
        id = req.id or 0,
        ok = ok,
        result = ok and res or nil,
        error = not ok and tostring(res) or nil
      }

      local resp_json = json_encode(resp)
      local chunk_size = 750
      local total_len = #resp_json
      local num_chunks = math.ceil(total_len / chunk_size)
      if num_chunks == 0 then num_chunks = 1 end

      reaper.SetExtState(EXT_SECTION, "resp_count", tostring(num_chunks), false)
      for i = 1, num_chunks do
        local chunk = resp_json:sub((i-1)*chunk_size + 1, i*chunk_size)
        reaper.SetExtState(EXT_SECTION, "resp_" .. tostring(i-1), chunk, false)
      end
      -- Clear any leftover chunks from previous longer responses
      for i = num_chunks, 35 do
        reaper.SetExtState(EXT_SECTION, "resp_" .. tostring(i), "", false)
      end
      -- Set resp_id last so web client knows chunks are ready
      reaper.SetExtState(EXT_SECTION, "resp_id", tostring(req.id or 0), false)
    end
  end

  reaper.defer(bridge_loop)
end

-- Start
reaper.SetExtState(EXT_SECTION, "heartbeat", tostring(math.floor(reaper.time_precise())), false)
bridge_loop()
