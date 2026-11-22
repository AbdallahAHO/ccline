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
| `format_reset_time`| Epoch → `3:42pm`, `fri 7pm` (inside 6 days) or `apr 3, 7pm`, rounded to the minute, lowercased on BSD and GNU |
| `weekly_outlook`   | Percent + reset epoch → `· resets fri 7pm`, or `· out tue 10am · budget 10%/day` when the average rate runs out first |
| `render_spend_lines`| Extra-credit row, or Enterprise spend/pace/month rows — one `awk` pass for all numbers and compact money (`$10K`, `$350`, `€0.95`) |

The `date` / `stat` helpers all have a *BSD path* and a *GNU path* because macOS ships BSD userland and Linux ships GNU coreutils — the flags are incompatible. We always try one, fall back to the other.

## Line 1 — identity & project

Assembled into `$line1` in this order:

1. **Model + effort** — `O4.7 1M ◉ xhigh`. The model name is compacted (`Opus ` → `O`, `Fable ` → `F`, `(1M context)` → `1M`) via a single `sed` pipeline. Effort level is the live `.effort.level` from the input JSON (so `/effort` changes show immediately), falling back to `~/.claude/settings.json`'s `.effortLevel` inside the same `jq` call; each value maps to a distinct glyph/color pair.
2. **Fast mode** — `↯ fast` when `.fast_mode` is true.
3. **Permission-mode badge** — `🛡 plan`, `✎ auto`, `⚡ bypass`. Hidden when the mode is `default`.
4. **Output-style badge** — `◎ <name>` when a non-default output style is active.
5. **Vim mode** — `[N]` or `[I]` when vim mode is on.
6. **Project** — `📂 <name> (<branch><dirty>) PR #N 📝+X -Y`. The PR badge comes from `.pr.number` and is coloured by `.pr.review_state` (`approved` ✓ green, `changes_requested` ✗ red, `merged` magenta, `draft` / `closed` dim). The branch and dirty flag come from a single `git status --porcelain=v1 -b` call wrapped in `GIT_OPTIONAL_LOCKS=0` so a killed statusline can't leave a stale `.git/index.lock` behind.
7. **Agent / worktree / session name** — only rendered when present.
8. **Relative cwd** — if the current dir differs from the project root, show the remainder (`→ src/features/search`). If cwd is outside the project entirely, fish-style abbreviate (`~/D/P/ccline`).
9. **200k flag** — `⚠ 200k+` when Claude Code's input JSON has `.exceeds_200k_tokens: true`: the latest response crossed the fixed 200k-token threshold (long-context pricing on 1M models). It is not a downgrade.

## Line 2 — context, cost, cache

1. **Context** — `ctx ●●●○○○○○ 391k/784k`: the tokens in context against the point where they compact, coloured by that share. The point is the one Claude Code 2.1.330 computes: the window is the model's, or a smaller configured one (`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, then `modelSettings.<model id>.autoCompactWindow`, then `autoCompactWindow` in `~/.claude/settings.json`; `500k` and `500000` both read, under 100k counts as 100k). 20k of it is reserved for output. Compaction starts 13k below that, or at `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` percent of it when that comes sooner. With auto-compact off (`autoCompactEnabled: false`, `DISABLE_AUTO_COMPACT`, `DISABLE_COMPACT`) the meter counts to the block instead, 3k below the model's own reserve. The settings file is read with a shell builtin and handed to the one `jq` call, which does this arithmetic; only the user's `settings.json` is read, not project or managed settings.
2. **Turns left** — `· ~12 turns`: `(compaction point − used) ÷ (used ÷ turns)`, from the third turn, once under 100; yellow at 5, red at 2. The turn count scans the transcript for `"type":"user"` lines, excluding those carrying `tool_use_id` (tool results are also `type:user`). It is an average over the session, so it reads high right after a compaction. In its place: `compacting…` past the compaction point, `⛔ blocked` past the block, and `compact soon` within 20k of compaction before there are enough turns to average.
3. **Cost** — `$33.03 · $8.1/h`: `.cost.total_cost_usd`, and per hour of `total_duration_ms` once the session is ten minutes old. The rate carries the colour: yellow from $10/h, red from $20/h. One `awk` pass.
4. **Prompt cache** — from `.prompt_cache`: `cache til 10:12pm` is `expires_at` while `warm` is true, with `· 2 misses` when `misses` is above zero. It is a clock time because a countdown would freeze between renders. Once cold: `cache cold · 391k to rebuild` (`recache_tokens_if_cold`). Nothing is shown when `caching_observed` is false.

## Rate limits — the two-source strategy

Rate-limit bars (5h and 7d) are rendered by `render_rate_lines`, which takes `(five_hour_pct, five_hour_reset, seven_day_pct, seven_day_reset, show_current)` and doesn't care where the numbers came from. The `current` row is dropped when the plan has no 5-hour limit: the server's `limits[]` has no `session` row, its `five_hour` is null, and Claude Code sent no 5-hour window. Without `limits[]` to go by, the row stays. Two sources, in priority order:

1. **Input JSON** — if Claude Code includes `.rate_limits.five_hour` / `.seven_day` in the payload, those numbers are authoritative (generated server-side right before the render) — even at 0%, so presence is checked rather than value.
2. **OAuth API fallback** — otherwise (typically before the session's first response) the windows come from the cached `https://api.anthropic.com/api/oauth/usage` response, while that cache is under 15 minutes old.

A fetch counts as successful on HTTP 200 alone: spend-billed plans answer with `null` `five_hour` / `seven_day`, which is valid and simply means there are no windows to draw.

The API response also carries the server's usage rows (`limits[]`) and an `extra_usage` block — add-on credits on Pro/Max, the whole budget on Enterprise — so the cache is read even when the input JSON has the windows.

### Server-driven rows

`limits[]` is the server's own list of meters: each row has a `kind` (`session`, `weekly_all`, `weekly_scoped`, …), a `percent`, a `resets_at`, an optional `scope` naming a model or a surface, and a `severity`. `session` and `weekly_all` are the current/weekly windows. Every other row is drawn as its own meter in the server's order, labelled by `scope.model.display_name`, else `scope.surface.display_name`, else the kind — so a meter Anthropic adds later shows up without a release. `severity` can raise a row's colour (`warning` → yellow, `critical` → red) but never lowers it. A row whose `resets_at` has passed is dropped, since a cached percent is wrong once its window resets.

A body without `limits[]` (an older server) falls back to the top-level `seven_day_opus` / `seven_day_sonnet` windows. A plan without any window (spend-billed) keeps only the model-scoped weekly rows, so its three spend rows stay exactly as they were.

Two more parts of the body decorate these rows:

- **`weekly_scoped_shares`** — for the row at `limit_index`, `used_percent_of_weekly` and `allowance_percent_of_weekly` become `· 15/50% of weekly`: the row's own percent is of its allowance, and this is the same usage as a share of the whole week.
- **`cedar_ember`** — the plan's limit resets, returned because the request carries `?cedar_ember=1`. Each grant lists the windows it `clears` and its `resets_left`. Grants that clear `seven_day` count for the `weekly` row; grants that clear only `seven_day_overage_included` count for model rows. A row at 80% or more shows `↺ N resets`. Paused, unusable or ineligible grants are not counted, and the model count applies only when there is exactly one model row.

### Fetching without blocking the render

The usage endpoint answers 429 when it is asked too often, with a `Retry-After` that has been seen at half an hour. Two things could turn one request a minute into a stream of them: Claude Code aborts a render that a newer one supersedes, so a render blocked in `curl` could be killed before it wrote the cache and the next render sent the request again; and every open session did the same when the cache expired.

So a render never fetches. It draws the cache and, when the cache is over 5 minutes old and the next-request marker has passed, does two things:

1. **Claims the next minute** by writing `now + 60` to the marker (`statusline-usage-backoff`) before any request goes out. Every session reads the marker, so one request is sent no matter how many renders overlap.
2. **Starts `refresh_usage_cache` detached** — a subshell with `set -m`, which gives the background job its own process group, so a kill aimed at the render's group cannot reach it. The job resolves the OAuth token, calls the API (the token goes to `curl` on stdin, never in `ps`), writes the body whole and renames it into place. A plan whose cached body has windows is asked for its limit resets with `?cedar_ember=1`; an answer to that other than 200, 401, 403 or 429 is tried once more without it. A spend-billed plan and every cold start send the plain request, exactly as before. On a failure it pushes the marker out by the server's `Retry-After` plus 30 seconds, or 5 minutes after a 429/403 without one, 1 minute after a timeout, 5xx or offline — a day at most. The wait is honored in full because a request sent inside the penalty has been seen to lengthen it (30 minutes became an hour).

The next render picks up the result. Only a cold start, with nothing to show, waits for that fetch — two seconds at most, less if it fails — so a plan whose only rows come from the API has them on its first render. While the API is failing, the cached rows stay up for 2 hours, marked `· 20m old` once they pass 15 minutes.

### Spend rows

`render_spend_lines` draws `extra_usage` while `is_enabled` is true. On Pro, Max and Ultra that is one `extra` row. When the response has no windows (Enterprise), it draws three rows in the slots `current` / `weekly` would use:

- **spend** — used ÷ cap, rounded but held at 99% while money is left; `⚠ 50%+` / `🚨 80%+` show what's left, `⛔ CAP HIT` the limit. `▲ over pace` / `▼ under pace` when spend% is more than 5 points from month%.
- **pace** — `used ÷ days elapsed` projected over the whole month (the first half-day counts as half a day so an early session can't spike it). `⚡ cap by <date>` when that rate exhausts the cap before the reset, `⚠ tight` from 80%, else `✓ on track`.
- **month** — share of the calendar month gone (dim: time is neither good nor bad) and `(cap − used) ÷ days left` as the daily budget.

### OAuth token resolution

Tried in this order, first hit wins:

1. `$CLAUDE_CODE_OAUTH_TOKEN` environment variable
2. macOS Keychain (`security find-generic-password -s "Claude Code-credentials"`)
3. `~/.claude/.credentials.json` (works on every platform — the only path on Windows since `security` and `secret-tool` don't exist there)
4. Linux `secret-tool lookup service "Claude Code-credentials"`

Each step extracts `.claudeAiOauth.accessToken` via `jq`. It runs inside the detached fetch, so a slow keychain never delays a render. If everything fails we just skip the API call — the input-JSON path still works.

### Weekly outlook and burning fast

`weekly_outlook` takes a row's percent and reset epoch and, in one `awk` pass, divides the percent by the days elapsed in the 7-day window. If that daily rate reaches 100% before the reset, the row ends `· out tue 10am` in red — the claude.ai usage page's "at this pace you'll run out Tuesday evening" — and the `weekly` row adds `· budget 10%/day`, what is left divided by the days to the reset. Otherwise the row ends `· resets fri 7pm`. Model rows whose `group` is `weekly` use the same function without the budget.

The 5h row gets `· burning fast` at 90% used with more than 28% of the window still to go.

## Caching & temp files

The only things on disk are the usage-API response and the next-request marker, both under `${TMPDIR:-/tmp}/claude-${UID}/`. We:

- `mkdir -p` the dir with `0700` perms, then `umask 077` on the writes
- Use `stat -c %Y` / `stat -f %m` (GNU / BSD) to read mtime for cache age
- Write the response to `statusline-usage-cache.json.tmp` and `mv` it into place, so a reader never sees half a body
- Treat the marker as an epoch, not a lock: a value that is unreadable or more than a day ahead is ignored, so nothing can get stuck

No lock files, no pidfiles.

## Cross-platform considerations

Every non-trivial external command has a fallback path because the same name behaves differently on BSD vs GNU:

- **`date`**: GNU has `-d "string"` and `-d "@epoch"`; BSD has `-j -f "format" "string"` and `-j -r epoch`
- **`stat`**: GNU uses `-c` format-specifiers; BSD uses `-f`

The script runs on macOS (default path), Linux, WSL, and Git Bash/MSYS2. It does *not* run as PowerShell — users need to invoke it through `bash -c` if their Claude Code is launched from PowerShell.

## Failure modes

Everything below is designed to degrade quietly rather than fail loudly — the statusline should never blow up mid-render:

| Scenario                                 | Behavior                                                    |
|------------------------------------------|-------------------------------------------------------------|
| `jq` missing                             | `eval` sees empty string, all vars unset, minimal line prints |
| `git` missing or cwd isn't a repo        | Branch segment silently omitted                             |
| OAuth token unresolvable                 | No request; retried in 5 min; input-JSON bars still render  |
| API request times out (5s cap)           | Render is unaffected; cached rows stay up; retry in 1 min   |
| API rate-limits (429/403)                | Wait out `Retry-After` (≤1 day); cached rows shown up to 2 h |
| Plan has no session/weekly windows       | Spend / pace / month rows instead of current / weekly       |
| Transcript file unreadable               | Turns-left estimate skipped                                 |
| Index-refresh would take `.git/index.lock` | `GIT_OPTIONAL_LOCKS=0` skips the refresh entirely         |

## Performance notes

The hottest optimizations in the current code:

- **One `jq` per JSON document** (input + usage response) instead of one per field saves ~150ms per render on slow machines
- **One `git status`** captures branch + dirty together
- `GIT_OPTIONAL_LOCKS=0` avoids the stat-refresh path entirely — slightly faster *and* lock-safe
- The usage API is never called in the render path: one detached request per 5 minutes, shared by every session, and one per `Retry-After` window while the API is failing
- No `claude --version` subprocess (removed in 1.3.0 — was adding 300–500ms per cache miss)

A cold render (empty cache, first launch) waits up to two seconds for the first API response. Every render costs the two jq parses and one `git status`.
