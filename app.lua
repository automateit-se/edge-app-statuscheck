-- Status check (Statuskontroll): when triggered, checks the current state of chosen functions and tells what is not
-- as it should be, for example "Altandörren är öppen" and "Kaffebryggaren är på", or "Allt är ok".
--
--   - The check is a function of its own (type button, obj/statuscheck/<group>, written to on
--     set/obj/statuscheck/<group>). Writing 1 runs the check: from the dashboard's push button, a KNX button (an extra
--     trigger topic) or anything else. After a check the function's value is the number of deviations and its msg
--     what they were.
--   - Every item: a function, when it is a deviation (active, inactive, above, below or equal to a value), the text
--     and the sound for it. A function that has not reported a value is told as unknown.
--   - What happens: the sounds of the deviations one after another on the installation's speaker (a device of type
--     audio), or the ok sound when there is none; optionally a notification with the same texts.
--   - Settings are stored as metadata in IoT Open and kept in step with the form both ways, last change wins, as in
--     För länge 0.4: the items on their functions (statuscheck.group, .when, .value, .text, .sound), the check's own
--     settings on the check function (statuscheck.ok_text, .ok_sound, .unknown_sound, .gap_s).

local VERSION = "0.1.0"
local PREFIX = "statuscheck"
local SYNC_WAIT_S = 3

local M = {}

-- ---- small helpers -----------------------------------------------------------------------------------------------

local function is_null(v) return v == nil or (json ~= nil and v == json.null) end
local function num(v, d) local n = tonumber(v) if n == nil or n ~= n then return d end return n end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function str(v) if is_null(v) then return "" end return trim(v) end
local function first_set(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if not is_null(v) and trim(v) ~= "" then return trim(v) end
  end
  return nil
end

--- The edge client's log has i, e and d (no w): warnings are written with log.i.
local function warn(f, ...) log.i("warning: " .. f, ...) end

local function ids(v)
  local out = {}
  if type(v) == "table" then
    for k, x in pairs(v) do
      local id = type(k) == "number" and tonumber(x) or tonumber(k) or tonumber(x)
      if id then out[#out + 1] = math.floor(id) end
    end
  elseif tonumber(v) then
    out[1] = math.floor(tonumber(v))
  end
  table.sort(out)
  return out
end

function M.slug(v)
  local t = str(v)
  for from, to in pairs({ ["å"] = "a", ["Å"] = "a", ["ä"] = "a", ["Ä"] = "a", ["ö"] = "o", ["Ö"] = "o", ["é"] = "e", ["É"] = "e", ["ü"] = "u", ["Ü"] = "u" }) do
    t = t:gsub(from, to)
  end
  t = t:lower():gsub("[^a-z0-9_%-]+", "_"):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
  return t
end

function M.same_value(a, b)
  if is_null(a) or is_null(b) then return false end
  local na, nb = tonumber(a), tonumber(b)
  if na ~= nil and nb ~= nil then return na == nb end
  return tostring(a) == tostring(b)
end

local function number_text(v)
  local n = tonumber(v)
  if n == nil then return str(v) end
  if n == math.floor(n) then return string.format("%d", n) end
  return string.format("%g", n)
end

-- ---- settings ------------------------------------------------------------------------------------------------------

local WHEN = { active = true, inactive = true, above = true, below = true, equal = true }

function M.settings(c)
  c = c or {}
  return {
    name = str(c.name) ~= "" and str(c.name) or "Statuskontroll",
    group = M.slug(c.group) ~= "" and M.slug(c.group) or (PREFIX .. "-" .. tostring(app and app.id or 0)),
    notify_outputs = ids(c.notify_outputs),
    notify_group = M.slug(c.notify_group),
    notify_always = c.notify_always == true,
    trigger_topic = str(c.trigger_topic),
    player_device = ids(c.player_device)[1],
    active_value = str(c.active_value),
  }
end

-- ---- the check: pure logic -----------------------------------------------------------------------------------------

--- An item from a function's metadata: { id, name, topic, when, value, text, sound }.
function M.item(fn)
  local meta = fn.meta or {}
  local when = str(meta[PREFIX .. ".when"])
  return {
    id = fn.id,
    fn = fn,
    name = first_set(meta.name) or ("funktion " .. tostring(fn.id)),
    topic = meta.topic_read,
    when = WHEN[when] and when or "active",
    value = tonumber(meta[PREFIX .. ".value"]) or str(meta[PREFIX .. ".value"]),
    text = first_set(meta[PREFIX .. ".text"], meta.name) or ("funktion " .. tostring(fn.id)),
    sound = first_set(meta[PREFIX .. ".sound"]),
  }
end

--- Whether a value means active (open, on) for a function.
function M.is_active(fn, value, default_active)
  local meta = fn and fn.meta or {}
  local active = first_set(meta[PREFIX .. ".active_value"], default_active, meta.state_open, meta.state_on, meta.state_true) or "1"
  return M.same_value(value, active)
end

--- "warning", "ok" or "unknown" for an item and its current value.
function M.status(item, value, default_active)
  if is_null(value) then return "unknown" end
  local w = item.when
  if w == "active" then return M.is_active(item.fn, value, default_active) and "warning" or "ok" end
  if w == "inactive" then return M.is_active(item.fn, value, default_active) and "ok" or "warning" end
  if w == "equal" then return M.same_value(value, item.value) and "warning" or "ok" end
  local v, limit = tonumber(value), tonumber(item.value)
  if v == nil or limit == nil then return "unknown" end
  if w == "above" then return v > limit and "warning" or "ok" end
  return v < limit and "warning" or "ok"
end

--- Runs the check over items (in order) with the current values: { warnings = {item...}, unknown = {item...},
--- sounds = {file...}, texts = {text...} }.
function M.run(items, values, check)
  local r = { warnings = {}, unknown = {}, sounds = {}, texts = {} }
  for _, item in ipairs(items) do
    local st = M.status(item, values[item.topic], check.active_value)
    if st == "warning" then
      r.warnings[#r.warnings + 1] = item
      r.texts[#r.texts + 1] = item.text
      if item.sound then r.sounds[#r.sounds + 1] = item.sound end
    elseif st == "unknown" then
      r.unknown[#r.unknown + 1] = item
      r.texts[#r.texts + 1] = item.name .. ": " .. check.unknown_text
    end
  end
  if #r.unknown > 0 and check.unknown_sound then r.sounds[#r.sounds + 1] = check.unknown_sound end
  if #r.warnings == 0 and #r.unknown == 0 then
    r.texts = { check.ok_text }
    if check.ok_sound then r.sounds = { check.ok_sound } end
  end
  return r
end

-- ---- the form and the metadata -------------------------------------------------------------------------------------

-- items: <PREFIX>.<meta> on each function <-> <form> in the form's item rows
local ITEM_FIELDS = {
  { meta = "when", form = "item_when" }, { meta = "value", form = "item_value" },
  { meta = "text", form = "item_text" }, { meta = "sound", form = "item_sound" },
}
-- the check's own settings: <PREFIX>.<meta> on the check function <-> <form> at the top level of the form
local CHECK_FIELDS = {
  { meta = "ok_text", form = "ok_text", default = "Allt är ok" }, { meta = "ok_sound", form = "ok_sound" },
  { meta = "unknown_text", form = "unknown_text", default = "okänd status" }, { meta = "unknown_sound", form = "unknown_sound" },
  { meta = "gap_s", form = "gap_s", default = "4", number = true },
}

local function field_value(f, v)
  if f.number or f.meta == "value" then return number_text(v) end
  if f.meta == "when" then return WHEN[str(v)] and str(v) or "" end
  return str(v)
end

function M.groups(v)
  local out = {}
  for part in str(v):gmatch("[^,;]+") do
    local g = M.slug(part)
    if g ~= "" then out[#out + 1] = g end
  end
  return out
end

function M.in_group(fn, group)
  for _, g in ipairs(M.groups((fn.meta or {})[PREFIX .. ".group"])) do if g == group then return true end end
  return false
end

function M.form_rows(c)
  local out, seen = {}, {}
  for _, w in ipairs(type(c) == "table" and type(c.items) == "table" and c.items or {}) do
    if type(w) == "table" then
      local id = ids(w.item_function)[1]
      if id and not seen[id] then
        seen[id] = true
        local r = { id = id }
        for _, f in ipairs(ITEM_FIELDS) do r[f.meta] = field_value(f, w[f.form]) end
        out[#out + 1] = r
      end
    end
  end
  return out
end

function M.meta_rows(functions, group, order)
  local by, out = {}, {}
  for _, fn in ipairs(functions or {}) do
    if fn.id and M.in_group(fn, group) then
      local r = { id = fn.id }
      for _, f in ipairs(ITEM_FIELDS) do r[f.meta] = field_value(f, (fn.meta or {})[PREFIX .. "." .. f.meta]) end
      by[fn.id] = r
    end
  end
  for _, id in ipairs(order or {}) do if by[id] then out[#out + 1] = by[id] by[id] = nil end end
  local rest = {}
  for id in pairs(by) do rest[#rest + 1] = id end
  table.sort(rest)
  for _, id in ipairs(rest) do out[#out + 1] = by[id] end
  return out
end

--- The check's own settings from the form, or from the check function's metadata.
function M.form_check(c)
  local out = {}
  for _, f in ipairs(CHECK_FIELDS) do out[f.meta] = field_value(f, (c or {})[f.form]) end
  return out
end

function M.meta_check(fn)
  local out = {}
  for _, f in ipairs(CHECK_FIELDS) do out[f.meta] = field_value(f, ((fn or {}).meta or {})[PREFIX .. "." .. f.meta]) end
  return out
end

--- The check's settings in use: the metadata, with defaults.
function M.check_settings(fn)
  local m = M.meta_check(fn)
  local out = {}
  for _, f in ipairs(CHECK_FIELDS) do
    local v = m[f.meta] ~= "" and m[f.meta] or f.default
    out[f.meta] = v ~= "" and v or nil
  end
  out.gap_s = math.max(0, num(out.gap_s, 4))
  return out
end

local function clean(v) return (tostring(v or ""):gsub("[\t\r\n]", " ")) end

--- Items and the check's settings as text, for the retained topic and for comparing.
function M.text(rows, check)
  local lines = {}
  local c = {}
  for _, f in ipairs(CHECK_FIELDS) do c[#c + 1] = clean(check[f.meta]) end
  lines[1] = "#\t" .. table.concat(c, "\t")
  for _, r in ipairs(rows or {}) do
    local parts = { tostring(r.id) }
    for _, f in ipairs(ITEM_FIELDS) do parts[#parts + 1] = clean(r[f.meta]) end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  return table.concat(lines, "\n")
end

function M.parse(text)
  local rows, check = {}, {}
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local p = {}
    for part in (line .. "\t"):gmatch("([^\t]*)\t") do p[#p + 1] = part end
    if p[1] == "#" then
      for i, f in ipairs(CHECK_FIELDS) do check[f.meta] = p[i + 1] or "" end
    elseif tonumber(p[1]) then
      local r = { id = math.floor(tonumber(p[1])) }
      for i, f in ipairs(ITEM_FIELDS) do r[f.meta] = p[i + 1] or "" end
      rows[#rows + 1] = r
    end
  end
  return rows, check
end

--- What to write to the item functions' metadata when the form's items changed from `prev` to `form` (nil prev: add,
--- remove nothing).
function M.plan(prev, form, functions, group)
  local fns, out, before, after = {}, {}, {}, {}
  for _, fn in ipairs(functions or {}) do if fn.id then fns[fn.id] = fn end end
  for _, r in ipairs(prev or {}) do before[r.id] = r end
  for _, r in ipairs(form) do after[r.id] = r end
  local function set(id, key, value) out[id] = out[id] or {} out[id][key] = value end
  for _, r in ipairs(form) do
    local fn = fns[r.id]
    if fn then
      local old = before[r.id]
      if not M.in_group(fn, group) and (old == nil or prev == nil) then
        local gs = M.groups((fn.meta or {})[PREFIX .. ".group"])
        gs[#gs + 1] = group
        set(r.id, PREFIX .. ".group", table.concat(gs, ","))
      end
      for _, f in ipairs(ITEM_FIELDS) do
        local key, value = PREFIX .. "." .. f.meta, r[f.meta]
        local current = field_value(f, (fn.meta or {})[key])
        if prev == nil or old == nil then
          if value ~= "" and value ~= current then set(r.id, key, value) end
        elseif value ~= old[f.meta] and value ~= current then
          set(r.id, key, value ~= "" and value or false)
        end
      end
    end
  end
  for _, r in ipairs(prev or {}) do
    local fn = fns[r.id]
    if not after[r.id] and fn and M.in_group(fn, group) then
      local keep = {}
      for _, g in ipairs(M.groups(fn.meta[PREFIX .. ".group"])) do if g ~= group then keep[#keep + 1] = g end end
      set(r.id, PREFIX .. ".group", #keep > 0 and table.concat(keep, ",") or false)
    end
  end
  return out
end

--- What to write to the check function when the form's own settings changed from `prev` to `form`.
function M.plan_check(prev, form, fn)
  local out = {}
  local current = M.meta_check(fn)
  for _, f in ipairs(CHECK_FIELDS) do
    local value = form[f.meta]
    if prev == nil then
      if value ~= "" and value ~= current[f.meta] then out[PREFIX .. "." .. f.meta] = value end
    elseif value ~= (prev[f.meta] or "") and value ~= current[f.meta] then
      out[PREFIX .. "." .. f.meta] = value ~= "" and value or false
    end
  end
  return out
end

--- The form's items and own settings from rows and the check's settings, for writing the instance's config.
function M.form_config(config, rows, check)
  local out = {}
  for k, v in pairs(config or {}) do out[k] = v end
  local items = {}
  for _, r in ipairs(rows) do
    local w = { item_function = r.id }
    for _, f in ipairs(ITEM_FIELDS) do
      if r[f.meta] ~= "" then w[f.form] = (f.meta == "value" and tonumber(r[f.meta])) or r[f.meta] end
    end
    items[#items + 1] = w
  end
  out.items = items
  for _, f in ipairs(CHECK_FIELDS) do
    local v = check[f.meta]
    if v == "" then out[f.form] = nil else out[f.form] = f.number and tonumber(v) or v end
  end
  return out
end

--- The speaker: the Play function of the device of type audio (the chosen one, or the first).
function M.player_topic(devices, functions, wanted_device)
  local audio, first = {}, nil
  for _, d in ipairs(devices or {}) do
    if d.type == "audio" then
      audio[d.id] = true
      if first == nil or d.id < first then first = d.id end
    end
  end
  local dev = wanted_device and audio[wanted_device] and wanted_device or first
  if dev == nil then return nil end
  for _, fn in ipairs(functions or {}) do
    local meta = fn.meta or {}
    if meta["ha.part"] == "play" and tonumber(meta.device_id) == dev and str(meta.topic_write) ~= "" then return meta.topic_write end
  end
  return nil
end

function M.recipients(devices, group)
  if group == nil or group == "" then return {} end
  local email, sms = {}, {}
  for _, d in ipairs(devices or {}) do
    if d.type == "recipients" and d.meta then
      for _, x in ipairs({ { email, "recipients_email_" .. group }, { sms, "recipients_sms_" .. group } }) do
        local v = str(d.meta[x[2]])
        if v ~= "" then x[1][#x[1] + 1] = v end
      end
    end
  end
  local out = {}
  if #email > 0 then out.recipients_email = table.concat(email, ",") end
  if #sms > 0 then out.recipients_sms = table.concat(sms, ",") end
  return out
end

-- ---- glue: the edge client -----------------------------------------------------------------------------------------

local state = { settings = nil, functions = {}, devices = {}, items = {}, values = {}, check_fn = nil, check = nil,
  player = nil, playing = nil, applied_rows = nil, applied_check = nil, form_received = false, synced = false,
  queue = {} }

local function now() return os.time() end
local function base() return "obj/" .. PREFIX .. "/" .. state.settings.group end
local function set_topic() return "set/" .. base() end
local function form_topic() return base() .. "/form" end

local function pub(topic, value, msg, retain)
  mq:pub(topic, json:encode({ value = value, msg = msg or "", timestamp = now() }), retain == true, 1)
end

local bound = {}
local function bind(topic, fn)
  if bound[topic] == fn then return end
  if bound[topic] then mq:unbind(topic, bound[topic]) end
  bound[topic] = fn
  mq:sub(topic, 1)
  mq:bind(topic, fn)
end

local function find_check_fn()
  for _, fn in ipairs(state.functions) do
    if fn.meta and tostring(fn.meta[PREFIX .. ".app_id"]) == tostring(app.id) then return fn end
  end
  return nil
end

--- The check function: created once, found again by statuscheck.app_id; its topics are kept right.
local function ensure_check_fn()
  local fn = find_check_fn()
  local meta = { name = state.settings.name, topic_read = base(), topic_write = set_topic(), [PREFIX .. ".app_id"] = tostring(app.id) }
  if fn == nil then
    lynx.createFunction({ type = "button", installation_id = app.installation_id, meta = meta })
    log.i("check function created (%s)", base())
    state.functions = lynx.getFunctions() or {}
    return find_check_fn()
  end
  local new, changed = {}, false
  for k, v in pairs(fn.meta or {}) do new[k] = v end
  for k, v in pairs(meta) do if k ~= "name" and new[k] ~= v then new[k] = v changed = true end end
  if changed then
    lynx.apiCall("PUT", "/api/v2/functionx/" .. tostring(fn.installation_id or app.installation_id) .. "/" .. tostring(fn.id), {
      id = fn.id, installation_id = fn.installation_id or app.installation_id, type = fn.type, meta = new,
      protected_meta = fn.protected_meta or {},
    })
  end
  return fn
end

local function write_meta(fn, changes)
  local meta = {}
  for k, v in pairs(fn.meta or {}) do meta[k] = v end
  local changed = false
  for k, v in pairs(changes) do
    if v == false then
      if meta[k] ~= nil then meta[k] = nil changed = true end
    elseif meta[k] ~= v then meta[k] = v changed = true end
  end
  if not changed then return false end
  lynx.apiCall("PUT", "/api/v2/functionx/" .. tostring(fn.installation_id or app.installation_id) .. "/" .. tostring(fn.id), {
    id = fn.id, installation_id = fn.installation_id or app.installation_id, type = fn.type, meta = meta,
    protected_meta = fn.protected_meta or {},
  })
  return true
end

local function decoded(v)
  if type(v) == "string" then
    local ok, d = pcall(json.decode, json, v)
    if ok then return d end
  end
  return v
end

local warned_mirror = false
local function mirror(rows, check)
  local iid = app.installation_id
  local ok, err = pcall(function()
    local list = decoded(lynx.apiCall("GET", "/api/v2/edge/app/configured/" .. tostring(iid)))
    local inst
    for _, x in ipairs(type(list) == "table" and list or {}) do
      if type(x) == "table" and tonumber(x.id) == tonumber(app.id) then inst = x break end
    end
    assert(inst, "this instance was not found")
    local body = {}
    for k, v in pairs(inst) do body[k] = v end
    body.config = M.form_config(decoded(inst.config), rows, check)
    body.installation_id = iid
    lynx.apiCall("PUT", "/api/v2/edge/app/configured/" .. tostring(iid) .. "/" .. tostring(app.id), body)
  end)
  if not ok then
    if not warned_mirror then warn("the form could not be updated from the metadata (%s)", tostring(err)) end
    warned_mirror = true
    return false
  end
  log.i("form updated from the metadata")
  return true
end

local function save_form(rows, check)
  state.applied_rows, state.applied_check = rows, check
  pub(form_topic(), M.text(rows, check), "form", true)
end

local function order_of(rows)
  local o = {}
  for _, r in ipairs(rows or {}) do o[#o + 1] = r.id end
  return o
end

--- At start: what changed in the form is written to the metadata; then the form is written again if the metadata
--- holds more or other values.
local function sync()
  local rows, check = M.form_rows(cfg), M.form_check(cfg)
  local received = state.form_received
  local functions = lynx.getFunctions() or {}
  local n = 0
  if not received or M.text(state.applied_rows, {}) ~= M.text(rows, {}) then
    local plan = M.plan(received and state.applied_rows or nil, rows, functions, state.settings.group)
    for _, fn in ipairs(functions) do
      if plan[fn.id] then
        local ok, res = pcall(write_meta, fn, plan[fn.id])
        if not ok then warn("function %s could not be updated: %s", tostring(fn.id), tostring(res))
        elseif res then n = n + 1 end
      end
    end
  end
  if state.check_fn then
    local changes = M.plan_check(received and state.applied_check or nil, check, state.check_fn)
    if next(changes) then
      local ok, res = pcall(write_meta, state.check_fn, changes)
      if ok and res then n = n + 1 end
    end
  end
  if n > 0 then
    log.i("form applied: %d functions updated", n)
    functions = lynx.getFunctions() or {}
    state.functions = functions
    state.check_fn = find_check_fn()
  end
  local meta_rows = M.meta_rows(functions, state.settings.group, order_of(rows))
  local meta_check = M.meta_check(state.check_fn)
  if M.text(meta_rows, meta_check) ~= M.text(rows, check) and not mirror(meta_rows, meta_check) then
    save_form(rows, check)
  else
    save_form(meta_rows, meta_check)
  end
  state.synced = true
end

local function check_form()
  if not state.synced then return end
  local rows = M.meta_rows(state.functions, state.settings.group, order_of(state.applied_rows))
  local check = M.meta_check(state.check_fn)
  if M.text(rows, check) ~= M.text(state.applied_rows, state.applied_check or {}) and mirror(rows, check) then
    save_form(rows, check)
  end
end

local function on_form(_, payload)
  if state.form_received then return end
  local ok, data = pcall(json.decode, json, payload)
  if not ok or type(data) ~= "table" then return end
  state.form_received = true
  state.applied_rows, state.applied_check = M.parse(data.value)
end

local function on_value(topic, payload)
  local ok, data = pcall(json.decode, json, payload)
  if ok and type(data) == "table" then state.values[topic] = data.value end
end

--- Plays the sounds one after another, gap_s apart. A new check stops the one still playing.
local function play(sounds, gap)
  if state.playing then state.playing.stopped = true end
  if #sounds == 0 then return end
  if state.player == nil then
    warn("no speaker (a device of type audio with a Play function): the sounds are skipped")
    return
  end
  local run = { stopped = false }
  state.playing = run
  local i = 0
  local function nxt()
    if run.stopped then return end
    i = i + 1
    if i > #sounds then state.playing = nil return end
    pub(state.player, sounds[i], state.settings.name, false)
    if i < #sounds then timer:after(gap, nxt) else state.playing = nil end
  end
  nxt()
end

local function send(output, payload, at)
  local body = {}
  for k, v in pairs(payload) do body[k] = v end
  if at and now() - at > 3600 then body.late = true end
  local ok, err = pcall(lynx.notify, output, body)
  if not ok then
    state.queue[#state.queue + 1] = { output = output, payload = payload, at = at or now() }
    warn("notification output %d could not be called, queued: %s", output, tostring(err))
  end
end

--- Runs the check: the result on the check function, the sounds, and a notification when set.
local function run_check(who)
  local check = M.check_settings(state.check_fn)
  local r = M.run(state.items, state.values, { active_value = state.settings.active_value, ok_text = check.ok_text,
    ok_sound = check.ok_sound, unknown_text = check.unknown_text, unknown_sound = check.unknown_sound })
  local count = #r.warnings + #r.unknown
  local text = table.concat(r.texts, ", ")
  log.i("%s%s: %d deviations", state.settings.name, who ~= "" and (" (" .. who .. ")") or "", count)
  pub(base(), count, text, true)
  play(r.sounds, check.gap_s)
  local s = state.settings
  if #s.notify_outputs > 0 and (count > 0 or s.notify_always) then
    local payload = { instance = s.name, count = count, ok = count == 0, text = text, at = now() }
    for k, v in pairs(M.recipients(state.devices, s.notify_group)) do payload[k] = v end
    for _, o in ipairs(s.notify_outputs) do send(o, payload) end
  end
end

local function triggered(payload)
  local ok, data = pcall(json.decode, json, payload)
  local v = ok and type(data) == "table" and data.value or trim(payload)
  if v == true or tonumber(v) == 1 then
    run_check(ok and type(data) == "table" and str(data.msg) or "")
  end
end

local function on_set(_, payload) triggered(payload) end
local function on_trigger(_, payload) triggered(payload) end

local function refresh()
  state.functions = lynx.getFunctions() or {}
  state.devices = lynx.getDevices() or {}
  state.check_fn = find_check_fn() or state.check_fn
  state.player = M.player_topic(state.devices, state.functions, state.settings.player_device)
  local order = order_of(state.applied_rows or M.form_rows(cfg))
  local items, topics = {}, {}
  local by = {}
  for _, fn in ipairs(state.functions) do
    if M.in_group(fn, state.settings.group) and fn.meta and str(fn.meta.topic_read) ~= "" then by[fn.id] = fn end
  end
  for _, r in ipairs(M.meta_rows(state.functions, state.settings.group, order)) do
    local fn = by[r.id]
    if fn then
      local item = M.item(fn)
      items[#items + 1] = item
      topics[item.topic] = true
    end
  end
  state.items = items
  for topic, fn in pairs(bound) do
    if fn == on_value and not topics[topic] then mq:unbind(topic, fn) bound[topic] = nil end
  end
  for topic in pairs(topics) do bind(topic, on_value) end
  return #items
end

--- The latest values from IoT Open, so a check right after a start knows the state of things that seldom report.
local function catch_up()
  local topics = {}
  for _, item in ipairs(state.items) do if state.values[item.topic] == nil then topics[#topics + 1] = item.topic end end
  if #topics == 0 then return end
  local ok, statuses = pcall(lynx.getStatus, topics)
  if not ok or type(statuses) ~= "table" then return end
  for _, s in ipairs(statuses) do
    if type(s) == "table" and s.topic then
      local topic = tostring(s.topic):gsub("^%d+/", "")
      if state.values[topic] == nil then state.values[topic] = s.value end
    end
  end
end

local function every_minute()
  timer:after(60, every_minute)
  if #state.queue > 0 then
    local q = state.queue
    state.queue = {}
    for _, item in ipairs(q) do if now() - item.at < 24 * 3600 then send(item.output, item.payload, item.at) end end
  end
end

local function start_sync()
  local ok, err = pcall(function() state.check_fn = ensure_check_fn() end)
  if not ok then log.e("could not create the check function: %s", tostring(err)) end
  ok, err = pcall(sync)
  if not ok then log.e("could not apply the form: %s", tostring(err)) state.synced = true end
  local ok2, n = pcall(refresh)
  if ok2 then log.i("%s checks %d functions", state.settings.name, n) end
  pcall(catch_up)
end

function onStart()
  state.settings = M.settings(cfg)
  bind(form_topic(), on_form)
  bind(set_topic(), on_set)
  if state.settings.trigger_topic ~= "" then bind(state.settings.trigger_topic, on_trigger) end
  local ok, n = pcall(refresh)
  if not ok then log.e("could not read functions: %s", tostring(n)) end
  log.i("statuscheck %s: %s, group %s, write 1 to %s to run it", VERSION, state.settings.name, state.settings.group, set_topic())
  timer:after(SYNC_WAIT_S, start_sync)
  timer:after(60, every_minute)
end

function onFunctionsUpdated()
  if not state.settings then return end
  local ok, err = pcall(refresh)
  if not ok then log.e("could not read functions: %s", tostring(err)) return end
  pcall(check_form)
end

function onDevicesUpdated() onFunctionsUpdated() end
function onExit() end

if STATUSCHECK_TEST then
  M._state = state
  return M
end
