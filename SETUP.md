# Prompt Enhancer — setup (macOS / Hammerspoon)

Select text anywhere → press ⌥⌘C → it gets rewritten as a Claude Code prompt and pasted back in place.

## 1. Install Hammerspoon

```bash
brew install --cask hammerspoon
```

Launch it. It will ask for **Accessibility** permission — this is required, since the tool works by sending synthetic ⌘C and ⌘V keystrokes. Grant it in System Settings → Privacy & Security → Accessibility.

## 2. Create the config directory

```bash
mkdir -p ~/.config/prompt-enhancer/profiles
```

Drop your Anthropic API key in a file (get one at https://console.anthropic.com):

```bash
printf '%s' 'sk-ant-...' > ~/.config/prompt-enhancer/anthropic_key
chmod 600 ~/.config/prompt-enhancer/anthropic_key
```

Copy the profile in:

```bash
cp profiles/claude_code.md ~/.config/prompt-enhancer/profiles/
```

## 3. Install the module

```bash
cp prompt_enhancer.lua ~/.hammerspoon/
```

Add to `~/.hammerspoon/init.lua`:

```lua
local enhancer = require("prompt_enhancer")

enhancer.bind({"cmd", "alt"}, "c", "claude_code")

-- Reload profiles without restarting Hammerspoon, for when you're
-- iterating on the prompt itself:
hs.hotkey.bind({"cmd", "alt", "shift"}, "r", enhancer.reloadProfiles)
```

Reload the config from the Hammerspoon menu bar icon.

## 4. Use it

Select a word dump in any app. Press ⌥⌘C. About a second later the selection is replaced with a structured prompt.

Every original is appended to `~/.config/prompt-enhancer/history.jsonl` before being overwritten, so nothing is ever lost:

```bash
tail -1 ~/.config/prompt-enhancer/history.jsonl | jq -r .original
```

## Tuning

**The profile is where the value is, not the code.** Expect to edit `claude_code.md` a dozen times over your first week. When a rewrite disappoints you, open the file and add a rule addressing that specific failure, then hit ⌥⌘⇧R.

**Model.** Haiku is the default because latency is what makes or breaks this — a tool that takes four seconds is a tool you stop reaching for. If your dumps are long and tangled and you want better structural judgment, set `enhancer.model = "claude-sonnet-4-5-20250929"` in `init.lua`.

**Don't want auto-paste?** Set `enhancer.autoPaste = false` and the result lands on your clipboard instead, so you can look before you commit.

## Adding more profiles

Each new target is a new `.md` file plus one line in `init.lua`:

```lua
enhancer.bind({"cmd", "alt"}, "w", "long_form")
enhancer.bind({"cmd", "alt"}, "i", "image")
```

## If something goes wrong

Open the Hammerspoon console (menu bar icon → Console) to see errors. Common ones:

- **"Nothing selected"** — the ⌘C didn't land. Usually means Accessibility permission isn't granted, or the app doesn't support standard copy.
- **"API 401"** — key file is wrong or has a trailing newline from `echo`. Use `printf` as above.
- **Paste goes to the wrong place** — some terminals need ⌘V remapped; check your terminal's paste binding.
