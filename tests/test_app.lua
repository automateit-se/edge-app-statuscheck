-- Tests for app.lua without an edge client: run with `lua5.3 tests/test_app.lua` from the repository root.
-- The edge client and the clock are simulated. All names, addresses and numbers are made up.

local failures, count = 0, 0
local function check(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if ok then print("ok   " .. name) else failures = failures + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, what)
  if a ~= b then error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2) end
end

local S = dofile("tests/sim.lua")
local fn, load_app = S.fn, S.load_app
local CHECK, SET, PLAY = "obj/statuscheck/home", "set/obj/statuscheck/home", "set/obj/ha/speaker/play"
local DOOR, COFFEE, STOVE, FREEZER = "obj/door", "obj/coffee", "obj/stove", "obj/freezer"

-- a flat: a balcony door, a coffee maker, a stove and a freezer temperature
local function functions()
  return {
    fn(101, DOOR, "Altandörr", { state_open = "1" }),
    fn(102, COFFEE, "Kaffebryggare", { state_on = "1" }),
    fn(103, STOVE, "Spis effekt"),
    fn(104, FREEZER, "Frys temperatur"),
    S.PLAY,
  }
end

local function config(extra)
  local c = {
    name = "Statuskontroll", group = "home",
    items = {
      { item_function = 101, item_when = "active", item_text = "Altandörren är öppen", item_sound = "iotopen/altandorren_oppen.mp3" },
      { item_function = 102, item_when = "active", item_text = "Kaffebryggaren är på", item_sound = "iotopen/kaffebryggaren_pa.mp3" },
      { item_function = 103, item_when = "above", item_value = 50, item_text = "Spisen är på", item_sound = "iotopen/spisen_pa.mp3" },
      { item_function = 104, item_when = "above", item_value = -15, item_text = "Frysen är för varm", item_sound = "iotopen/frysen.mp3" },
    },
    ok_text = "Allt är ok", ok_sound = "iotopen/allt_ok.mp3", gap_s = 4,
  }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

local function start(extra, opts)
  opts = opts or {}
  local fns = opts.functions or functions()
  local M, env, sim = load_app({ cfg = config(extra), functions = fns, devices = opts.devices or { S.SPEAKER }, status = opts.status,
    retained = opts.retained })
  env.onStart()
  sim.advance(5)
  return M, env, sim, fns
end

local function plays(sim)
  local out = {}
  for _, p in ipairs(sim.pubs(PLAY)) do out[#out + 1] = p.value end
  return table.concat(out, " | ")
end

local ALL_OK = { [DOOR] = 0, [COFFEE] = 0, [STOVE] = 3, [FREEZER] = -19 }

-- ---- the check -----------------------------------------------------------------------------------------------------

check("all as it should be: the ok sound and Allt är ok", function()
  local _, _, sim = start(nil, { status = ALL_OK })
  sim.set(SET, 1, "Dashboard")
  eq(plays(sim), "iotopen/allt_ok.mp3", "sound")
  eq(sim.last(CHECK).value, 0, "no deviations")
  eq(sim.last(CHECK).msg, "Allt är ok", "text")
end)

check("an open door and the coffee maker: their sounds one after another, nothing for what is as it should be", function()
  local _, _, sim = start(nil, { status = ALL_OK })
  sim.value(DOOR, 1)
  sim.value(COFFEE, 1)
  sim.set(SET, 1)
  eq(plays(sim), "iotopen/altandorren_oppen.mp3", "the first at once")
  sim.advance(4)
  eq(plays(sim), "iotopen/altandorren_oppen.mp3 | iotopen/kaffebryggaren_pa.mp3", "the second 4 s later")
  sim.advance(10)
  eq(#sim.pubs(PLAY), 2, "no ok sound")
  eq(sim.last(CHECK).value, 2, "two deviations")
  eq(sim.last(CHECK).msg, "Altandörren är öppen, Kaffebryggaren är på", "texts in the form's order")
end)

check("above and below a value", function()
  local _, _, sim = start(nil, { status = ALL_OK })
  sim.value(STOVE, 1200)
  sim.value(FREEZER, -8)
  sim.set(SET, 1)
  eq(sim.last(CHECK).msg, "Spisen är på, Frysen är för varm", "texts")
  local M = load_app({})
  local item = { when = "below", value = 20, fn = {} }
  eq(M.status(item, 19, nil), "warning", "below")
  eq(M.status({ when = "inactive", fn = { meta = { state_true = "1" } } }, 0, nil), "warning", "inactive = deviation")
  eq(M.status({ when = "equal", value = "locked", fn = {} }, "locked", nil), "warning", "equal text")
end)

check("a function without a value is told as unknown, not as ok", function()
  local _, _, sim = start({ unknown_sound = "iotopen/okand.mp3" }, { status = { [DOOR] = 0, [COFFEE] = 0, [STOVE] = 3 } })
  sim.set(SET, 1)
  eq(sim.last(CHECK).value, 1, "one deviation")
  eq(sim.last(CHECK).msg, "Frys temperatur: okänd status", "named")
  eq(plays(sim), "iotopen/okand.mp3", "the unknown sound")
end)

check("the latest values come from IoT Open at the start; live values win", function()
  local _, _, sim = start(nil, { status = { [DOOR] = 1, [COFFEE] = 0, [STOVE] = 3, [FREEZER] = -20 } })
  sim.set(SET, 1)
  eq(sim.last(CHECK).msg, "Altandörren är öppen", "from IoT Open")
  sim.value(DOOR, 0)
  sim.set(SET, 1)
  eq(sim.last(CHECK).msg, "Allt är ok", "closed since")
end)

check("a KNX button on its own topic runs the check too; 0 does not", function()
  local _, _, sim = start({ trigger_topic = "set/obj/house/hemma/virtual_9/status_check" }, { status = ALL_OK })
  sim.set("set/obj/house/hemma/virtual_9/status_check", 0)
  eq(sim.last(CHECK), nil, "0 does nothing")
  sim.set("set/obj/house/hemma/virtual_9/status_check", 1)
  eq(sim.last(CHECK).value, 0, "1 runs it")
end)

check("a new check stops the sounds of the one still playing", function()
  local _, _, sim = start(nil, { status = ALL_OK })
  sim.value(DOOR, 1) sim.value(COFFEE, 1)
  sim.set(SET, 1)
  sim.value(DOOR, 0) sim.value(COFFEE, 0)
  sim.set(SET, 1)
  sim.advance(20)
  eq(plays(sim), "iotopen/altandorren_oppen.mp3 | iotopen/allt_ok.mp3", "the coffee sound not played after the new check")
end)

check("without a speaker the check still runs, with a warning", function()
  local fns = functions()
  fns[#fns] = nil
  local _, _, sim = start(nil, { status = ALL_OK, functions = fns, devices = {} })
  sim.set(SET, 1)
  eq(sim.last(CHECK).value, 0, "result")
  local warned = false
  for _, l in ipairs(sim.logs) do if l:find("no speaker", 1, true) then warned = true end end
  assert(warned, "warning")
end)

check("a notification with the texts when something deviates, and only then unless asked", function()
  local rec = { id = 950, type = "recipients", meta = { recipients_email_boende = "boende@example.com" } }
  local _, _, sim = start({ notify_outputs = { 1001 }, notify_group = "Boende" }, { status = ALL_OK, devices = { S.SPEAKER, rec } })
  sim.set(SET, 1)
  eq(#(sim.notified or {}), 0, "all ok: nothing")
  sim.value(DOOR, 1)
  sim.set(SET, 1)
  local n = sim.notified[1]
  eq(n.body.count, 1, "count")
  eq(n.body.text, "Altandörren är öppen", "text")
  eq(n.body.recipients_email, "boende@example.com", "recipients")
  local _, _, sim2 = start({ notify_outputs = { 1001 }, notify_always = true }, { status = ALL_OK })
  sim2.set(SET, 1)
  eq(sim2.notified[1].body.ok, true, "always")
end)

-- ---- the check function and the settings ---------------------------------------------------------------------------

check("the check is a function of type button with its topics, created once", function()
  local _, _, sim, fns = start(nil, { status = ALL_OK })
  local f = sim.created[1]
  eq(f.type, "button", "type")
  eq(f.meta.topic_read, CHECK, "read")
  eq(f.meta.topic_write, SET, "write")
  eq(f.meta["statuscheck.ok_text"], "Allt är ok", "carries its settings")
  eq(f.meta["statuscheck.ok_sound"], "iotopen/allt_ok.mp3", "sound")
  local all = {}
  for _, x in ipairs(fns) do all[#all + 1] = x end
  all[#all + 1] = f
  local _, env2, sim2 = load_app({ cfg = sim.instance_config, functions = all, devices = { S.SPEAKER }, retained = sim.retained })
  env2.onStart()
  sim2.advance(5)
  eq(#sim2.created, 0, "not again")
  eq(#sim2.puts("/api/v2/"), 0, "and nothing written")
end)

check("the items are written to their functions and changes in IoT Open come back into the form", function()
  local _, env, sim, fns = start(nil, { status = ALL_OK })
  eq(fns[1].meta["statuscheck.group"], "home", "group")
  eq(fns[1].meta["statuscheck.text"], "Altandörren är öppen", "text")
  eq(fns[3].meta["statuscheck.when"], "above", "when")
  eq(fns[3].meta["statuscheck.value"], "50", "value")
  fns[2].meta["statuscheck.text"] = "Bryggaren är på"            -- an item changed in IoT Open
  sim.created[1].meta["statuscheck.ok_text"] = "Allt är lugnt"    -- and the check's own setting
  env.onFunctionsUpdated()
  eq(sim.instance_config.items[2].item_text, "Bryggaren är på", "item back into the form")
  eq(sim.instance_config.ok_text, "Allt är lugnt", "setting back into the form")
  eq(sim.instance_config.items[3].item_value, 50, "a number stays a number")
  sim.set(SET, 1)
  eq(sim.last(CHECK).msg, "Allt är lugnt", "and in use")
end)

check("an item removed from the form leaves the function alone except for this check's group", function()
  local _, _, sim, fns = start(nil, { status = ALL_OK })
  local c = config()
  table.remove(c.items, 2)
  local all = {}
  for _, x in ipairs(fns) do all[#all + 1] = x end
  all[#all + 1] = sim.created[1]
  local _, env2, sim2 = load_app({ cfg = c, functions = all, devices = { S.SPEAKER }, retained = sim.retained,
    status = { [DOOR] = 0, [COFFEE] = 1, [STOVE] = 3, [FREEZER] = -19 } })
  env2.onStart()
  sim2.advance(5)
  eq(fns[2].meta["statuscheck.group"], nil, "group removed")
  eq(fns[2].meta.name, "Kaffebryggare", "the rest kept")
  eq(sim2.handlers[COFFEE], nil, "not subscribed")
  sim2.set(SET, 1)
  eq(sim2.last(CHECK).value, 0, "the coffee maker is on but no longer checked")
end)

check("the code returns nothing in the edge client", function()
  local env = setmetatable({ cfg = {}, app = { id = 1 }, log = { i = print, e = print }, json = { null = {} } }, { __index = _G })
  local chunk = assert(loadfile("app.lua", "t", env))
  eq(select("#", chunk()), 0, "returned values")
end)

print(string.format("%d of %d passed", count - failures, count))
os.exit(failures == 0 and 0 or 1)
