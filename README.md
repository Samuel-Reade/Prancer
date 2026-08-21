# Prompt Enhancer

Select messy text anywhere on macOS, press a key, and it's replaced in place by a structured prompt for Claude Code.

```
the login thing is broken again, when the token expires it just spins forever
instead of kicking you back to /login. i think its in useAuth or maybe the
axios interceptor. dont want to rewrite the whole auth flow just fix the redirect
```

↓ press 🌐 ↓

```
Goal: Redirect to /login when an auth token expires, instead of hanging indefinitely.

Context: An expired token currently leaves the UI in a permanent loading state.
The handling is likely in `useAuth` or the axios response interceptor — check
both before editing.

Constraints: Minimal fix. Do not restructure the auth flow.

Done when: An expired token produces a redirect to /login rather than an
indefinite spinner.
```

Works in any app that supports copy and paste — editors, browsers, chat windows, terminals.

## Why

Writing a good prompt means stating an objective, naming the files in scope, listing constraints, and defining what "done" looks like. Typing that out every time is friction, so in practice you type a stream-of-consciousness dump instead and get worse results.

This closes that gap. You keep dumping; the tool does the structuring.

The important design decision: **all of the intelligence lives in a markdown file, not in code.** [`claude_code.md`](claude_code.md) is the system prompt. Changing behaviour means editing prose, not Lua.

## Requirements

| | |
|---|---|
| macOS | Event taps and the Globe key are macOS-specific |
| [Hammerspoon](https://www.hammerspoon.org/) | `brew install --cask hammerspoon` |
| Anthropic API key | From [console.anthropic.com](https://console.anthropic.com) — billed separately from a Claude subscription |
| Accessibility permission | Required; the tool sends synthetic ⌘C and ⌘V |

No Lua packages, no build step, no runtime beyond Hammerspoon itself.

## Install

**1. Hammerspoon**

```bash
brew install --cask hammerspoon
```

Launch it and grant Accessibility when prompted (System Settings → Privacy & Security → Accessibility). Without this the tool fails with "Nothing selected" on every press.

**2. Config directory and API key**

```bash
mkdir -p ~/.config/prompt-enhancer/profiles
```

Store the key **without a trailing newline**:

```bash
read -rs KEY && printf '%s' "$KEY" > ~/.config/prompt-enhancer/anthropic_key \
  && chmod 600 ~/.config/prompt-enhancer/anthropic_key && unset KEY
```

Run it, paste the key, press Return. Nothing echoes — that's intentional, and it keeps the key out of your shell history. Verify with `wc -c` (a normal key is ~108 bytes) and check it starts with `sk-ant-api03-`, not a doubled prefix.

**3. Install the files**

```bash
cp prompt_enhancer.lua ~/.hammerspoon/
cp init.lua            ~/.hammerspoon/
cp claude_code.md      ~/.config/prompt-enhancer/profiles/
```

Or symlink them, so this checkout stays the live source and edits take effect without copying:

```bash
ln -s "$PWD/prompt_enhancer.lua" ~/.hammerspoon/prompt_enhancer.lua
ln -s "$PWD/init.lua"            ~/.hammerspoon/init.lua
ln -s "$PWD/claude_code.md"      ~/.config/prompt-enhancer/profiles/claude_code.md
```

⚠️ With symlinks, Hammerspoon's auto-reload no longer fires for `init.lua` — it watches `~/.hammerspoon`, and edits land on the far side of the link. Reload manually from the menu bar icon after changing it.

**4. Free up the Globe key**

The default binding is a tap of 🌐, which macOS otherwise uses for the emoji picker:

```bash
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
```

Or System Settings → Keyboard → "Press 🌐 to:" → **Do Nothing**. May need a logout to take effect. To restore, set it back to `2` (Show Emoji & Symbols).

**5. Reload** from the Hammerspoon menu bar icon.

## Usage

| Key | Action |
|---|---|
| **🌐** | Enhance the selection |
| **⌥⌘C** | Same thing — fallback binding |
| **⌥⌘⇧R** | Reload profiles after editing the prompt |

Select text, press the key, watch the panel count off the stages, and about a second later your selection is replaced.

Only a *tap* of 🌐 triggers it. Holding it, or using it with another key (🌐+F5, 🌐+arrow), behaves normally — enforced by a 0.6s maximum hold and a check that nothing else was pressed.

### Nothing is ever lost

Every original is appended to `~/.config/prompt-enhancer/history.jsonl` **before** the paste:

```bash
tail -1 ~/.config/prompt-enhancer/history.jsonl | jq -r .original    # what you typed
tail -1 ~/.config/prompt-enhancer/history.jsonl | jq -r .enhanced    # what it produced
tail -1 ~/.config/prompt-enhancer/history.jsonl | jq -r .context     # repo context sent
```

## Key features

### The profile is the product

[`claude_code.md`](claude_code.md) is sent as the `system` field on every request. Its rules are what stop the common failure modes:

- **Never invent specifics** — missing details become `[SPECIFY: path to the auth middleware]` rather than a plausible fabrication
- **Don't add requirements** — no unrequested tests, logging, or refactors
- **Preserve uncertainty** — "I think it's in useAuth" stays a hunch, and becomes an instruction to investigate before editing
- **Match the input's scale** — a one-line request stays one line

Expect to edit it a dozen times in your first week. When a rewrite disappoints you, add a rule naming that specific failure and press ⌥⌘⇧R.

### Repo context

Each request carries a small block describing what you're working on:

```
Currently editing: prompt_enhancer.lua
Repo: Prancer  (branch main)
Last commit: Clean environment and initial commit
Uncommitted changes:
  Desktop/Prancer/init.lua
```

Under 100 tokens, so it costs no perceptible latency. Three guards keep it honest:

- **Editors only** (VS Code, Cursor, Zed, Sublime, Xcode, Nova). A browser tab title would otherwise become `Currently editing: Some Blog Post`.
- **Scoped to your folder** with `git status -- .`, so a home directory under git doesn't dump unrelated projects into the block.
- **Never fatal** — it runs in a `pcall`; failure means no block, not no rewrite.

The profile documents the block as a hint rather than a scope, so real paths get used without the model treating them as a mandate.

Disable with `M.contextEnabled = false`.

### The loading panel

A run has four stages, and the panel names the one it is in rather than spinning anonymously:

```
Prancing                                  claude-haiku-4-5
Rewriting your prompt                                 2.1s
218 words  ·  ~273 tok  ·  Prancer (branch main)
━━━━━━━━━━━━━━━━━━🚀 · · · · · · · · · · · · · · · · · ·
● ● ● ○                                                47%
```

The stage, the dots, the counts and the clock are all exact. **The percentage is an
estimate** — a single non-streaming POST has no real progress to report. Each stage
owns a slice of the bar and eases toward its ceiling without ever arriving, so a slow
model keeps the bar creeping instead of freezing at a number. It reaches 100% only
once the text is actually pasted.

It resolves in place rather than just vanishing: green with `218 → 312 words` on
success, red on failure carrying the API's own message plus a reminder that nothing
was pasted and your clipboard is untouched. Pressing the key again mid-run nudges the
panel instead of being dropped in silence.

Eyeball the animation without spending a token:

```bash
hs -c 'require("prompt_enhancer").previewHud()'        # success
hs -c 'require("prompt_enhancer").previewHud("fail")'  # failure
```

### Adding profiles

Each target is a markdown file plus one binding. Drop `long_form.md` into `~/.config/prompt-enhancer/profiles/` and bind it in `init.lua` — the code is target-agnostic.

## Configuration

All fields on `M`, at the top of [`prompt_enhancer.lua`](prompt_enhancer.lua):

| Field | Default | Notes |
|---|---|---|
| `model` | `claude-haiku-4-5-20251001` | Latency is what makes this tool usable. Swap to Sonnet for tangled dumps. |
| `maxTokens` | `2000` | |
| `autoPaste` | `true` | `false` leaves the result on the clipboard instead |
| `contextEnabled` | `true` | Repo context block |
| `projectRoots` | Desktop, Documents, Projects, src, ~ | Where to look for the folder named in the window title |
| `hudGlyph` | `🚀` | Rides the leading edge of the progress bar |
| `hudFps` | `60` | Animation frames per second |
| `hudDrop` | `0.70` | Vertical placement of the panel: `0` top of screen, `1` bottom |

## How it works

1. **Trigger** — an event tap fires `M.run("claude_code")`. An `inFlight` guard drops presses while one is in progress.
2. **Capture** — saves your clipboard, sends synthetic ⌘C, polls `changeCount` 40× at 20ms. That 800ms ceiling produces "Nothing selected".
3. **Enhance** — `POST https://api.anthropic.com/v1/messages` with the profile as `system` and your selection (plus context block) as the user message.
4. **Log** — appends to `history.jsonl`, before anything is overwritten.
5. **Deliver** — sets the clipboard, sends ⌘V, restores your original clipboard 0.4s later.

### Why event taps instead of `hs.hotkey`

`hs.hotkey.bind` registers successfully and logs `Enabled hotkey ⌘⌥C`, but the callback never fires on the machine this was built on — while event taps receive the same keystrokes reliably. So [`init.lua`](init.lua) binds from the event stream via a small `bindTap` helper.

This has an upside: `hs.hotkey` can't bind the Globe key at all, since `fn` isn't a modifier Carbon recognises. Event taps see it, which is what makes the default binding possible.

## Troubleshooting

Open the Hammerspoon console (menu bar icon → Console) for errors.

| Symptom | Cause |
|---|---|
| No panel at all | The keystroke never reached Hammerspoon. Check Accessibility, and that Hammerspoon is running. |
| **Nothing selected** | ⌘C didn't land — nothing highlighted, or the app doesn't support standard copy. Webviews and Electron surfaces are common culprits. |
| **API 401** | Key is wrong. Check for a doubled `sk-ant-` prefix, and confirm it's ~108 bytes starting `sk-ant-api03-`. |
| Emoji picker opens on 🌐 | `AppleFnUsageType` isn't set to `0`, or needs a logout. |
| Paste lands in the wrong place | Some terminals rebind ⌘V. Test in TextEdit first. |
| Edits to `init.lua` do nothing | Symlinked install — Hammerspoon's watcher doesn't see them. Reload from the menu bar. |

Nothing is lost to a failed run: the original is written to `history.jsonl` before the paste, and on any error the clipboard is restored and nothing is pasted.

## Files

```
prompt_enhancer.lua   capture, API call, history, loading HUD, repo context
claude_code.md        the rewrite rules — where behaviour lives
init.lua              key bindings
SETUP.md              original setup notes
```

The API key lives at `~/.config/prompt-enhancer/anthropic_key`, outside this repo, and should stay there.
