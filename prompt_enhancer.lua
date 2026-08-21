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

-- Repo context: a handful of lines about what you are working on right now,
-- appended to each request. Cheap enough (<100 tokens) not to cost latency.
-- Spinner: tune without touching the animation loop.
M.spinnerInterval = 0.08   -- seconds per frame
M.spinnerWidth    = 14     -- cells in the track
M.spinnerGlyph    = "🚀"
M.spinnerTrail    = false  -- true = leave a trail of dots behind the rocket

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

local function enhanceText(profileName, text, onSuccess, onError)
  local key = apiKey()
  if not key then
    return onError("No API key at " .. KEY_FILE)
  end

  local systemPrompt = loadProfile(profileName)
  if not systemPrompt then
    return onError("No profile: " .. profileName .. ".md")
  end

  local context = M.repoContext()
  M.lastContext = context
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
-- Spinner
--------------------------------------------------------------------------------

-- Monospace, so the box does not resize between frames.
local SPINNER_STYLE = { textFont = "Menlo", textSize = 16 }

-- Returns a stop function. The rocket advances one cell per frame, leaving a
-- trail of dots behind it, and wraps back to the start.
local function startSpinner(label)
  local index   = 0
  local showing = nil

  local function draw()
    local cells = {}
    for cell = 0, M.spinnerWidth - 1 do
      if     cell == index      then cells[#cells + 1] = M.spinnerGlyph
      elseif cell < index and M.spinnerTrail then cells[#cells + 1] = "."
      else                           cells[#cells + 1] = " " end
    end

    -- Close before showing. Two alerts alive at once stack vertically instead
    -- of replacing each other.
    if showing then hs.alert.closeSpecific(showing) end
    showing = hs.alert.show(label .. "  " .. table.concat(cells),
                            SPINNER_STYLE, hs.screen.mainScreen(), 10)
  end

  draw()
  local timer = hs.timer.doEvery(M.spinnerInterval, function()
    index = (index + 1) % M.spinnerWidth
    draw()
  end)

  return function()
    timer:stop()
    if showing then hs.alert.closeSpecific(showing) end
  end
end

M.startSpinner = startSpinner  -- exposed so you can eyeball it without a real run

--------------------------------------------------------------------------------
-- Public entry point
--------------------------------------------------------------------------------

local inFlight = false

function M.run(profileName)
  if inFlight then return end
  inFlight = true

  captureSelection(function(selection, savedClipboard)
    if not selection or trim(selection) == "" then
      inFlight = false
      if savedClipboard then hs.pasteboard.setContents(savedClipboard) end
      return hs.alert.show("Nothing selected")
    end

    local stopSpinner = startSpinner("Enhancing")

    enhanceText(profileName, selection,
      function(result)
        stopSpinner()
        logHistory(profileName, selection, result)
        deliver(result, savedClipboard)
        inFlight = false
      end,
      function(err)
        stopSpinner()
        if savedClipboard then hs.pasteboard.setContents(savedClipboard) end
        hs.alert.show("Enhance failed — " .. err, 4)
        inFlight = false
      end)
  end)
end

function M.bind(mods, key, profileName)
  hs.hotkey.bind(mods, key, function() M.run(profileName) end)
end

return M
