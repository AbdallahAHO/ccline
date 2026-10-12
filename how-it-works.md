# How ccline works

A walkthrough of `bin/statusline.sh` — what it reads, what it renders, and the handful of non-obvious tricks that keep it fast, portable, and safe.

## The contract

Claude Code invokes the statusline command on every render and pipes a JSON blob to stdin. Whatever the command prints to stdout is displayed beneath the prompt. That's the entire API:

```
┌────────────────────┐     JSON on stdin      ┌────────────────────┐
│    Claude Code     │ ─────────────────────► │   statusline.sh    │
└────────────────────┘                        └─────────┬──────────┘
         ▲                                              │
         │              ANSI text on stdout             │
         └──────────────────────────────────────────────┘
```

There is no return channel, no persistent state handed to us between invocations, and no guarantee the process won't be killed mid-render if it exceeds Claude Code's internal timeout. Everything below is designed around those three facts.

## Top-of-file setup

```bash
set -f                  # disable pathname expansion — we do string work, not globbing
export LC_ALL=C         # force C locale — stable date parsing & sort order
input=$(cat)            # slurp stdin once; we'll parse it with a single jq
```

If stdin is empty (e.g. a user testing the script manually) we exit early printing `"Claude"` so Claude Code still shows *something* rather than a blank line.

## The single `jq` parse

Spawning `jq` once per field would mean 15+ subprocesses on every keystroke of context change. Instead we parse all fields in one shot and hydrate them into shell variables via `eval` (the usage API response gets the same treatment — one `jq` call for all of its fields):

```bash
eval "$(printf '%s' "$input" | jq -r '
  "model_name=" + (.model.display_name // "Claude" | @sh),
  "ctx_size="   + (.context_window.context_window_size // 200000 | tostring),
  "pct_used="   + (.context_window.used_percentage // 0 | floor | tostring),
  ...
')"
```

Two safety details:

- `@sh` on free-text fields shell-escapes the value — so a project named `my'proj` can't break out of the `eval`.
- Every field has a `//` default so a missing key never produces an `eval` syntax error.

After this one call, everything the script needs is a plain shell variable.

## Helpers worth knowing about

| Helper             | Job                                                                                   |
|--------------------|----------------------------------------------------------------------------------------|
| `format_tokens`    | `1543` → `1.5k`, `1_200_000` → `1.2m`                                                 |
| `color_for_pct`    | Picks green / orange / yellow / red from a percentage                                 |
| `build_bar`        | Renders a filled/empty dot bar (`●●●○○○○○`)                                          |
| `iso_to_epoch`     | ISO-8601 → unix epoch — tries GNU `date -d` first, falls back to BSD `date -j -f`     |
| `to_epoch`         | Accepts either an ISO string OR an integer epoch; returns epoch or empty              |
| `format_reset_time`| Epoch → `3:42pm`, `fri 7pm` (inside 6 days) or `apr 3, 7pm`, lowercased on BSD and GNU |
| `render_spend_lines`| Extra-credit row, or Enterprise spend/pace/month rows — one `awk` pass for all numbers and compact money (`$10K`, `$350`, `€0.95`) |
| `file_birth_epoch` | Portable birth-time lookup (BSD `stat -f %B`, GNU `stat -c %W`, mtime fallback)       |

The `date` / `stat` helpers all have a *BSD path* and a *GNU path* because macOS ships BSD userland and Linux ships GNU coreutils — the flags are incompatible. We always try one, fall back to the other.

## Line 1 — identity & project

Assembled into `$line1` in this order:

1. **Model + effort** — `O4.7 1M ◉ xhigh`. The model name is compacted (`Opus ` → `O`, `(1M context)` → `1M`) via a single `sed` pipeline. Effort level is the live `.effort.level` from the input JSON (so `/effort` changes show immediately), falling back to `~/.claude/settings.json`'s `.effortLevel`; each value maps to a distinct glyph/color pair.
2. **Permission-mode badge** — `🛡 plan`, `✎ auto`, `⚡ bypass`. Hidden when the mode is `default`.
3. **Output-style badge** — `◎ <name>` when a non-default output style is active.
4. **Vim mode** — `[N]` or `[I]` when vim mode is on.
5. **Project** — `📂 <name> (<branch><dirty>) 📝+X -Y`. The branch and dirty flag come from a single `git status --porcelain=v1 -b` call wrapped in `GIT_OPTIONAL_LOCKS=0` so a killed statusline can't leave a stale `.git/index.lock` behind.
6. **Agent / worktree / session name** — only rendered when present.
7. **Relative cwd** — if the current dir differs from the project root, show the remainder (`→ src/features/search`). If cwd is outside the project entirely, fish-style abbreviate (`~/D/P/ccline`).
8. **200k flag** — `⚠ 200k+` when Claude Code's input JSON has `.exceeds_200k_tokens: true`: the latest response crossed the fixed 200k-token threshold (long-context pricing on 1M models). It is not a downgrade.

## Line 2 — session health

Built from the same hydrated variables, in this order:

1. **Turn counter** — scans the transcript file for `"type":"user"` lines, *excluding* lines carrying `tool_use_id` (tool results also have `type:user` and inflate the count ~10×). Color ramps: white → yellow at 30 → red at 50.
2. **Session duration** — `now - file_birth_epoch(transcript_path)`. Birth time is the correct start marker because the transcript file is created at session start and never rotated.
3. **Context usage** — `pct% used_tokens/ctx_size ctx`, with autocompact warnings appended:
   - `compact soon` at `ctx_size - 33k`
   - `compacting…` at `ctx_size - 13k`
   - `⛔ blocked` at `ctx_size - 3k`
   These thresholds mirror `AUTOCOMPACT_BUFFER_TOKENS` / `WARNING_THRESHOLD_BUFFER_TOKENS` / `MANUAL_COMPACT_BUFFER_TOKENS` in `src/services/compact/autoCompact.ts` of Claude Code.
4. **Session cost** — `$X.XX`, yellow at $5, red at $10.
5. **API-latency ratio** — `total_api_duration_ms / total_duration_ms`. How much of the session's wall-clock was spent waiting on the model. Useful signal for "am I bottlenecked on the model or on my own typing?".

## Rate limits — the two-source strategy

Rate-limit bars (5h and 7d) are rendered by `render_rate_lines`, which takes `(five_hour_pct, five_hour_reset, seven_day_pct, seven_day_reset)` and doesn't care where the numbers came from. Two sources, in priority order:

1. **Input JSON** — if Claude Code includes `.rate_limits.five_hour` / `.seven_day` in the payload, those numbers are authoritative (generated server-side right before the render) — even at 0%, so presence is checked rather than value.
2. **OAuth API fallback** — otherwise (typically the very first render after launch) the windows come from `https://api.anthropic.com/api/oauth/usage`, called with a Bearer token and cached for 60 seconds under `${TMPDIR:-/tmp}/claude-${UID}/statusline-usage-cache.json` (`0700`). The cache directory is per-UID so a multi-user box can't cross-pollute.

A fetch counts as successful on HTTP 200 alone: spend-billed plans answer with `null` `five_hour` / `seven_day`, which is valid and simply means there are no windows to draw.

The API response also carries the per-model weekly buckets (`limits[]`) and an `extra_usage` block — add-on credits on Pro/Max, the whole budget on Enterprise — so the API is consulted (through the shared cache) even when the input JSON has the windows.

### Spend rows

`render_spend_lines` draws `extra_usage`. On Pro/Max that is one `extra` row. When the response has no windows (Enterprise), it draws three rows in the slots `current` / `weekly` would use:

- **spend** — used ÷ cap, rounded but held at 99% while money is left; `⚠ 50%+` / `🚨 80%+` show what's left, `⛔ CAP HIT` the limit. `▲ over pace` / `▼ under pace` when spend% is more than 5 points from month%.
- **pace** — `used ÷ days elapsed` projected over the whole month (the first half-day counts as half a day so an early session can't spike it). `⚡ cap by <date>` when that rate exhausts the cap before the reset, `⚠ tight` from 80%, else `✓ on track`.
- **month** — share of the calendar month gone (dim: time is neither good nor bad) and `(cap − used) ÷ days left` as the daily budget.

### OAuth token resolution

Tried in this order, first hit wins:

1. `$CLAUDE_CODE_OAUTH_TOKEN` environment variable
2. macOS Keychain (`security find-generic-password -s "Claude Code-credentials"`)
3. `~/.claude/.credentials.json` (works on every platform — the only path on Windows since `security` and `secret-tool` don't exist there)
4. Linux `secret-tool lookup service "Claude Code-credentials"`

Each step extracts `.claudeAiOauth.accessToken` via `jq`. If everything fails we just skip the API call — the input-JSON path still works.

### "Burning fast" heuristics

Both windows get a `⚡ burning fast` flag when usage is outrunning the elapsed window fraction:

- **5h**: ≥90% used *and* ≥72% of the window elapsed → burning fast
- **7d**: tiered — ≥75% used by 60% elapsed, ≥50% by 35%, or ≥25% by 15%

The 7d row also shows a projected `~X%/day` burn rate colored green/yellow/red against the 100% projection.

### Peak hour detection

Between 05:00–11:00 Pacific, Anthropic's 5h limits are tighter. We compute the PT hour and append `🔥 PEAK til <local time>` to the 5h row when we're in that window. `peak_end_local` is computed in PT but formatted in the user's local timezone so the "til" time is meaningful wherever you are.

## Caching & temp files

The only thing cached to disk is the OAuth API response (60s TTL) at `${TMPDIR:-/tmp}/claude-${UID}/statusline-usage-cache.json`. We:

- `mkdir -p` the dir with `0700` perms, then `umask 077` on the write
- Use `stat -c %Y` / `stat -f %m` (GNU / BSD) to read mtime for cache freshness
- Fall back to the cache when a new API call fails, but only while it is ≤15 minutes old — older data is more likely wrong (e.g. from before an account switch) than useful
- Write a one-line backoff marker (`statusline-usage-backoff`, the epoch to retry after) on a failed fetch: 5 minutes after a 429/403 — Claude Code's own backoff — 1 minute after a timeout, 5xx or offline. Every session reads it, so a failing endpoint costs one request per window, not one per render. Unreadable or implausible values are ignored.

No lock files, no pidfiles.

## Cross-platform considerations

Every non-trivial external command has a fallback path because the same name behaves differently on BSD vs GNU:

- **`date`**: GNU has `-d "string"` and `-d "@epoch"`; BSD has `-j -f "format" "string"` and `-j -r epoch`
- **`stat`**: GNU uses `-c` format-specifiers; BSD uses `-f`
- **Birth time**: true birthtime exists on macOS (`stat -f %B`) and recent GNU coreutils (`stat -c %W`), but some filesystems (ext4 on older kernels, tmpfs) don't record it — we degrade to mtime so session duration is approximate but never missing

The script runs on macOS (default path), Linux, WSL, and Git Bash/MSYS2. It does *not* run as PowerShell — users need to invoke it through `bash -c` if their Claude Code is launched from PowerShell.

## Failure modes

Everything below is designed to degrade quietly rather than fail loudly — the statusline should never blow up mid-render:

| Scenario                                 | Behavior                                                    |
|------------------------------------------|-------------------------------------------------------------|
| `jq` missing                             | `eval` sees empty string, all vars unset, minimal line prints |
| `git` missing or cwd isn't a repo        | Branch segment silently omitted                             |
| OAuth token unresolvable                 | API fallback skipped, input-JSON bars still render          |
| API request times out (3s cap)           | Serve cache ≤15 min old, else skip API rows; retry in 1 min |
| API rate-limits (429/403)                | One request per 5 min across sessions; cache ≤15 min shown  |
| Plan has no session/weekly windows       | Spend / pace / month rows instead of current / weekly       |
| Transcript file unreadable               | Turn counter and session duration skipped                   |
| Index-refresh would take `.git/index.lock` | `GIT_OPTIONAL_LOCKS=0` skips the refresh entirely         |
| Filesystem without birth time            | Session duration falls back to mtime-based approximation    |

## Performance notes

The hottest optimizations in the current code:

- **One `jq` per JSON document** (input + usage response) instead of one per field saves ~150ms per render on slow machines
- **One `git status`** captures branch + dirty together
- `GIT_OPTIONAL_LOCKS=0` avoids the stat-refresh path entirely — slightly faster *and* lock-safe
- 60s cache on API responses, shared by every session, means at most one network call per minute — and one per backoff window while the API is failing
- No `claude --version` subprocess (removed in 1.3.0 — was adding 300–500ms per cache miss)

A cold render (empty cache, first launch) spends the most time in the jq parse and the optional API call. A warm render is essentially instant.
