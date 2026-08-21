require("hs.ipc")  -- lets the `hs` CLI query this Hammerspoon instance

local enhancer = require("prompt_enhancer")

-- hs.hotkey.bind registers the hotkey and reports "Enabled", but the callback
-- never fires on this machine. Event taps do receive the keystrokes, so bind
-- from the event stream instead.
local function bindTap(types, matches, action)
  local tap
  tap = hs.eventtap.new(types, function(ev)
    if matches(ev, ev:getFlags()) then
      pcall(action)
      return true  -- swallow the keystroke so it does not reach the app
    end
    return false
  end)
  tap:start()
  return tap  -- keep a reference, or it gets garbage collected and stops working
end

local KEYDOWN = {hs.eventtap.event.types.keyDown}

local function enhance() enhancer.run("claude_code") end

--------------------------------------------------------------------------------
-- 🌐 (Globe / fn) tapped on its own — the main trigger.
--------------------------------------------------------------------------------
-- fn is not a real hotkey modifier, so there is nothing to bind to. Instead
-- watch the modifier-change stream and treat "fn pressed and released quickly,
-- with nothing pressed in between" as the trigger. Holding fn for a shortcut
-- (fn+F5, fn+arrow) must not fire, hence the other-key and duration guards.

local FN_MAX_HOLD    = 0.6   -- seconds; a tap, not a hold
local fnDownAt       = nil
local fnUsedWithKey  = false

-- Anything pressed while fn is held disqualifies the tap.
FN_GUARD_TAP = hs.eventtap.new(
  {hs.eventtap.event.types.keyDown, hs.eventtap.event.types.systemDefined},
  function()
    if fnDownAt then fnUsedWithKey = true end
    return false
  end)
FN_GUARD_TAP:start()

FN_TAP = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(ev)
  local f = ev:getFlags()
  if f.fn and not fnDownAt then
    fnDownAt, fnUsedWithKey = hs.timer.secondsSinceEpoch(), false
  elseif not f.fn and fnDownAt then
    local held  = hs.timer.secondsSinceEpoch() - fnDownAt
    local clean = not fnUsedWithKey
              and not (f.cmd or f.alt or f.ctrl or f.shift)
    fnDownAt = nil
    if clean and held < FN_MAX_HOLD then pcall(enhance) end
  end
  return false  -- never swallow a modifier event
end)
FN_TAP:start()

--------------------------------------------------------------------------------
-- Fallbacks
--------------------------------------------------------------------------------

-- ⌥⌘C — the original trigger, kept as a fallback. Delete if you don't want it.
ENHANCE_TAP = bindTap(KEYDOWN,
  function(ev, f)
    return ev:getKeyCode() == hs.keycodes.map.c
       and f.cmd and f.alt and not f.ctrl and not f.shift
  end, enhance)

-- ⌥⌘⇧R — reload profiles after editing the prompt.
RELOAD_TAP = bindTap(KEYDOWN,
  function(ev, f)
    return ev:getKeyCode() == hs.keycodes.map.r
       and f.cmd and f.alt and f.shift and not f.ctrl
  end, enhancer.reloadProfiles)
