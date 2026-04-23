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

build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

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

    local result=""
    case "$style" in
        time)
            result=$(date -d "@$epoch" +"%l:%M%P" 2>/dev/null | sed 's/^ //; s/\.//g')
            [ -z "$result" ] && result=$(date -j -r "$epoch" +"%l:%M%p" 2>/dev/null | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        datetime)
            result=$(date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g')
            [ -z "$result" ] && result=$(date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            ;;
        *)
            result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
            [ -z "$result" ] && result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            ;;
    esac
    printf '%s' "$result"
}

# Portable file-birth-time lookup.
# macOS (BSD stat) has true birthtime via `-f %B`.
# GNU coreutils 8.31+ expose birthtime via `-c %W`; returns "-" or 0 if the FS
# doesn't track it (ext4 on older kernels, tmpfs). Fall back to mtime in that
# case — session duration becomes approximate but never disappears.
file_birth_epoch() {
    local path="$1"
    local epoch

    epoch=$(stat -f %B "$path" 2>/dev/null)
    if [ -n "$epoch" ] && [ "$epoch" -gt 0 ] 2>/dev/null; then
        printf '%s' "$epoch"; return 0
    fi

    epoch=$(stat -c %W "$path" 2>/dev/null)
    if [ -n "$epoch" ] && [ "$epoch" != "-" ] && [ "$epoch" -gt 0 ] 2>/dev/null; then
        printf '%s' "$epoch"; return 0
    fi

    epoch=$(stat -c %Y "$path" 2>/dev/null)
    if [ -n "$epoch" ] && [ "$epoch" -gt 0 ] 2>/dev/null; then
        printf '%s' "$epoch"; return 0
    fi

    epoch=$(stat -f %m "$path" 2>/dev/null)
    if [ -n "$epoch" ] && [ "$epoch" -gt 0 ] 2>/dev/null; then
        printf '%s' "$epoch"; return 0
    fi

    return 1
}

# ── Single jq parse ────────────────────────────────────
eval "$(printf '%s' "$input" | jq -r '
  "model_name=" + (.model.display_name // "Claude" | @sh),
  "cwd=" + (.workspace.current_dir // "" | @sh),
  "project_dir=" + (.workspace.project_dir // "" | @sh),
  "ctx_size=" + (.context_window.context_window_size // 200000 | tostring),
  "pct_used=" + (.context_window.used_percentage // 0 | floor | tostring),
  "input_tokens=" + (.context_window.current_usage.input_tokens // 0 | tostring),
  "cache_create=" + (.context_window.current_usage.cache_creation_input_tokens // 0 | tostring),
  "cache_read=" + (.context_window.current_usage.cache_read_input_tokens // 0 | tostring),
  "total_input=" + (.context_window.total_input_tokens // 0 | tostring),
  "total_output=" + (.context_window.total_output_tokens // 0 | tostring),
  "session_cost=" + (.cost.total_cost_usd // 0 | tostring),
  "lines_added=" + (.cost.total_lines_added // 0 | tostring),
  "lines_removed=" + (.cost.total_lines_removed // 0 | tostring),
  "api_duration=" + (.cost.total_api_duration_ms // 0 | tostring),
  "total_duration=" + (.cost.total_duration_ms // 0 | tostring),
  "five_hour_pct=" + (.rate_limits.five_hour.used_percentage // 0 | floor | tostring),
  "five_hour_reset=" + (.rate_limits.five_hour.resets_at // "" | tostring),
  "seven_day_pct=" + (.rate_limits.seven_day.used_percentage // 0 | floor | tostring),
  "seven_day_reset=" + (.rate_limits.seven_day.resets_at // "" | tostring),
  "exceeds_200k=" + (.exceeds_200k_tokens // false | tostring),
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
total_tokens=$(format_tokens "$ctx_size")

session_cost_fmt=$(awk "BEGIN {printf \"%.2f\", $session_cost}")

# Shorten model: "Opus 4.6 (1M context)" -> "O4.6 1M"
model_short=$(printf '%s' "$model_name" | sed -E \
    -e 's/Opus /O/' \
    -e 's/Sonnet /S/' \
    -e 's/Haiku /H/' \
    -e 's/ *\(1M context\)/ 1M/' \
    -e 's/ *\(200K context\)//')

# Effort level (from settings.json)
effort="default"
settings_path="$HOME/.claude/settings.json"
if [ -f "$settings_path" ]; then
    effort=$(jq -r '.effortLevel // "default"' "$settings_path" 2>/dev/null)
fi

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

# ── Session duration ───────────────────────────────────
session_duration=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    start_epoch=$(file_birth_epoch "$transcript_path")
    if [ -n "$start_epoch" ] && [ "$start_epoch" -gt 0 ] 2>/dev/null; then
        now_epoch=$(date +%s)
        elapsed=$(( now_epoch - start_epoch ))
        if [ "$elapsed" -ge 3600 ]; then
            session_duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
        elif [ "$elapsed" -ge 60 ]; then
            session_duration="$(( elapsed / 60 ))m"
        else
            session_duration="${elapsed}s"
        fi
    fi
fi

# ── Peak detection (05:00-11:00 PT) ───────────────────
is_peak=false
peak_end_local=""
pt_hour=$(TZ="America/Los_Angeles" date +%-H 2>/dev/null)
if [ -n "$pt_hour" ] && [ "$pt_hour" -ge 5 ] && [ "$pt_hour" -lt 11 ] 2>/dev/null; then
    is_peak=true
    today_pt=$(TZ="America/Los_Angeles" date +%Y-%m-%d)
    peak_end_epoch=$(TZ="America/Los_Angeles" date -j -f "%Y-%m-%d %H:%M:%S" "${today_pt} 11:00:00" +%s 2>/dev/null)
    [ -z "$peak_end_epoch" ] && peak_end_epoch=$(TZ="America/Los_Angeles" date -d "${today_pt} 11:00:00" +%s 2>/dev/null)
    if [ -n "$peak_end_epoch" ]; then
        peak_end_local=$(date -d "@$peak_end_epoch" +"%l%P" 2>/dev/null | sed 's/^ //; s/\.//g')
        [ -z "$peak_end_local" ] && peak_end_local=$(date -j -r "$peak_end_epoch" +"%l%p" 2>/dev/null | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
    fi
fi

# ── Autocompact thresholds (match Claude Code source) ──
# src/services/compact/autoCompact.ts: AUTOCOMPACT_BUFFER_TOKENS=13k,
# WARNING_THRESHOLD_BUFFER_TOKENS=20k, MANUAL_COMPACT_BUFFER_TOKENS=3k.
autocompact_threshold=$(( ctx_size - 13000 ))
warning_threshold=$(( autocompact_threshold - 20000 ))
blocking_threshold=$(( ctx_size - 3000 ))

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

# 200k+ downgrade warning
if [ "$exceeds_200k" = "true" ]; then
    line1+=" ${red}⚠ downgraded${reset}"
fi

# ── LINE 2: Session stats ─────────────────────────────
line2=""

if [ -n "$turn_count" ] && [ "$turn_count" -gt 0 ] 2>/dev/null; then
    turn_color="$white"
    [ "$turn_count" -ge 30 ] 2>/dev/null && turn_color="$yellow"
    [ "$turn_count" -ge 50 ] 2>/dev/null && turn_color="$red"
    line2+="${turn_color}#${turn_count}${reset} ${dim}turns${reset}"
fi

if [ -n "$session_duration" ]; then
    [ -n "$line2" ] && line2+="${sep}"
    line2+="⏱ ${white}${session_duration}${reset}"
fi

# Context usage + compact warnings
pct_color=$(color_for_pct "$pct_used")
[ -n "$line2" ] && line2+="${sep}"
line2+="${pct_color}${pct_used}%${reset} ${white}${used_tokens}/${total_tokens}${reset} ${dim}ctx${reset}"

if [ "$current" -ge "$blocking_threshold" ] 2>/dev/null; then
    line2+=" ${red}⛔ blocked${reset}"
elif [ "$current" -ge "$autocompact_threshold" ] 2>/dev/null; then
    line2+=" ${red}compacting…${reset}"
elif [ "$current" -ge "$warning_threshold" ] 2>/dev/null; then
    line2+=" ${yellow}compact soon${reset}"
fi

# Cost
if [ "$(awk "BEGIN {print ($session_cost > 0)}")" = "1" ]; then
    line2+="${sep}"
    cost_color="$white"
    [ "$(awk "BEGIN {print ($session_cost >= 5)}")" = "1" ] && cost_color="$yellow"
    [ "$(awk "BEGIN {print ($session_cost >= 10)}")" = "1" ] && cost_color="$red"
    line2+="${cost_color}\$${session_cost_fmt}${reset}"
fi

# API latency %
if [ "$total_duration" -gt 0 ] 2>/dev/null && [ "$api_duration" -gt 0 ] 2>/dev/null; then
    api_pct=$(( api_duration * 100 / total_duration ))
    line2+="${sep}${dim}api ${api_pct}%${reset}"
fi

# ── OAuth token resolution ──────────────────────────────
# macOS keychain → ~/.claude/.credentials.json → Linux secret-tool → env var.
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

# ── Rate-line rendering (shared between input-JSON and API paths) ──
render_rate_lines() {
    local f_pct=$1 f_reset=$2 s_pct=$3 s_reset=$4
    local bar_width=8
    local out=""

    # 5-hour row
    local f_reset_fmt f_bar f_color f_pct_fmt
    f_reset_fmt=$(format_reset_time "$f_reset" "time")
    f_bar=$(build_bar "$f_pct" "$bar_width")
    f_color=$(color_for_pct "$f_pct")
    f_pct_fmt=$(printf "%3d" "$f_pct")
    out+="${white}current${reset} ${f_bar} ${f_color}${f_pct_fmt}%${reset} ${dim}resets${reset} ${white}${f_reset_fmt}${reset}"

    if $is_peak; then
        out+="  🔥 ${red}PEAK${reset}"
        [ -n "$peak_end_local" ] && out+=" ${dim}til${reset} ${white}${peak_end_local}${reset}"
    fi

    # 5-hour burn-fast: ≥90% used and ≥72% into the window
    local f_epoch now_epoch
    f_epoch=$(to_epoch "$f_reset" 2>/dev/null)
    if [ -n "$f_epoch" ] && [ "$f_pct" -ge 90 ] 2>/dev/null; then
        now_epoch=$(date +%s)
        local remaining=$(( f_epoch - now_epoch ))
        local time_pct
        time_pct=$(awk "BEGIN {printf \"%.2f\", 1 - ($remaining / 18000)}")
        if awk "BEGIN {exit !($time_pct <= 0.72)}"; then
            out+="  ${red}⚡ burning fast${reset}"
        fi
    fi

    # 7-day row
    local s_reset_fmt s_bar s_color s_pct_fmt
    s_reset_fmt=$(format_reset_time "$s_reset" "datetime")
    s_bar=$(build_bar "$s_pct" "$bar_width")
    s_color=$(color_for_pct "$s_pct")
    s_pct_fmt=$(printf "%3d" "$s_pct")

    # Burn rate + weekly burn-fast
    local burn_rate="" s_epoch
    s_epoch=$(to_epoch "$s_reset" 2>/dev/null)
    if [ -n "$s_epoch" ] && [ "$s_pct" -gt 0 ] 2>/dev/null; then
        now_epoch=$(date +%s)
        local secs_remaining=$(( s_epoch - now_epoch ))
        local days_elapsed burn_per_day projected
        days_elapsed=$(awk "BEGIN {d = 7 - ($secs_remaining / 86400); if (d < 0.1) d = 0.1; printf \"%.1f\", d}")
        burn_per_day=$(awk "BEGIN {printf \"%.0f\", $s_pct / $days_elapsed}")
        projected=$(awk "BEGIN {printf \"%.0f\", $burn_per_day * 7}")

        local burn_color="$green"
        [ "$projected" -ge 80 ] 2>/dev/null && burn_color="$yellow"
        [ "$projected" -ge 100 ] 2>/dev/null && burn_color="$red"
        burn_rate="${burn_color}~${burn_per_day}%/day${reset}"

        if [ "$secs_remaining" -gt 0 ] 2>/dev/null; then
            local time_pct
            time_pct=$(awk "BEGIN {printf \"%.2f\", 1 - ($secs_remaining / 604800)}")
            local burning_fast=false
            if [ "$s_pct" -ge 75 ] && awk "BEGIN {exit !($time_pct <= 0.60)}"; then burning_fast=true; fi
            if [ "$s_pct" -ge 50 ] && awk "BEGIN {exit !($time_pct <= 0.35)}"; then burning_fast=true; fi
            if [ "$s_pct" -ge 25 ] && awk "BEGIN {exit !($time_pct <= 0.15)}"; then burning_fast=true; fi
            $burning_fast && burn_rate+=" ${red}⚡${reset}"
        fi
    fi

    out+="\n${white}weekly${reset}  ${s_bar} ${s_color}${s_pct_fmt}%${reset} ${dim}resets${reset} ${white}${s_reset_fmt}${reset}"
    [ -n "$burn_rate" ] && out+="  ${burn_rate}"

    printf '%s' "$out"
}

# ── Rate limits: prefer input JSON (freshest), fall back to OAuth API ──
rate_lines=""
if [ "$five_hour_pct" -gt 0 ] 2>/dev/null || [ "$seven_day_pct" -gt 0 ] 2>/dev/null; then
    rate_lines=$(render_rate_lines "$five_hour_pct" "$five_hour_reset" "$seven_day_pct" "$seven_day_reset")
fi

# ── Cache + optional API fetch (extra_usage only comes from API) ──
uid=$(id -u 2>/dev/null || echo 0)
cache_dir="${TMPDIR:-/tmp}/claude-${uid}"
mkdir -p "$cache_dir" 2>/dev/null
chmod 700 "$cache_dir" 2>/dev/null
cache_file="${cache_dir}/statusline-usage-cache.json"
cache_max_age=60

needs_refresh=true
usage_data=""

if [ -f "$cache_file" ]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
    now=$(date +%s)
    if [ -n "$cache_mtime" ] && [ "$(( now - cache_mtime ))" -lt "$cache_max_age" ] 2>/dev/null; then
        needs_refresh=false
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
fi

if $needs_refresh; then
    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        response=$(curl -s --max-time 3 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: ccline-statusline" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if [ -n "$response" ] && printf '%s' "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
            usage_data="$response"
            ( umask 077; printf '%s' "$response" > "$cache_file" )
        fi
    fi
    if [ -z "$usage_data" ] && [ -f "$cache_file" ]; then
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
fi

if [ -n "$usage_data" ] && printf '%s' "$usage_data" | jq -e . >/dev/null 2>&1; then
    # API-sourced rate lines if input JSON had none
    if [ -z "$rate_lines" ]; then
        f_pct=$(printf '%s' "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
        f_reset_iso=$(printf '%s' "$usage_data" | jq -r '.five_hour.resets_at // empty')
        s_pct=$(printf '%s' "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
        s_reset_iso=$(printf '%s' "$usage_data" | jq -r '.seven_day.resets_at // empty')
        rate_lines=$(render_rate_lines "$f_pct" "$f_reset_iso" "$s_pct" "$s_reset_iso")
    fi

    # Extra-usage line (only surfaced via API)
    extra_enabled=$(printf '%s' "$usage_data" | jq -r '.extra_usage.is_enabled // false')
    if [ "$extra_enabled" = "true" ]; then
        extra_pct=$(printf '%s' "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
        extra_used=$(printf '%s' "$usage_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
        extra_limit=$(printf '%s' "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')
        extra_bar=$(build_bar "$extra_pct" 8)
        extra_pct_color=$(color_for_pct "$extra_pct")

        extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        [ -z "$extra_reset" ] && extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')

        rate_lines+="\n${white}extra${reset}   ${extra_bar} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset} ${dim}resets${reset} ${white}${extra_reset}${reset}"
    fi
fi

# ── Output ──────────────────────────────────────────────
printf "%b\n" "$line1"
printf "%b\n" "$line2"
[ -n "$rate_lines" ] && printf "%b" "$rate_lines"

exit 0
