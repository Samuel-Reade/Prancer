-- prompt_enhancer.lua
-- Select text anywhere, hit a hotkey, get it rewritten as a prompt tuned for a
-- specific target model, pasted back in place.
--
-- Load from ~/.hammerspoon/init.lua with:
--   local enhancer = require("prompt_enhancer")
--   enhancer.bind({"cmd", "alt"}, "c", "claude_code")

local M = {}

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local HOME       = os.getenv("HOME")
local CONFIG_DIR = HOME .. "/.config/prompt-enhancer"
local PROFILE_DIR = CONFIG_DIR .. "/profiles"
local KEY_FILE   = CONFIG_DIR .. "/anthropic_key"
local HISTORY    = CONFIG_DIR .. "/history.jsonl"

M.model      = "claude-haiku-4-5-20251001"  -- fast; swap to a Sonnet id for higher quality
M.maxTokens  = 2000
M.autoPaste  = true   -- false = leave result on the clipboard instead of pasting

-- Loading HUD: tune without touching the animation loop.
M.hudGlyph = "🚀"   -- rides the leading edge of the progress bar
M.hudFps   = 60     -- animation frames per second
M.hudDrop  = 0.70   -- vertical placement: 0 = top of screen, 1 = bottom

-- Repo context: a handful of lines about what you are working on right now,
-- appended to each request. Cheap enough (<100 tokens) not to cost latency.
M.contextEnabled = true
M.projectRoots   = {   -- where to look for the folder named in the window title
  HOME .. "/Desktop", HOME .. "/Documents", HOME .. "/Projects", HOME .. "/src", HOME,
}

local API_URL = "https://api.anthropic.com/v1/messages"

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local contents = f:read("*a")
  f:close()
  return contents
end

local cachedKey = nil
local function apiKey()
  if cachedKey then return cachedKey end
  local raw = readFile(KEY_FILE)
  if not raw or trim(raw) == "" then return nil end
  cachedKey = trim(raw)
  return cachedKey
end

local profileCache = {}
local function loadProfile(name)
  if profileCache[name] then return profileCache[name] end
  local text = readFile(PROFILE_DIR .. "/" .. name .. ".md")
  if not text then return nil end
  profileCache[name] = text
  return text
end

-- Call this after editing a profile file so you don't have to reload Hammerspoon.
function M.reloadProfiles()
  profileCache = {}
  hs.alert.show("Prompt profiles reloaded")
end

-- Models occasionally wrap output in a fence despite instructions. Strip it.
local function stripFence(text)
  local inner = text:match("^%s*```[%w]*\n(.-)\n?```%s*$")
  return trim(inner or text)
end

local function logHistory(profile, original, enhanced)
  local f = io.open(HISTORY, "a")
  if not f then return end
  f:write(hs.json.encode({
    ts       = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    profile  = profile,
    model    = M.model,
    original = original,
    enhanced = enhanced,
    context  = M.lastContext,
  }) .. "\n")
  f:close()
end

--------------------------------------------------------------------------------
-- Clipboard capture / restore
--------------------------------------------------------------------------------

-- Copying is asynchronous from our point of view, so poll changeCount rather
-- than sleeping a fixed amount and hoping.
local function pollClipboard(baseline, triesLeft, callback)
  if hs.pasteboard.changeCount() ~= baseline then
    callback(hs.pasteboard.getContents())
  elseif triesLeft <= 0 then
    callback(nil)
  else
    hs.timer.doAfter(0.02, function()
      pollClipboard(baseline, triesLeft - 1, callback)
    end)
  end
end

local function captureSelection(callback)
  local saved    = hs.pasteboard.getContents()
  local baseline = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({"cmd"}, "c", 0)
  pollClipboard(baseline, 40, function(selection)  -- ~800ms ceiling
    callback(selection, saved)
  end)
end

local function deliver(text, savedClipboard)
  hs.pasteboard.setContents(text)
  if M.autoPaste then
    hs.eventtap.keyStroke({"cmd"}, "v", 0)
    -- Put the user's original clipboard back once the paste has landed.
    hs.timer.doAfter(0.4, function()
      if savedClipboard then hs.pasteboard.setContents(savedClipboard) end
    end)
  end
end

--------------------------------------------------------------------------------
-- Repo context
--------------------------------------------------------------------------------

-- Only editors get inspected. A browser tab title would otherwise turn into
-- "Currently editing: Some Blog Post".
local EDITORS = {
  ["Code"] = true, ["Visual Studio Code"] = true, ["Cursor"] = true,
  ["Zed"] = true, ["Sublime Text"] = true, ["Xcode"] = true, ["Nova"] = true,
}

local GIT = "/usr/bin/git"

local function sh(cmd)
  local out = hs.execute(cmd)
  return trim(out or "")
end

-- VS Code and friends title windows "file.lua — FolderName — Visual Studio Code".
local function frontFileAndFolder()
  local app = hs.application.frontmostApplication()
  if not app or not EDITORS[app:name()] then return nil, nil end
  local win = hs.window.focusedWindow()
  if not win then return nil, nil end

  local parts = {}
  for seg in (win:title() or ""):gmatch("[^—]+") do
    seg = trim(seg):gsub("^●%s*", "")            -- unsaved-changes marker
    if seg ~= "" and seg ~= app:name() then parts[#parts + 1] = seg end
  end
  return parts[1], parts[2]
end

-- Resolve a bare folder name to a path by looking in M.projectRoots. Cached,
-- since the answer never changes for a given name.
local rootCache = {}
local function resolveRoot(folder)
  if not folder then return nil end
  local hit = rootCache[folder]
  if hit ~= nil then return hit or nil end

  local candidates = { folder }                  -- title might hold a full path
  for _, base in ipairs(M.projectRoots) do candidates[#candidates + 1] = base .. "/" .. folder end
  for _, path in ipairs(candidates) do
    if hs.fs.attributes(path, "mode") == "directory" then
      rootCache[folder] = path
      return path
    end
  end
  rootCache[folder] = false
  return nil
end

-- What you are editing, the branch, the last commit, and what is uncommitted.
function M.repoContext()
  if not M.contextEnabled then return nil end

  local ok, lines = pcall(function()
    local file, folder = frontFileAndFolder()
    local out = {}
    if file then out[#out + 1] = "Currently editing: " .. file end

    local root = resolveRoot(folder)
    if root then
      local git = string.format("%s -C %q ", GIT, root)
      local branch  = sh(git .. "rev-parse --abbrev-ref HEAD 2>/dev/null")
      local subject = sh(git .. "log -1 --pretty=%s 2>/dev/null")
      -- Scoped to the folder, not the whole repo: a home directory under git
      -- would otherwise dump unrelated projects into the context.
      local changed = sh(git .. "status --porcelain -uall -- . 2>/dev/null | head -12 | sed 's/^...//'")

      if branch ~= "" then
        out[#out + 1] = "Repo: " .. root:match("[^/]+$") .. "  (branch " .. branch .. ")"
      end
      if subject ~= "" then out[#out + 1] = "Last commit: " .. subject end
      if changed ~= "" then
        out[#out + 1] = "Uncommitted changes:"
        for path in changed:gmatch("[^\n]+") do out[#out + 1] = "  " .. trim(path) end
      end
    end
    return out
  end)

  if not ok or #lines == 0 then return nil end
  return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

local function enhanceText(profileName, text, hud, onSuccess, onError)
  local key = apiKey()
  if not key then
    return onError("No API key at " .. KEY_FILE)
  end

  local systemPrompt = loadProfile(profileName)
  if not systemPrompt then
    return onError("No profile: " .. profileName .. ".md")
  end

  hud:enter("context")
  local context = M.repoContext()
  M.lastContext = context
  -- The repo line if there is one, else whatever file the editor is showing.
  local where = context and (context:match("Repo: ([^\n]+)")
                          or context:match("Currently editing: ([^\n]+)"))
  hud:note("context", where and where:gsub("%s+", " ") or "no repo context")
  local content = context
    and (text .. "\n\n<context>\n" .. context .. "\n</context>")
    or text

  local body = hs.json.encode({
    model      = M.model,
    max_tokens = M.maxTokens,
    system     = systemPrompt,
    messages   = { { role = "user", content = content } },
  })

  local headers = {
    ["content-type"]      = "application/json",
    ["x-api-key"]         = key,
    ["anthropic-version"] = "2023-06-01",
  }

  hud:enter("model")
  hs.http.asyncPost(API_URL, body, headers, function(status, response)
    if status ~= 200 then
      local detail = ""
      local ok, parsed = pcall(hs.json.decode, response or "")
      if ok and parsed and parsed.error and parsed.error.message then
        detail = ": " .. parsed.error.message
      end
      return onError("API " .. tostring(status) .. detail)
    end

    local ok, parsed = pcall(hs.json.decode, response)
    if not ok or not parsed or not parsed.content then
      return onError("Could not parse API response")
    end

    local parts = {}
    for _, block in ipairs(parsed.content) do
      if block.type == "text" then parts[#parts + 1] = block.text end
    end

    local result = stripFence(table.concat(parts, "\n"))
    if result == "" then return onError("Empty response") end
    onSuccess(result)
  end)
end

--------------------------------------------------------------------------------
-- Loading HUD
--------------------------------------------------------------------------------

-- A run has four stages, and the HUD names the one it is in rather than
-- spinning anonymously. Each stage owns a slice of the bar and eases toward its
-- ceiling without ever arriving, so a slow stage keeps creeping instead of
-- freezing. The percentage is an estimate for that reason -- one non-streaming
-- POST has no real progress to report. The stage, the stage count, the counts
-- on the detail line and the elapsed clock are all exact.
local STAGES = {
  { key = "capture", label = "Reading your selection", ceiling = 0.10, tau = 0.30 },
  { key = "context", label = "Checking the repo",      ceiling = 0.26, tau = 0.35 },
  { key = "model",   label = "Rewriting your prompt",  ceiling = 0.93, tau = 2.20 },
  { key = "deliver", label = "Pasting it back",        ceiling = 1.00, tau = 0.25 },
}

local STAGE_AT = {}
for i, s in ipairs(STAGES) do STAGE_AT[s.key] = i end

-- Layout. Every element is positioned off these, so nudging one number moves a
-- whole row instead of breaking the panel.
local HUD_W, HUD_H = 460, 132
local PAD          = 20
local BAR          = { x = PAD, y = 84, w = HUD_W - PAD * 2, h = 10 }
local DOT          = { y = 109, gap = 15, r = 3.5 }
local SHIMMER_W    = 84
local DONE_HOLD, FAIL_HOLD, SHAKE = 0.85, 3.2, 0.4

-- Element indices, in the order they are appended in build() below.
local E = {
  card = 1, title = 2, badge = 3, status = 4, elapsed = 5, detail = 6,
  track = 7, fill = 8, clip = 9, shimmer = 10, unclip = 11,
  rocket = 12, percent = 13,
  dots = 14,  -- one per stage: 14 .. 14 + #STAGES - 1
}

local function rgb(r, g, b)  return { red = r/255, green = g/255, blue = b/255, alpha = 1 } end
local function ink(a)        return { white = 1, alpha = a } end
local function fade(c, a)    return { red = c.red, green = c.green, blue = c.blue, alpha = a } end

local PALETTE = {
  running = { rgb(255, 122,  69), rgb(255, 186, 107) },
  done    = { rgb( 52, 211, 153), rgb(134, 239, 172) },
  failed  = { rgb(248, 113, 113), rgb(252, 165, 165) },
}

-- Fixed order, so a note added by a later stage lands after the earlier ones.
local NOTE_ORDER = { "input", "context", "result" }

local function nowSec() return hs.timer.secondsSinceEpoch() end

-- claude-haiku-4-5-20251001 -> claude-haiku-4-5
local function shortModel(id) return (id:gsub("%-%d%d%d%d%d%d%d%d$", "")) end

-- "218 words · ~290 tok"
local function describe(text)
  local words = select(2, text:gsub("%S+", ""))
  return string.format("%d word%s  ·  ~%d tok", words, words == 1 and "" or "s", math.ceil(#text / 4))
end

--------------------------------------------------------------------------------

-- Canvas creation can fail (no screen, no window server). A run must still
-- finish and still paste when it does, so fall back to a stub that keeps the
-- one message the user cannot afford to miss.
local NULL_HUD = {
  enter = function() end, note = function() end, done = function() end,
  nudge = function() end, close = function() end,
  fail  = function(_, message) hs.alert.show("Enhance failed — " .. message, 4) end,
}
NULL_HUD.__index = NULL_HUD

local HUD = {}
HUD.__index = HUD

-- The panel outlives its run by a hold-and-fade, so a quick second press would
-- otherwise draw a new one on top of the old.
local activeHud = nil

function HUD.start(title)
  if activeHud then activeHud:close() end
  local screen = hs.screen.mainScreen() or hs.screen.primaryScreen()
  local frame  = screen and screen:frame()
  local canvas = frame and hs.canvas.new({
    x = frame.x + (frame.w - HUD_W) / 2,
    y = frame.y + (frame.h - HUD_H) * M.hudDrop,
    w = HUD_W, h = HUD_H,
  })
  if not canvas then return setmetatable({}, NULL_HUD) end

  local self = setmetatable({
    canvas   = canvas,
    origin   = canvas:frame(),
    state    = "running",
    stage    = 1,
    floor    = 0,       -- progress at the moment the current stage began
    shown    = 0,       -- eased toward the target, so the bar never jumps
    sweep    = 0,
    parts    = {},
    startAt  = nowSec(),
    stageAt  = nowSec(),
    lastTick = nowSec(),
  }, HUD)

  canvas:level(hs.canvas.windowLevels.screenSaver)
  canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces
                + hs.canvas.windowBehaviors.stationary)
  canvas:clickActivating(false)   -- a stray click must not pull focus off the app we paste into
  self:build(title)
  canvas:show(0.12)
  activeHud = self

  self.timer = hs.timer.doEvery(1 / M.hudFps, function()
    -- A broken frame should take the panel down, not leave it stuck on screen.
    if not pcall(function() self:tick() end) then self:close() end
  end)
  return self
end

function HUD:build(title)
  local accent = PALETTE.running

  self.canvas:appendElements(
    { type = "rectangle", action = "strokeAndFill",
      frame = { x = 0, y = 0, w = HUD_W, h = HUD_H },
      roundedRectRadii = { xRadius = 18, yRadius = 18 },
      fillColor = { red = 0.07, green = 0.07, blue = 0.086, alpha = 0.94 },
      strokeColor = ink(0.12), strokeWidth = 1,
      withShadow = true,
      shadow = { blurRadius = 26, color = { alpha = 0.5 }, offset = { h = -8, w = 0 } } },

    { type = "text", text = title,
      frame = { x = PAD, y = 15, w = HUD_W - PAD * 2 - 160, h = 22 },
      textFont = "HelveticaNeue-Medium", textSize = 15, textColor = ink(0.96) },

    { type = "text", text = shortModel(M.model),
      frame = { x = HUD_W - PAD - 220, y = 19, w = 220, h = 18 },
      textFont = "Menlo-Regular", textSize = 10.5, textColor = ink(0.36),
      textAlignment = "right", textLineBreak = "truncateHead" },

    { type = "text", text = STAGES[1].label,
      frame = { x = PAD, y = 41, w = HUD_W - PAD * 2 - 70, h = 20 },
      textFont = "HelveticaNeue", textSize = 13, textColor = ink(0.80),
      textLineBreak = "truncateTail" },

    { type = "text", text = "0.0s",
      frame = { x = HUD_W - PAD - 80, y = 42, w = 80, h = 18 },
      textFont = "Menlo-Regular", textSize = 11.5, textColor = ink(0.42),
      textAlignment = "right" },

    { type = "text", text = "",
      frame = { x = PAD, y = 60, w = HUD_W - PAD * 2, h = 18 },
      textFont = "HelveticaNeue", textSize = 11, textColor = ink(0.34),
      textLineBreak = "truncateTail" },

    { type = "rectangle", action = "fill",
      frame = { x = BAR.x, y = BAR.y, w = BAR.w, h = BAR.h },
      roundedRectRadii = { xRadius = BAR.h / 2, yRadius = BAR.h / 2 },
      fillColor = ink(0.09) },

    { type = "rectangle", action = "fill",
      frame = { x = BAR.x, y = BAR.y, w = 0.01, h = BAR.h },
      roundedRectRadii = { xRadius = BAR.h / 2, yRadius = BAR.h / 2 },
      fillGradient = "linear", fillGradientAngle = 0,
      fillGradientColors = { accent[1], accent[2] } },

    -- Clip the sweep to the filled part, so it never lights up empty track.
    { type = "rectangle", action = "clip",
      frame = { x = BAR.x, y = BAR.y, w = 0.01, h = BAR.h },
      roundedRectRadii = { xRadius = BAR.h / 2, yRadius = BAR.h / 2 } },

    { type = "rectangle", action = "fill",
      frame = { x = BAR.x, y = BAR.y, w = SHIMMER_W, h = BAR.h },
      fillGradient = "linear", fillGradientAngle = 0,
      fillGradientColors = { ink(0), ink(0.34), ink(0) } },

    { type = "resetClip" },

    { type = "text", text = M.hudGlyph,
      frame = { x = BAR.x - 12, y = BAR.y - 7, w = 24, h = 24 },
      textSize = 17, textAlignment = "center",
      withShadow = true,
      shadow = { blurRadius = 5, color = { alpha = 0.7 }, offset = { h = -2, w = 0 } } },

    { type = "text", text = "0%",
      frame = { x = HUD_W - PAD - 70, y = 101, w = 70, h = 18 },
      textFont = "Menlo-Bold", textSize = 11.5, textColor = ink(0.55),
      textAlignment = "right" }
  )

  for i = 1, #STAGES do
    self.canvas:appendElements({ type = "circle", action = "fill",
      center = { x = PAD + DOT.r + (i - 1) * DOT.gap, y = DOT.y },
      radius = DOT.r, fillColor = ink(0.14) })
  end
end

--------------------------------------------------------------------------------
-- Reporting in

-- Where the bar would be right now if nothing else changed.
function HUD:target()
  local stage = STAGES[self.stage]
  local held  = nowSec() - self.stageAt
  return self.floor + (stage.ceiling - self.floor) * (1 - math.exp(-held / stage.tau))
end

function HUD:enter(key)
  local i = STAGE_AT[key]
  if not i or self.state ~= "running" or i <= self.stage then return end
  self.floor   = self:target()   -- carry the bar forward rather than restarting it
  self.stage   = i
  self.stageAt = nowSec()
  self.canvas[E.status].text = STAGES[i].label
end

function HUD:note(key, value)
  self.parts[key] = value
  local out = {}
  for _, k in ipairs(NOTE_ORDER) do
    if self.parts[k] then out[#out + 1] = self.parts[k] end
  end
  self.canvas[E.detail].text = table.concat(out, "  ·  ")
end

function HUD:paint(name)
  local accent = PALETTE[name]
  self.canvas[E.shimmer].frame = { x = BAR.x, y = BAR.y, w = 0.01, h = BAR.h }
  self.canvas[E.fill].fillGradientColors = { accent[1], accent[2] }
  self.canvas[E.percent].textColor       = fade(accent[2], 0.9)
end

function HUD:done(summary)
  if self.state ~= "running" then return end
  self.state = "done"
  self.canvas[E.status].text = M.autoPaste and "Pasted into place" or "Copied to your clipboard"
  self.canvas[E.status].textColor = ink(0.95)
  self.parts = {}
  self:note("result", summary or "")
  self:paint("done")
  self.closeAt = nowSec() + DONE_HOLD
end

function HUD:fail(message)
  if self.state ~= "running" then return end
  self.state = "failed"
  self.canvas[E.status].text      = message
  self.canvas[E.status].textColor = fade(PALETTE.failed[2], 0.95)
  self.canvas[E.rocket].text      = "⚠️"
  self.parts = {}
  self:note("result", "Nothing pasted — your clipboard is untouched")
  self:paint("failed")
  self.shakeUntil = nowSec() + SHAKE
  self.closeAt    = nowSec() + FAIL_HOLD
end

-- A second keypress while a run is in flight: say "still working" rather than
-- swallowing it silently.
function HUD:nudge()
  if self.state == "running" then self.shakeUntil = nowSec() + SHAKE end
end

function HUD:close()
  if self.closed then return end
  self.closed = true
  if activeHud == self then activeHud = nil end
  if self.timer then self.timer:stop() end
  self.canvas:delete(0.25)
end

--------------------------------------------------------------------------------
-- One frame

function HUD:tick()
  local t  = nowSec()
  local dt = t - self.lastTick
  self.lastTick = t
  local c   = self.canvas
  local age = t - self.startAt

  if (self.closeAt and t >= self.closeAt) or age > 90 then return self:close() end

  -- Progress: aim at the stage curve, then chase that with a fixed-rate ease so
  -- a stage change slides in instead of snapping.
  local target = self.state == "running" and self:target()
              or (self.state == "done" and 1 or self.shown)
  self.shown = self.shown + (target - self.shown) * (1 - math.exp(-dt * 10))
  -- Land exactly on the end rather than easing toward it forever: 99% under a
  -- filled bar reads as a rounding bug.
  if self.state ~= "running" and math.abs(target - self.shown) < 0.006 then self.shown = target end

  local width = math.max(0.01, self.shown * BAR.w)
  local edge  = BAR.x + width
  c[E.fill].frame = { x = BAR.x, y = BAR.y, w = width, h = BAR.h }
  c[E.clip].frame = { x = BAR.x, y = BAR.y, w = width, h = BAR.h }

  -- Sweep runs only while there is something left to wait for.
  if self.state == "running" then
    self.sweep = (self.sweep + dt * 300) % (BAR.w + SHIMMER_W)
    c[E.shimmer].frame = { x = BAR.x - SHIMMER_W + self.sweep, y = BAR.y, w = SHIMMER_W, h = BAR.h }
  end

  local bob = self.state == "running" and math.sin(t * 7) * 1.6 or 0
  c[E.rocket].frame = { x = edge - 12, y = BAR.y - 7 + bob, w = 24, h = 24 }

  c[E.elapsed].text     = string.format("%.1fs", age)
  c[E.percent].text     = string.format("%d%%", math.floor(self.shown * 100 + 0.5))
  c[E.card].strokeColor = ink(0.10 + 0.06 * (0.5 + 0.5 * math.sin(t * 3)))

  local accent = PALETTE[self.state]
  for i = 1, #STAGES do
    local dot = E.dots + i - 1
    if self.state == "done" or i < self.stage then
      c[dot].fillColor, c[dot].radius = fade(accent[1], 0.55), DOT.r
    elseif i == self.stage then
      c[dot].fillColor = fade(accent[2], 1)
      c[dot].radius    = DOT.r + 1 + (self.state == "running" and math.sin(t * 5) * 0.8 or 0)
    else
      c[dot].fillColor, c[dot].radius = ink(0.14), DOT.r
    end
  end

  -- Entrance lift, and a decaying shake for "failed" or "already working".
  local dy = age < 0.5 and 14 * math.exp(-age * 14) or 0
  local dx = 0
  if self.shakeUntil then
    local left = self.shakeUntil - t
    if left > 0 then dx = math.sin(t * 48) * 10 * (left / SHAKE) else self.shakeUntil = nil end
  end
  if dx ~= 0 or dy ~= 0 or self.offset then
    c:topLeft({ x = self.origin.x + dx, y = self.origin.y + dy })
    self.offset = dx ~= 0 or dy ~= 0
  end
end

-- Eyeball the animation without spending a token:
--   hs -c 'require("prompt_enhancer").previewHud()'      -- or ("fail")
function M.previewHud(outcome)
  local hud = HUD.start("Enhancing prompt")
  hud:note("input", describe(string.rep("word ", 218)))

  -- Parked on the HUD: an unreferenced one-shot timer can be collected before
  -- it fires, which silently skips the stage it was meant to trigger.
  hud.preview = {}
  local function at(delay, fn) hud.preview[#hud.preview + 1] = hs.timer.doAfter(delay, fn) end

  at(0.5, function() hud:enter("context") end)
  at(1.0, function()
    hud:enter("model")
    hud:note("context", "Prancer (branch main)")
  end)
  at(3.4, function()
    if outcome == "fail" then
      hud:fail("API 401: invalid x-api-key")
    else
      hud:enter("deliver")
      at(0.3, function() hud:done("218 → 312 words") end)
    end
  end)
  return hud
end

--------------------------------------------------------------------------------
-- Public entry point
--------------------------------------------------------------------------------

local inFlight = false

function M.run(profileName)
  if inFlight then
    if activeHud then activeHud:nudge() end   -- already working; don't drop the press silently
    return
  end
  inFlight = true
  local hud = HUD.start("Enhancing prompt")

  captureSelection(function(selection, savedClipboard)
    if not selection or trim(selection) == "" then
      inFlight = false
      if savedClipboard then hs.pasteboard.setContents(savedClipboard) end
      return hud:fail("Nothing selected")
    end

    hud:note("input", describe(selection))

    enhanceText(profileName, selection, hud,
      function(result)
        hud:enter("deliver")
        logHistory(profileName, selection, result)
        deliver(result, savedClipboard)
        hud:done(string.format("%d → %d words",
          select(2, selection:gsub("%S+", "")), select(2, result:gsub("%S+", ""))))
        inFlight = false
      end,
      function(err)
        if savedClipboard then hs.pasteboard.setContents(savedClipboard) end
        hud:fail(err)
        inFlight = false
      end)
  end)
end

function M.bind(mods, key, profileName)
  hs.hotkey.bind(mods, key, function() M.run(profileName) end)
end

return M
