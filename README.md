# ccline

A feature-rich statusline for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that helps you track session health, manage quota, and avoid burning through your Max plan.

![demo](.github/demo.png)

## What you get

**Line 1 — Identity & Project**
```
O4.6 1M ● high | 📂 really-app (main*) 📝+147 -38 | → src/features/search
```
- Compact model name with effort level
- Project root with git branch and dirty indicator
- Lines changed this session
- Current working directory (relative to project, fish-style if outside)

**Line 2 — Session Health**
```
#84 turns | ⏱ 2h14m | 72% 720k/1m ctx compact? | $12.41
```
- Turn counter (yellow at 30, red at 50 — time to start fresh)
- Session duration
- Context window usage with absolute tokens and compaction nudge at 60%+
- Running session cost (yellow at $5, red at $10)

**Lines 3-4 — Quota & Rate Limits**
```
current ●●●●●●●○○○  68% resets 3:42pm  🔥 PEAK til 8pm
weekly  ●●●●●●●●○○  81% resets apr 3, 7:00pm  ~22%/day
```
- 5-hour and 7-day rate limit bars via Anthropic OAuth API (cached, 60s TTL)
- Peak hour detection (05:00-11:00 PT) with local end time — only shows when active
- Weekly burn rate projection — green if on pace, yellow if tight, red if you'll hit the limit

## Install

```bash
npx @abdallahaho/ccline
```

This copies the statusline script to `~/.claude/statusline.sh` and configures your `~/.claude/settings.json`. Restart Claude Code to see it.

If you already have a custom statusline, it's backed up to `statusline.sh.bak` first.

## Requirements

- `jq`, `curl`, `git`
- Claude Code with an active Max/Pro subscription (for rate limit bars)

```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt install jq curl git
```

## Uninstall

```bash
npx @abdallahaho/ccline --uninstall
```

Restores your previous statusline if a backup exists, or removes it and cleans up settings.json.

## How it works

Claude Code pipes a JSON blob to the statusline script on every render. The script extracts model info, context usage, session cost, and workspace data from that JSON. Rate limit data is fetched from the Anthropic OAuth API and cached for 60 seconds at `/tmp/claude/statusline-usage-cache.json`.

The OAuth token is resolved from (in order):
1. `$CLAUDE_CODE_OAUTH_TOKEN` environment variable
2. macOS Keychain
3. `~/.claude/.credentials.json`
4. Linux `secret-tool`

## Credits

Heavily inspired by [kamranahmedse/claude-statusline](https://github.com/kamranahmedse/claude-statusline) by Kamran Ahmed.

## License

MIT
