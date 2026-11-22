#!/usr/bin/env bash
# ccline — Claude Code statusline
# Works on macOS, Linux, and Windows (Git Bash / MSYS2, WSL).

set -f
export LC_ALL=C

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}|${reset} "

# ── Helpers ─────────────────────────────────────────────
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ] 2>/dev/null; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ] 2>/dev/null; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ] 2>/dev/null; then printf '%s' "$red"
    elif [ "$pct" -ge 70 ] 2>/dev/null; then printf '%s' "$yellow"
    elif [ "$pct" -ge 50 ] 2>/dev/null; then printf '%s' "$orange"
    else printf '%s' "$green"
    fi
}

# ISO 4217 code → symbol. The usage API reports the account's billing currency
# (e.g. EUR for European plans), so the spend line follows it instead of a
# hardcoded "$". Unknown codes fall back to "<CODE> " to stay unambiguous.
currency_symbol() {
    case "$1" in
        USD) printf '$' ;;
        EUR) printf '€' ;;
        GBP) printf '£' ;;
        JPY) printf '¥' ;;
        *)   printf '%s ' "$1" ;;
    esac
}

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    # Any usage gets a dot, so 7% doesn't read as untouched.
    [ "$pct" -gt 0 ] 2>/dev/null && [ "$filled" -eq 0 ] && filled=1
    local empty=$(( width - filled ))
    local bar_color="${3:-}"   # optional override, e.g. dim for neutral meters
    [ -z "$bar_color" ] && bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    local i
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf '%b' "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

# ISO 8601 string → unix epoch seconds. Tries GNU `date -d` first
# (Linux, Git Bash, WSL), falls back to BSD `date -j -f` (macOS).
iso_to_epoch() {
    local iso_str="$1"
    local epoch

    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        printf '%s' "$epoch"
        return 0
    fi

    local stripped="${iso_str%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"

    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        printf '%s' "$epoch"
        return 0
    fi
    return 1
}

# Accepts ISO string OR integer epoch seconds.
to_epoch() {
    local val="$1"
    [ -z "$val" ] || [ "$val" = "null" ] || [ "$val" = "0" ] && return 1
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        printf '%s' "$val"
        return 0
    fi
    iso_to_epoch "$val"
}

format_reset_time() {
    local val="$1"
    local style="$2"
    [ -z "$val" ] || [ "$val" = "null" ] || [ "$val" = "0" ] && return

    local epoch
    epoch=$(to_epoch "$val")
    [ -z "$epoch" ] && return
    # The API's resets land a fraction before the minute (21:59:59.87).
    epoch=$(( (epoch + 30) / 60 * 60 ))

    # Inside the next 6 days a weekday ("sat 12am") is unambiguous and shorter
    # than a date. ":00" is dropped, and both date flavours are lowercased.
    local fmt
    case "$style" in
        time)     fmt="%l:%M%p" ;;
        hour)     fmt="%a %l%p" ;;
        datetime) fmt="%b %-d, %l:%M%p"
                  [ $(( epoch - $(date +%s) )) -lt 518400 ] && fmt="%a %l:%M%p" ;;
        *)        fmt="%b %-d" ;;
    esac

    local result
    result=$(date -d "@$epoch" +"$fmt" 2>/dev/null || date -j -r "$epoch" +"$fmt" 2>/dev/null)
    printf '%s' "$result" | tr '[:upper:]' '[:lower:]' | sed 's/  */ /g; s/^ //; s/\.//g; s/:00//'
}

# ── Single jq parse ────────────────────────────────────
# The user's settings ride along as an argument (read with a builtin, not a
# subprocess): they hold the saved effort level and the auto-compact window.
user_settings=""
[ -r "$HOME/.claude/settings.json" ] && user_settings=$(<"$HOME/.claude/settings.json")
case "${DISABLE_AUTO_COMPACT:-} ${DISABLE_COMPACT:-}" in
    *1*|*[Tt][Rr][Uu][Ee]*|*[Yy][Ee][Ss]*|*[Oo][Nn]*) env_compact_off=true ;;
    *) env_compact_off=false ;;
esac

eval "$(printf '%s' "$input" | jq -r \
    --arg user_settings "$user_settings" \
    --arg env_window "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" \
    --arg env_pct "${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}" \
    --argjson env_compact_off "$env_compact_off" '
  # A window size as Claude Code reads it: 500000, "500k", "1m"; under 100k
  # counts as 100k; "auto" and anything unreadable is no setting at all.
  def size: (if type == "number" then .
      elif type == "string" then ([ascii_downcase | gsub("[ ,_]"; "") | capture("^(?<n>[0-9]+(\\.[0-9]+)?)(?<u>[km]?)$")][0]
          | if . == null then null else (.n | tonumber) * (if .u == "k" then 1000 elif .u == "m" then 1000000 else 1 end) end)
      else null end)
    | if . == null then null elif . < 100000 then 100000 else floor end;
  (((try ($user_settings | fromjson) catch null) | objects) // {}) as $settings
  | ((.context_window.context_window_size | numbers | floor) // 200000) as $ctx
  | (.model.id // "" | tostring) as $model_id
  # Auto-compact, as Claude Code computes it: the window is the model window
  # or a smaller configured one (env, then per-model setting, then setting);
  # 20k of it is reserved for output; compaction starts 13k below that, or at
  # CLAUDE_AUTOCOMPACT_PCT_OVERRIDE percent of it when that comes sooner.
  | (($env_window | if . == "" then null else size end)
      // ($settings.modelSettings[$model_id]?.autoCompactWindow | size)
      // ($settings.autoCompactWindow | size)) as $configured
  | ([$ctx, $configured // $ctx] | min) as $window
  | ($window - 20000) as $usable
  | (($env_pct | tonumber?) // 0) as $pct
  | (if $pct > 0 and $pct <= 100 then ($usable * $pct / 100 | floor) else $usable end) as $pct_point
  | ([$pct_point, $usable - 13000] | min) as $compact_at
  | ((.prompt_cache | objects) // {}) as $cache
  | "autocompact_threshold=" + ($compact_at | tostring),
  "blocking_threshold=" + ($ctx - 23000 | tostring),
  "autocompact_on=" + (($settings.autoCompactEnabled == false or $env_compact_off) | not | tostring),
  "cache_misses=" + (($cache.misses | numbers | floor) // 0 | tostring),
  "cache_cold_cost=" + (($cache.recache_tokens_if_cold | numbers | floor) // 0 | tostring),
  "has_input_five_hour=" + (.rate_limits.five_hour != null | tostring),
  "model_name=" + (.model.display_name // "Claude" | @sh),
  "cwd=" + (.workspace.current_dir // "" | @sh),
  "project_dir=" + (.workspace.project_dir // "" | @sh),
  "ctx_size=" + ($ctx | tostring),
  "pct_used=" + (.context_window.used_percentage // 0 | floor | tostring),
  "input_tokens=" + (.context_window.current_usage.input_tokens // 0 | tostring),
  "cache_create=" + (.context_window.current_usage.cache_creation_input_tokens // 0 | tostring),
  "cache_read=" + (.context_window.current_usage.cache_read_input_tokens // 0 | tostring),
  "total_input=" + (.context_window.total_input_tokens // 0 | tostring),
  "total_output=" + (.context_window.total_output_tokens // 0 | tostring),
  "session_cost=" + (.cost.total_cost_usd // 0 | tostring),
  "lines_added=" + (.cost.total_lines_added // 0 | tostring),
  "lines_removed=" + (.cost.total_lines_removed // 0 | tostring),
  "total_duration=" + (.cost.total_duration_ms // 0 | tostring),
  "has_input_limits=" + ((.rate_limits.five_hour != null or .rate_limits.seven_day != null) | tostring),
  "five_hour_pct=" + (.rate_limits.five_hour.used_percentage // 0 | floor | tostring),
  "five_hour_reset=" + (.rate_limits.five_hour.resets_at // "" | @sh),
  "seven_day_pct=" + (.rate_limits.seven_day.used_percentage // 0 | floor | tostring),
  "seven_day_reset=" + (.rate_limits.seven_day.resets_at // "" | @sh),
  "exceeds_200k=" + (.exceeds_200k_tokens // false | tostring),
  "fast_mode=" + (.fast_mode == true | tostring),
  "pr_number=" + ((.pr | objects | .number | numbers | floor) // "" | tostring | @sh),
  "pr_state=" + ((.pr | objects | .review_state | strings) // "" | @sh),
  "cache_state=" + ((.prompt_cache | objects
      | if .caching_observed == false then "" elif .warm == true then "warm" else "cold" end) // "" | @sh),
  "cache_expires=" + ((.prompt_cache | objects | .expires_at | numbers | floor) // 0 | tostring),
  "effort=" + ((.effort.level | strings) // ($settings.effortLevel | strings) // "default" | @sh),
  "permission_mode=" + (.permission_mode // "" | @sh),
  "output_style=" + (.output_style.name // "" | @sh),
  "vim_mode=" + (.vim.mode // "" | @sh),
  "session_name=" + (.session_name // "" | @sh),
  "agent_name=" + (.agent.name // "" | @sh),
  "worktree_name=" + (.worktree.name // "" | @sh),
  "transcript_path=" + (.transcript_path // "" | @sh)
')"

# ── Derived values ─────────────────────────────────────
current=$(( input_tokens + cache_create + cache_read ))
used_tokens=$(format_tokens "$current")

# Shorten model: "Opus 4.6 (1M context)" -> "O4.6 1M", "Fable 5.2" -> "F5.2"
model_short=$(printf '%s' "$model_name" | sed -E \
    -e 's/Fable /F/' \
    -e 's/Mythos /M/' \
    -e 's/Opus /O/' \
    -e 's/Sonnet /S/' \
    -e 's/Haiku /H/' \
    -e 's/ *\(1M context\)/ 1M/' \
    -e 's/ *\(200K context\)//')

# Effort is the live value from the input JSON (.effort.level), which reflects
# session-only overrides like `/effort max`. Older Claude Code builds omit it,
# so the parse above falls back to the saved default in settings.json.

# ── Directory & git ────────────────────────────────────
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
[ -z "$project_dir" ] || [ "$project_dir" = "null" ] && project_dir="$cwd"

if [ "$project_dir" = "$HOME" ]; then
    project_name="~"
else
    project_name=$(basename "$project_dir")
fi

cwd_display=""
if [ "$cwd" != "$project_dir" ]; then
    case "$cwd" in
        "$project_dir"/*)
            cwd_display="${cwd#$project_dir/}"
            ;;
        "$HOME"/*)
            rel="${cwd#$HOME/}"
            abbreviated=""
            while [[ "$rel" == */* ]]; do
                segment="${rel%%/*}"
                abbreviated+="${segment:0:1}/"
                rel="${rel#*/}"
            done
            cwd_display="~/${abbreviated}${rel}"
            ;;
        *)
            cwd_display="$cwd"
            ;;
    esac
fi

# Single `git status --porcelain=v1 -b` captures branch + dirty together.
# `GIT_OPTIONAL_LOCKS=0` skips the stat-cache refresh that would take
# `.git/index.lock` — otherwise a killed statusline can leave a stale lock
# and break the user's next checkout/commit (git 2.15+).
git_branch=""
git_dirty=""
if git_out=$(GIT_OPTIONAL_LOCKS=0 git -C "$project_dir" status --porcelain=v1 -b 2>/dev/null); then
    first_line=${git_out%%$'\n'*}
    if [ "${first_line#\#\# }" != "$first_line" ]; then
        b=${first_line#\#\# }
        b=${b%%...*}
        b=${b%% *}
        [ "$b" = "HEAD" ] && b="(detached)"
        git_branch="$b"
    fi
    # Anything beyond the header line means the tree is dirty.
    [ "$git_out" != "$first_line" ] && git_dirty="*"
fi

# ── Turn counter ───────────────────────────────────────
# Transcript logs tool results as {"type":"user", ..., "tool_use_id":...},
# so a naive count of "type":"user" inflates real user turns by ~10x.
# Exclude any line carrying tool_use_id.
turn_count=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    turn_count=$(grep '"type":"user"' "$transcript_path" 2>/dev/null | grep -vc 'tool_use_id')
    [ -z "$turn_count" ] && turn_count=0
fi

# ── Autocompact thresholds ─────────────────────────────
# autocompact_threshold and blocking_threshold come from the parse above;
# the "compact soon" warning starts 20k before compaction.
warning_threshold=$(( autocompact_threshold - 20000 ))

# ── LINE 1: Model+Effort | Project (branch) +lines ───
line1=""

# Claude Code's effort ladder (as of 2.1.117): low < medium < high < xhigh < max.
# Visual progression: quarter → half → full circle → bullseye → lightning.
case "$effort" in
    max)    line1+="${blue}${model_short}${reset} ${red}⚡ ${effort}${reset}" ;;
    xhigh)  line1+="${blue}${model_short}${reset} ${red}◉ ${effort}${reset}" ;;
    high)   line1+="${blue}${model_short}${reset} ${magenta}● ${effort}${reset}" ;;
    medium) line1+="${blue}${model_short}${reset} ${white}◑ ${effort}${reset}" ;;
    low)    line1+="${blue}${model_short}${reset} ${dim}◔ ${effort}${reset}" ;;
    *)      line1+="${blue}${model_short}${reset} ${dim}◑ ${effort}${reset}" ;;
esac

[ "$fast_mode" = true ] && line1+=" ${orange}↯ fast${reset}"

# Permission-mode badge (only when not default)
case "$permission_mode" in
    plan)              line1+=" ${yellow}🛡 plan${reset}" ;;
    acceptEdits)       line1+=" ${green}✎ auto${reset}" ;;
    bypassPermissions) line1+=" ${red}⚡ bypass${reset}" ;;
esac

# Output-style badge (only when not default)
if [ -n "$output_style" ] && [ "$output_style" != "default" ]; then
    line1+=" ${magenta}◎ ${output_style}${reset}"
fi

# Vim mode badge
case "$vim_mode" in
    NORMAL) line1+=" ${cyan}[N]${reset}" ;;
    INSERT) line1+=" ${dim}[I]${reset}" ;;
esac

line1+="${sep}"

line1+="📂 ${cyan}${project_name}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
# The branch's pull request, coloured by its review state.
if [ -n "$pr_number" ]; then
    case "$pr_state" in
        approved)          line1+=" ${green}PR #${pr_number} ✓${reset}" ;;
        changes_requested) line1+=" ${red}PR #${pr_number} ✗${reset}" ;;
        merged)            line1+=" ${magenta}PR #${pr_number} merged${reset}" ;;
        draft|closed)      line1+=" ${dim}PR #${pr_number} ${pr_state}${reset}" ;;
        *)                 line1+=" ${white}PR #${pr_number}${reset}" ;;
    esac
fi
if [ "$lines_added" -gt 0 ] 2>/dev/null || [ "$lines_removed" -gt 0 ] 2>/dev/null; then
    line1+=" 📝${green}+${lines_added}${reset} ${red}-${lines_removed}${reset}"
fi

# Agent name
if [ -n "$agent_name" ]; then
    line1+="${sep}${magenta}@${agent_name}${reset}"
fi

# Worktree
if [ -n "$worktree_name" ]; then
    line1+="${sep}${cyan}⎇ ${worktree_name}${reset}"
fi

# Session name
if [ -n "$session_name" ]; then
    line1+="${sep}${dim}${session_name}${reset}"
fi

if [ -n "$cwd_display" ]; then
    line1+="${sep}${dim}→${reset} ${white}${cwd_display}${reset}"
fi

# Crossed the fixed 200k-token threshold. This is NOT a downgrade — the flag is
# independent of context-window size; on 1M models it just means long-context
# (2× pricing) territory. Yellow caution, not a red error.
if [ "$exceeds_200k" = "true" ]; then
    line1+=" ${yellow}⚠ 200k+${reset}"
fi

# ── LINE 2: Context, cost, cache ───────────────────────
# Context is measured against the point where it compacts (or blocks, with
# auto-compact off), so a custom compaction window shows as itself.
context_limit=$autocompact_threshold
[ "$autocompact_on" = true ] || context_limit=$blocking_threshold
ctx_pct=0
[ "$context_limit" -gt 0 ] && ctx_pct=$(( current * 100 / context_limit ))
[ "$ctx_pct" -gt 100 ] && ctx_pct=100
line2="${dim}ctx${reset} $(build_bar "$ctx_pct" 8) ${white}${used_tokens}/$(format_tokens "$context_limit")${reset}"

if [ "$current" -ge "$blocking_threshold" ] 2>/dev/null; then
    line2+=" ${dim}·${reset} ${red}⛔ blocked${reset}"
elif [ "$autocompact_on" = true ] && [ "$current" -ge "$autocompact_threshold" ] 2>/dev/null; then
    line2+=" ${dim}·${reset} ${red}compacting…${reset}"
else
    # Runway: turns left at this session's average growth per turn, from the
    # third turn, once it is under 100.
    turns_left=""
    if [ "${turn_count:-0}" -ge 3 ] 2>/dev/null && [ "$current" -gt 0 ]; then
        turns_left=$(( (context_limit - current) * turn_count / current ))
        [ "$turns_left" -ge 100 ] && turns_left=""
    fi
    if [ -n "$turns_left" ]; then
        runway="~${turns_left} turns"
        [ "$turns_left" -eq 1 ] && runway="~1 turn"
        [ "$turns_left" -eq 0 ] && runway="<1 turn"
        runway_color="$white"
        [ "$turns_left" -le 5 ] && runway_color="$yellow"
        [ "$turns_left" -le 2 ] && runway_color="$red"
        line2+=" ${dim}·${reset} ${runway_color}${runway}${reset}"
    elif [ "$autocompact_on" = true ] && [ "$current" -ge "$warning_threshold" ] 2>/dev/null; then
        line2+=" ${dim}·${reset} ${yellow}compact soon${reset}"
    fi
fi

# Cost, with its rate once the session is ten minutes old. The rate carries
# the colour: yellow from $10/h, red from $20/h.
read -r cost_fmt per_hour rate_level <<EOF
$(awk -v c="$session_cost" -v ms="$total_duration" 'BEGIN {
    if (c + 0 <= 0) exit
    h = (ms >= 600000) ? c / (ms / 3600000) : -1
    r = (h >= 10) ? sprintf("%.0f", h) : sprintf("%.1f", h); sub(/\.0$/, "", r)
    printf "%.2f %s %d\n", c, (h >= 0 ? r : "-"), (h >= 20 ? 2 : h >= 10 ? 1 : 0)
}')
EOF
if [ -n "$cost_fmt" ]; then
    line2+="${sep}${white}\$${cost_fmt}${reset}"
    if [ "$per_hour" != "-" ]; then
        rate_color="$white"
        [ "$rate_level" = 1 ] && rate_color="$yellow"
        [ "$rate_level" = 2 ] && rate_color="$red"
        line2+=" ${dim}·${reset} ${rate_color}\$${per_hour}/h${reset}"
    fi
fi

# Prompt cache: when the next message would have to rebuild it, as a clock
# time (a countdown would freeze between renders), and how many times it was
# rebuilt mid-session. Once cold, what the next message re-reads.
if [ "$cache_state" = warm ] && [ "$cache_expires" -gt 0 ]; then
    line2+="${sep}${dim}cache til${reset} ${white}$(format_reset_time "$cache_expires" "time")${reset}"
    if [ "$cache_misses" -gt 0 ]; then
        miss_noun=misses
        [ "$cache_misses" -eq 1 ] && miss_noun=miss
        line2+=" ${dim}·${reset} ${yellow}${cache_misses} ${miss_noun}${reset}"
    fi
elif [ "$cache_state" = cold ]; then
    line2+="${sep}${dim}cache cold${reset}"
    [ "$cache_cold_cost" -gt 0 ] && line2+=" ${dim}· $(format_tokens "$cache_cold_cost") to rebuild${reset}"
fi

# ── OAuth token resolution ──────────────────────────────
# env var → macOS keychain → ~/.claude/.credentials.json → Linux secret-tool.
# The credentials.json path covers Windows (Git Bash / WSL) since neither
# `security` nor `secret-tool` exist there.
get_oauth_token() {
    local token=""

    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    if command -v security >/dev/null 2>&1; then
        local blob
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(printf '%s' "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                printf '%s' "$token"
                return 0
            fi
        fi
    fi

    local creds_file="${HOME}/.claude/.credentials.json"
    if [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            printf '%s' "$token"
            return 0
        fi
    fi

    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(printf '%s' "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                printf '%s' "$token"
                return 0
            fi
        fi
    fi

    printf ''
}

# Where a weekly window is heading at its average rate so far: it lasts to
# the reset ("· resets fri 11pm") or runs out first ("· out tue 10am"). With
# a budget, the run-out adds the daily share that would last until the reset.
weekly_outlook() {
    local pct=$1 reset_epoch=$2 with_budget=$3
    local out_epoch=0 budget=-1
    if [ -n "$reset_epoch" ] && [ "$pct" -gt 0 ] 2>/dev/null; then
        read -r out_epoch budget <<EOF
$(awk -v p="$pct" -v r="$reset_epoch" -v now="$(date +%s)" 'BEGIN {
    rem = r - now
    d = 7 - rem / 86400; if (d < 0.1) d = 0.1
    d = sprintf("%.1f", d) + 0
    b = sprintf("%.0f", p / d) + 0
    out = 0
    if (p < 100 && rem > 0 && b * 7 >= 100) { out = int(now + (100 - p) * d * 86400 / p); if (out >= r) out = 0 }
    printf "%d %d\n", out, (rem >= 86400 ? int((100 - p) / (rem / 86400)) : -1)
}')
EOF
    fi
    if [ "${out_epoch:-0}" -gt 0 ] 2>/dev/null; then
        printf '%s' " ${dim}·${reset} ${red}out $(format_reset_time "$out_epoch" "hour")${reset}"
        [ "$with_budget" = true ] && [ "${budget:-0}" -ge 1 ] 2>/dev/null && printf '%s' " ${dim}· budget${reset} ${white}${budget}%/day${reset}"
    elif [ -n "$reset_epoch" ]; then
        local reset_fmt
        reset_fmt=$(format_reset_time "$reset_epoch" "datetime")
        [ -n "$reset_fmt" ] && printf '%s' " ${dim}· resets${reset} ${white}${reset_fmt}${reset}"
    fi
}

# "↺ N resets" once a row is at 80%: the limit resets the plan still holds
# for that row.
resets_hint() {
    local pct=$1 count=$2
    [ "$pct" -ge 80 ] 2>/dev/null && [ "$count" -gt 0 ] 2>/dev/null || return
    local noun=reset
    [ "$count" -gt 1 ] && noun=resets
    printf '%s' " ${dim}·${reset} ${cyan}↺ ${count} ${noun}${reset}"
}

# ── Rate-line rendering (shared between input-JSON and API paths) ──
render_rate_lines() {
    local f_pct=$1 f_reset=$2 s_pct=$3 s_reset=$4 show_current=$5
    local out=""

    # 5-hour row, unless the plan has no session limit.
    if [ "$show_current" != false ]; then
        local f_reset_fmt f_epoch
        f_reset_fmt=$(format_reset_time "$f_reset" "time")
        out+="${white}current${reset} $(build_bar "$f_pct" 8) $(color_for_pct "$f_pct")$(printf '%3d' "$f_pct")%${reset}"
        # The 5h window has no reset time until the first message opens it.
        [ -n "$f_reset_fmt" ] && out+=" ${dim}· resets${reset} ${white}${f_reset_fmt}${reset}"
        # Burning fast: ≥90% used with more than 28% of the window still to go.
        f_epoch=$(to_epoch "$f_reset" 2>/dev/null)
        if [ -n "$f_epoch" ] && [ "$f_pct" -ge 90 ] 2>/dev/null && [ $(( f_epoch - $(date +%s) )) -gt 5040 ]; then
            out+=" ${dim}·${reset} ${red}burning fast${reset}"
        fi
        out+="\n"
    fi

    out+="${white}weekly${reset}  $(build_bar "$s_pct" 8) $(color_for_pct "$s_pct")$(printf '%3d' "$s_pct")%${reset}"
    out+=$(weekly_outlook "$s_pct" "$(to_epoch "$s_reset" 2>/dev/null)" true)
    out+=$(resets_hint "$s_pct" "$resets_weekly")

    printf '%s' "$out"
}

# ── Spend-row rendering ──
# Pro/Max get one "extra" row for add-on credits. Spend-billed plans
# (Enterprise) have no session/weekly windows, so the credits are the whole
# budget: a spend row plus pace (month-end projection) and month (time gone,
# budget left per day) rows in the slots current/weekly would use.
# Percent comes from used/limit, since the API's utilization can be null.
# One awk pass also compacts money: $10K, $1.5K, $350, $12.41, €40.
render_spend_lines() {
    local used_minor=$1 limit_minor=$2 decimals=$3 sym=$4 has_windows=$5
    local month_start month_end reset_fmt badge=""
    local pct used_fmt limit_fmt left_fmt per_day_fmt projected_fmt proj_pct
    local month_pct day_n days_total days_left budget_fmt cap_epoch
    month_start=$(date -j -v1d -v0H -v0M -v0S +%s 2>/dev/null || date -d "$(date +%Y-%m-01)" +%s 2>/dev/null)
    month_end=$(date -j -v1d -v+1m -v0H -v0M -v0S +%s 2>/dev/null || date -d "$(date +%Y-%m-01) +1 month" +%s 2>/dev/null)
    reset_fmt=$(format_reset_time "$month_end" "date")

    IFS=$'\t' read -r pct used_fmt limit_fmt left_fmt per_day_fmt projected_fmt proj_pct \
        month_pct day_n days_total days_left budget_fmt cap_epoch <<EOF
$(awk -v u="$used_minor" -v l="$limit_minor" -v e="$decimals" -v sym="$sym" \
      -v now="$(date +%s)" -v s="${month_start:-0}" -v r="${month_end:-0}" '
function money(a,   x) {
    if (a >= 999950) { x = sprintf("%.1f", a / 1000000); sub(/\.0$/, "", x); return sym x "M" }
    if (a >= 999.5)  { x = sprintf("%.1f", a / 1000);    sub(/\.0$/, "", x); return sym x "K" }
    if (a >= 100)    return sym sprintf("%.0f", a)
    x = sprintf("%.2f", a); sub(/\.00$/, "", x); return sym x
}
function rate(a) { return a >= 10 ? int(a + 0.5) : a }
BEGIN {
    u /= 10 ^ e; l /= 10 ^ e
    left = l > u ? l - u : 0
    # Rounded like the claude.ai usage page, but held at 99% while money is
    # left so the cap badge never fires early.
    pct = l > 0 ? int(u * 100 / l + 0.5) : 0
    if (pct >= 100 && u < l) pct = 99

    # Pace: average daily spend so far, projected to the reset. The first
    # half-day counts as half a day so one early session cannot spike it.
    total = (r - s) / 86400; if (total <= 0) total = 1
    el = (now - s) / 86400; if (el < 0.5) el = 0.5
    days_left = (r - now) / 86400; if (days_left < 0) days_left = 0
    pd = u / el; proj = pd * total
    cap = (pd > 0 && left > 0) ? int(now + left / pd * 86400) : 0
    if (cap >= r) cap = 0

    printf "%d\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\n",
        pct, money(u), money(l), money(left), money(rate(pd)), money(proj),
        (l > 0 ? int(proj * 100 / l + 0.5) : 0), int(el * 100 / total + 0.5),
        int(el) + 1, int(total + 0.5), int(days_left + 0.5),
        money(rate(days_left > 0 ? left / days_left : 0)), cap
}')
EOF
    [ -n "$pct" ] || return

    # 50% / 80% / cap badges.
    if [ "$pct" -ge 100 ]; then badge="  ⛔ ${red}CAP HIT${reset} ${dim}til${reset} ${white}${reset_fmt}${reset}"
    elif [ "$pct" -ge 80 ]; then badge="  🚨 ${red}80%+${reset} ${white}${left_fmt}${reset} ${dim}left${reset}"
    elif [ "$pct" -ge 50 ]; then badge="  ⚠ ${yellow}50%+${reset} ${white}${left_fmt}${reset} ${dim}left${reset}"
    fi
    local meter="$(build_bar "$pct" 8) $(color_for_pct "$pct")$(printf '%3d' "$pct")%${reset} ${white}${used_fmt}${dim}/${reset}${white}${limit_fmt}${reset} ${dim}resets${reset} ${white}${reset_fmt}${reset}${badge}"

    if [ "$has_windows" != false ]; then
        printf '%s' "${white}extra${reset}   ${meter}"
        return
    fi

    # Spend share vs month share, with a ±5-point dead zone.
    local pace_mark=""
    if [ "$pct" -lt 100 ]; then
        if [ "$pct" -gt $(( month_pct + 5 )) ]; then pace_mark="  ${dim}▲ over pace${reset}"
        elif [ "$pct" -lt $(( month_pct - 5 )) ]; then pace_mark="  ${dim}▼ under pace${reset}"
        fi
    fi

    local verdict=""
    if [ "$pct" -ge 100 ]; then verdict=""
    elif [ "$cap_epoch" -gt 0 ]; then verdict="  ⚡ ${red}cap by $(format_reset_time "$cap_epoch" "date")${reset}"
    elif [ "$proj_pct" -ge 80 ]; then verdict="  ${yellow}⚠ tight${reset}"
    else verdict="  ${green}✓ on track${reset}"
    fi

    local budget="${white}${budget_fmt}/day${reset} ${dim}left for ${days_left}d${reset}"
    [ "$pct" -ge 100 ] && budget="${dim}no budget left · resets in ${days_left}d${reset}"

    printf '%s' "${white}spend${reset}   ${meter}${pace_mark}"
    printf '%s' "\n${white}pace${reset}    $(build_bar "$proj_pct" 8) $(color_for_pct "$proj_pct")$(printf '%3d' "$proj_pct")%${reset} ${white}~${per_day_fmt}/day${reset} ${dim}→${reset} ${white}${projected_fmt}${reset}${verdict}"
    # Time is not good or bad, so the month bar stays dim.
    printf '%s' "\n${white}month${reset}   $(build_bar "$month_pct" 8 "$dim") ${dim}$(printf '%3d' "$month_pct")%${reset} ${white}day ${day_n}/${days_total}${reset} ${dim}·${reset} ${budget}"
}

# ── Usage API: render from the cache, refresh it in the background ──
# The per-model and extra rows only come from the API. A render never waits
# on the network: it draws the shared cache and, when that is due, starts one
# detached fetch whose result the next render picks up.
uid=$(id -u 2>/dev/null || echo 0)
cache_dir="${TMPDIR:-/tmp}/claude-${uid}"
mkdir -p "$cache_dir" 2>/dev/null
chmod 700 "$cache_dir" 2>/dev/null
cache_file="${cache_dir}/statusline-usage-cache.json"
backoff_file="${cache_dir}/statusline-usage-backoff"
refresh_age=300     # refetch once the cache is older than this
window_max_age=900  # oldest cache trusted for the current/weekly windows
stale_max_age=7200  # oldest cache still shown at all (outlasts a 429 penalty)

usage_data=""
now=$(date +%s)
cache_age=""

if [ -f "$cache_file" ]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
    [ -n "$cache_mtime" ] && cache_age=$(( now - cache_mtime ))
    # Older than stale_max_age is more likely wrong (e.g. from before an
    # account switch) than useful.
    if [ -n "$cache_age" ] && [ "$cache_age" -le "$stale_max_age" ] 2>/dev/null; then
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
fi

# The marker holds the epoch of the next allowed request. Unreadable or
# implausible values are ignored.
next_attempt=0
[ -f "$backoff_file" ] && read -r next_attempt < "$backoff_file"
case "$next_attempt" in ''|*[!0-9]*) next_attempt=0 ;; esac
[ "$next_attempt" -gt $(( now + 86400 )) ] && next_attempt=0

# Fetches the usage API into the cache from its own process group, so the
# kill that ends a superseded render cannot drop a response already paid for.
# The body is written whole and renamed into place; a failure pushes the
# marker out by the server's Retry-After plus a margin, since asking again
# inside the penalty makes the server lengthen it (429/403 default 5 min,
# else 1 min, a day at most).
refresh_usage_cache() {
    (
        set -m
        (
            umask 077
            token=$(get_oauth_token)
            if [ -z "$token" ] || [ "$token" = "null" ]; then
                printf '%s\n' "$(( now + 300 ))" > "$backoff_file"
                exit 0
            fi
            # $1 is the query that asks for the plan's limit resets. An answer
            # to it that is not a success, a rate limit or an auth failure is
            # tried once more without it. The token goes in on stdin so it
            # never shows up in `ps`.
            usage_query=$1
            while :; do
                response=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -s --max-time 5 -K - \
                    -D "${cache_file}.hdr" -w '\n%{http_code}' \
                    -H "Accept: application/json" \
                    -H "anthropic-beta: oauth-2025-04-20" \
                    -H "User-Agent: ccline-statusline" \
                    "https://api.anthropic.com/api/oauth/usage${usage_query}" 2>/dev/null)
                http_code=${response##*$'\n'}
                response=${response%$'\n'*}
                case "$http_code" in 200|401|403|429) break ;; esac
                [ -z "$usage_query" ] && break
                usage_query=""
            done
            # Judge by status, not by .five_hour: spend-billed plans (Enterprise)
            # answer 200 with null five_hour/seven_day windows.
            if [ "$http_code" = "200" ] && [ "${response:0:1}" = "{" ]; then
                printf '%s' "$response" > "${cache_file}.tmp" && mv -f "${cache_file}.tmp" "$cache_file"
                rm -f "$backoff_file"
            else
                case "$http_code" in 429|403) backoff=300 ;; *) backoff=60 ;; esac
                retry_after=$(awk 'tolower($1) == "retry-after:" { print int($2); exit }' "${cache_file}.hdr" 2>/dev/null)
                [ "${retry_after:-0}" -gt "$backoff" ] 2>/dev/null && backoff=$(( retry_after + 30 ))
                [ "$backoff" -gt 86400 ] && backoff=86400
                printf '%s\n' "$(( $(date +%s) + backoff ))" > "$backoff_file"
            fi
            rm -f "${cache_file}.hdr"
        ) >/dev/null 2>&1 </dev/null &
    ) 2>/dev/null
}

# Single jq parse of the usage response, like the input-JSON eval above.
# Empty output means the cached/fetched body isn't usable JSON.
# Rows are the server's limits[]; a body without it (an older server) falls
# back to the top-level per-model windows. "session" and "weekly_all" are the
# current/weekly windows, everything else is a scoped row of its own. A plan
# without windows (spend-billed) keeps only the model-scoped weekly rows.
has_windows=false
session_limit=true
scoped_rows=""
extra_enabled=false
resets_weekly=0
resets_scoped=0
usage_vars=""
parse_usage() {
    usage_vars=$(printf '%s' "$usage_data" | jq -r '
  def clean: tostring | gsub("[\t\n\r\u001f\\\\]"; " ");
  def clears($key): any((.clears | arrays)[]?; . == $key);
  (if (.limits | type) == "array" then [.limits | to_entries[] | select(.value | type == "object") | .value + {idx: .key}]
   else [(.seven_day_opus // empty | {kind: "weekly_scoped", group: "weekly", percent: .utilization, resets_at, scope: {model: {display_name: "Opus"}}}),
         (.seven_day_sonnet // empty | {kind: "weekly_scoped", group: "weekly", percent: .utilization, resets_at, scope: {model: {display_name: "Sonnet"}}})]
   end) as $rows
  | ([$rows[] | select(.kind == "session")][0]) as $session
  | ([$rows[] | select(.kind == "weekly_all")][0]) as $weekly
  | (.five_hour != null or .seven_day != null or $session != null or $weekly != null) as $windows
  | ((.weekly_scoped_shares | arrays) // []) as $shares
  | ([.cedar_ember | objects | select(.eligible == true) | .grants | arrays | .[] | objects
      | select(((.resets_left | numbers) // 0) > 0 and .paused != true and .usable_now != false)]) as $grants
  | ((.extra_usage | objects) // {}) as $extra
  | "has_windows=" + ($windows | @sh),
  "session_limit=" + ((.five_hour != null or $session != null or (.limits | type) != "array") | @sh),
  "f_pct=" + (.five_hour.utilization // $session.percent // 0 | . + 0.5 | floor | @sh),
  "f_reset_iso=" + (.five_hour.resets_at // $session.resets_at // "" | @sh),
  "s_pct=" + (.seven_day.utilization // $weekly.percent // 0 | . + 0.5 | floor | @sh),
  "s_reset_iso=" + (.seven_day.resets_at // $weekly.resets_at // "" | @sh),
  "extra_enabled=" + ($extra.is_enabled // false | @sh),
  "extra_currency=" + ($extra.currency // "USD" | @sh),
  "extra_decimals=" + ($extra.decimal_places // 2 | @sh),
  "extra_used_minor=" + ($extra.used_credits // 0 | @sh),
  "extra_limit_minor=" + ($extra.monthly_limit // 0 | @sh),
  "resets_weekly=" + ([$grants[] | select(clears("seven_day")) | .resets_left] | add // 0 | floor | @sh),
  "resets_scoped=" + (if ([$rows[] | select(.kind == "weekly_scoped" and .scope.model != null)] | length) != 1 then 0
      else [$grants[] | select(clears("seven_day_overage_included") and (clears("seven_day") | not)) | .resets_left] | add // 0 | floor end | @sh),
  "scoped_rows=" + ([$rows[]
      | select(.kind != "session" and .kind != "weekly_all")
      | select($windows or (.kind == "weekly_scoped" and (.scope.model.display_name // "") != ""))
      | . as $row
      | (.scope.model.display_name // .scope.surface.display_name
          // (.kind // "" | tostring | sub("^weekly_"; "") | gsub("_"; " ")) | clean) as $label
      | select($label != "")
      | ([$shares[] | objects | select(.limit_index == $row.idx)][0]) as $share
      | [(.percent | numbers) // 0, $label, (.resets_at | strings) // "", (.severity | strings) // "",
         (.group | strings) // "", ($share.allowance_percent_of_weekly | numbers | floor) // "",
         (if .scope.model != null then 1 else 0 end), ($share.used_percent_of_weekly | numbers | floor) // ""]
      | map(tostring) | join("\u001f")] | join("\n") | @sh)
' 2>/dev/null)
    [ -n "$usage_vars" ] && eval "$usage_vars"
}
[ -n "$usage_data" ] && parse_usage

# Claiming the next minute before the request goes out keeps every other
# session, and this one's next renders, from sending the same request. Only a
# plan already known to have windows is asked for its limit resets, so a
# spend-billed plan and every cold start send the plain request.
if { [ -z "$cache_age" ] || [ "$cache_age" -ge "$refresh_age" ]; } && [ "$now" -ge "$next_attempt" ]; then
    ( umask 077; printf '%s\n' "$(( now + 60 ))" > "$backoff_file" ) 2>/dev/null
    usage_query=""
    [ "$has_windows" = true ] && usage_query="?cedar_ember=1"
    refresh_usage_cache "$usage_query"
    # With nothing to show (a cold start), give that fetch two seconds so
    # plans whose only rows come from the API have them on the first render.
    # The job removes the marker once the new body is in place; a marker
    # that no longer holds the claim means the fetch failed.
    if [ -z "$usage_data" ]; then
        for (( i = 0; i < 20; i++ )); do
            sleep 0.1
            if [ ! -f "$backoff_file" ]; then
                usage_data=$(cat "$cache_file" 2>/dev/null)
                cache_age=0
                [ -n "$usage_data" ] && parse_usage
                break
            fi
            claim=""
            read -r claim 2>/dev/null < "$backoff_file"
            [ "$claim" = "$(( now + 60 ))" ] || break
        done
    fi
fi

# ── Rate limits: prefer input JSON (freshest), fall back to the cache ──
# Presence, not value: a fresh 0% from Claude Code is still authoritative.
# Spend-billed plans have no session/weekly windows, so there is nothing to
# draw for them here.
rate_lines=""
api_rows=false
# The current row is dropped when the server's rows show the plan has no
# session limit and Claude Code sent no 5-hour window either.
if [ "$has_input_limits" = true ]; then
    show_current=true
    [ "$has_input_five_hour" = false ] && [ "$session_limit" = false ] && show_current=false
    rate_lines=$(render_rate_lines "$five_hour_pct" "$five_hour_reset" "$seven_day_pct" "$seven_day_reset" "$show_current")
elif [ "$has_windows" = true ] && [ "$cache_age" -le "$window_max_age" ]; then
    rate_lines=$(render_rate_lines "$f_pct" "$f_reset_iso" "$s_pct" "$s_reset_iso" "$session_limit")
    api_rows=true
fi

if [ -n "$usage_vars" ]; then
    # One row per scoped limit (e.g. Fable's weekly cap on Max plans), labelled
    # by the model or surface the server names, in the server's order. The
    # server's severity can raise the colour but never lowers it.
    if [ -n "$scoped_rows" ]; then
        while IFS=$'\x1f' read -r m_pct m_name m_reset m_sev m_group m_share m_model m_share_used; do
            [ -z "$m_name" ] && continue
            # A cached percent is wrong once its window has reset.
            m_epoch=$(to_epoch "$m_reset" 2>/dev/null)
            [ -n "$m_epoch" ] && [ "$m_epoch" -le "$now" ] && continue
            m_pct=$(printf '%.0f' "$m_pct" 2>/dev/null || echo 0)
            m_label=$(printf '%s' "$m_name" | tr '[:upper:]' '[:lower:]')
            # Pad the label to 8 cols so its bar lines up with current/weekly/extra.
            m_pad=$(( 8 - ${#m_label} ))
            [ "$m_pad" -lt 1 ] && m_pad=1
            m_spaces=$(printf '%*s' "$m_pad" '')
            m_color=$(color_for_pct "$m_pct")
            case "$m_sev" in
                critical) m_color="$red" ;;
                warning)  [ "$m_pct" -lt 90 ] && m_color="$yellow" ;;
            esac
            m_bar=$(build_bar "$m_pct" 8 "$m_color")
            m_pct_fmt=$(printf "%3d" "$m_pct")
            rate_lines+="\n${white}${m_label}${reset}${m_spaces}${m_bar} ${m_color}${m_pct_fmt}%${reset}"
            if [ "$m_group" = weekly ]; then
                rate_lines+=$(weekly_outlook "$m_pct" "$m_epoch" false)
            else
                m_reset_fmt=$(format_reset_time "$m_reset" "datetime")
                [ -n "$m_reset_fmt" ] && rate_lines+=" ${dim}· resets${reset} ${white}${m_reset_fmt}${reset}"
            fi
            # Limit resets that clear only the per-model cap belong to the model
            # row; the count is zero unless exactly one such row exists.
            [ "$m_model" = 1 ] && rate_lines+=$(resets_hint "$m_pct" "$resets_scoped")
            # The row's own percent is of its allowance; this is the same usage
            # as a share of the whole week, against the cap on that share.
            if [ -n "$m_share" ] && [ -n "$m_share_used" ]; then
                rate_lines+=" ${dim}· ${m_share_used}/${m_share}% of weekly${reset}"
            elif [ -n "$m_share" ]; then
                rate_lines+=" ${dim}· up to ${m_share}% of weekly${reset}"
            fi
            api_rows=true
        done <<EOF
$scoped_rows
EOF
    fi

    # Extra-usage credits (only surfaced via API). Currency and minor-unit
    # scale are API-driven (e.g. EUR, 2 decimals).
    spend_rows=""
    if [ "$extra_enabled" = "true" ]; then
        spend_rows=$(render_spend_lines "$extra_used_minor" "$extra_limit_minor" "$extra_decimals" "$(currency_symbol "$extra_currency")" "$has_windows")
    fi
    [ -n "$spend_rows" ] && rate_lines+="\n${spend_rows}" && api_rows=true

    # While the API is failing the rows above age; say so on the last one.
    if $api_rows && [ "$cache_age" -ge "$window_max_age" ]; then
        rate_lines+=" ${dim}· $(( cache_age / 60 ))m old${reset}"
    fi
fi

# ── Output ──────────────────────────────────────────────
printf "%b\n" "$line1"
printf "%b\n" "$line2"
# Rows append with a leading "\n"; drop it when no window rows came first.
rate_lines=${rate_lines#\\n}
[ -n "$rate_lines" ] && printf "%b" "$rate_lines"

exit 0
