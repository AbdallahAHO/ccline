#!/bin/bash
set -f

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
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

color_for_pct() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"
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
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

iso_to_epoch() {
    local iso_str="$1"

    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
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
        echo "$epoch"
        return 0
    fi

    return 1
}

# Accepts either ISO string or epoch seconds
to_epoch() {
    local val="$1"
    [ -z "$val" ] || [ "$val" = "null" ] || [ "$val" = "0" ] && return 1

    # Already epoch (pure digits)
    if [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "$val"
        return 0
    fi

    # ISO string
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
            result=$(date -j -r "$epoch" +"%l:%M%p" 2>/dev/null | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%l:%M%P" 2>/dev/null | sed 's/^ //; s/\.//g')
            ;;
        datetime)
            result=$(date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null | sed 's/  / /g; s/^ //; s/\.//g')
            ;;
        *)
            result=$(date -j -r "$epoch" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            [ -z "$result" ] && result=$(date -d "@$epoch" +"%b %-d" 2>/dev/null)
            ;;
    esac
    printf "%s" "$result"
}

# ── Single jq parse ────────────────────────────────────
eval "$(echo "$input" | jq -r '
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
  "session_name=" + (.session_name // "" | @sh),
  "agent_name=" + (.agent.name // "" | @sh),
  "worktree_name=" + (.worktree.name // "" | @sh),
  "transcript_path=" + (.transcript_path // "" | @sh)
')"

# ── Derived values ─────────────────────────────────────
current=$(( input_tokens + cache_create + cache_read ))
used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $ctx_size)

session_cost_fmt=$(awk "BEGIN {printf \"%.2f\", $session_cost}")

# Shorten model: "Opus 4.6 (1M context)" -> "O4.6 1M"
model_short=$(echo "$model_name" | sed -E \
    -e 's/Opus /O/' \
    -e 's/Sonnet /S/' \
    -e 's/Haiku /H/' \
    -e 's/ *\(1M context\)/ 1M/' \
    -e 's/ *\(200K context\)//')

# Effort level
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

git_branch=""
git_dirty=""
if git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$project_dir" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$project_dir" status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

# ── Turn counter ───────────────────────────────────────
turn_count=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    turn_count=$(grep -c '"type":"user"' "$transcript_path" 2>/dev/null || echo "0")
fi

# ── Session duration ───────────────────────────────────
session_duration=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    start_epoch=$(stat -f %B "$transcript_path" 2>/dev/null)
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
if [ -n "$pt_hour" ] && [ "$pt_hour" -ge 5 ] && [ "$pt_hour" -lt 11 ]; then
    is_peak=true
    today_pt=$(TZ="America/Los_Angeles" date +%Y-%m-%d)
    peak_end_epoch=$(TZ="America/Los_Angeles" date -j -f "%Y-%m-%d %H:%M:%S" "${today_pt} 11:00:00" +%s 2>/dev/null)
    if [ -n "$peak_end_epoch" ]; then
        peak_end_local=$(date -j -r "$peak_end_epoch" +"%l%p" 2>/dev/null | sed 's/^ //; s/\.//g' | tr '[:upper:]' '[:lower:]')
    fi
fi

# ── Autocompact thresholds (from Claude Code source) ──
autocompact_threshold=$(( ctx_size - 13000 ))
warning_threshold=$(( autocompact_threshold - 20000 ))
blocking_threshold=$(( ctx_size - 3000 ))

# ── LINE 1: Model+Effort | Project (branch) +lines ───
line1=""

case "$effort" in
    high)   line1+="${blue}${model_short}${reset} ${magenta}● ${effort}${reset}" ;;
    medium) line1+="${blue}${model_short}${reset} ${white}◑ ${effort}${reset}" ;;
    low)    line1+="${blue}${model_short}${reset} ${dim}◔ ${effort}${reset}" ;;
    *)      line1+="${blue}${model_short}${reset} ${dim}◑ ${effort}${reset}" ;;
esac

line1+="${sep}"

line1+="📂 ${cyan}${project_name}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
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

# 200k+ model downgrade warning
if [ "$exceeds_200k" = "true" ]; then
    line1+=" ${red}⚠ downgraded${reset}"
fi

# ── LINE 2: Session stats ─────────────────────────────
line2=""

if [ -n "$turn_count" ] && [ "$turn_count" -gt 0 ] 2>/dev/null; then
    turn_color="$white"
    [ "$turn_count" -ge 30 ] && turn_color="$yellow"
    [ "$turn_count" -ge 50 ] && turn_color="$red"
    line2+="${turn_color}#${turn_count}${reset} ${dim}turns${reset}"
fi

if [ -n "$session_duration" ]; then
    [ -n "$line2" ] && line2+="${sep}"
    line2+="⏱ ${white}${session_duration}${reset}"
fi

# Context usage with smart compact warning
pct_color=$(color_for_pct "$pct_used")
[ -n "$line2" ] && line2+="${sep}"
line2+="${pct_color}${pct_used}%${reset} ${white}${used_tokens}/${total_tokens}${reset} ${dim}ctx${reset}"

if [ "$current" -ge "$blocking_threshold" ]; then
    line2+=" ${red}⛔ blocked${reset}"
elif [ "$current" -ge "$autocompact_threshold" ]; then
    line2+=" ${red}compacting…${reset}"
elif [ "$current" -ge "$warning_threshold" ]; then
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
if [ "$total_duration" -gt 0 ] && [ "$api_duration" -gt 0 ]; then
    api_pct=$(( api_duration * 100 / total_duration ))
    line2+="${sep}${dim}api ${api_pct}%${reset}"
fi

# ── OAuth token resolution ──────────────────────────────
get_oauth_token() {
    local token=""

    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    if command -v security >/dev/null 2>&1; then
        local blob
        blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    local creds_file="${HOME}/.claude/.credentials.json"
    if [ -f "$creds_file" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            echo "$token"
            return 0
        fi
    fi

    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    echo ""
}

# ── Rate limit lines ────────────────────────────────────
rate_lines=""
bar_width=8

# Prefer input JSON rate_limits (from Claude Code response headers — freshest data)
if [ "$five_hour_pct" -gt 0 ] || [ "$seven_day_pct" -gt 0 ]; then

    # Current (5-hour)
    five_hour_reset_fmt=$(format_reset_time "$five_hour_reset" "time")
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")
    five_hour_pct_color=$(color_for_pct "$five_hour_pct")
    five_hour_pct_fmt=$(printf "%3d" "$five_hour_pct")

    rate_lines+="${white}current${reset} ${five_hour_bar} ${five_hour_pct_color}${five_hour_pct_fmt}%${reset} ${dim}resets${reset} ${white}${five_hour_reset_fmt}${reset}"

    if $is_peak; then
        rate_lines+="  🔥 ${red}PEAK${reset}"
        if [ -n "$peak_end_local" ]; then
            rate_lines+=" ${dim}til${reset} ${white}${peak_end_local}${reset}"
        fi
    fi

    # Burning fast? (5-hour window)
    five_hour_epoch=$(to_epoch "$five_hour_reset" 2>/dev/null)
    if [ -n "$five_hour_epoch" ] && [ "$five_hour_pct" -ge 90 ]; then
        now_epoch=$(date +%s)
        five_hour_remaining=$(( five_hour_epoch - now_epoch ))
        five_hour_window=18000
        five_hour_time_pct=$(awk "BEGIN {printf \"%.2f\", 1 - ($five_hour_remaining / $five_hour_window)}")
        if awk "BEGIN {exit !($five_hour_time_pct <= 0.72)}"; then
            rate_lines+="  ${red}⚡ burning fast${reset}"
        fi
    fi

    # Weekly (7-day)
    seven_day_reset_fmt=$(format_reset_time "$seven_day_reset" "datetime")
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")
    seven_day_pct_color=$(color_for_pct "$seven_day_pct")
    seven_day_pct_fmt=$(printf "%3d" "$seven_day_pct")

    # Burn rate
    burn_rate=""
    seven_day_epoch=$(to_epoch "$seven_day_reset" 2>/dev/null)
    if [ -n "$seven_day_epoch" ] && [ "$seven_day_pct" -gt 0 ]; then
        now_epoch=$(date +%s)
        secs_remaining=$(( seven_day_epoch - now_epoch ))
        days_elapsed=$(awk "BEGIN {d = 7 - ($secs_remaining / 86400); if (d < 0.1) d = 0.1; printf \"%.1f\", d}")
        burn_per_day=$(awk "BEGIN {printf \"%.0f\", $seven_day_pct / $days_elapsed}")
        projected=$(awk "BEGIN {printf \"%.0f\", $burn_per_day * 7}")

        burn_color="$green"
        [ "$projected" -ge 80 ] 2>/dev/null && burn_color="$yellow"
        [ "$projected" -ge 100 ] 2>/dev/null && burn_color="$red"

        burn_rate="${burn_color}~${burn_per_day}%/day${reset}"

        # Weekly burn-fast detection
        if [ "$secs_remaining" -gt 0 ]; then
            time_pct=$(awk "BEGIN {printf \"%.2f\", 1 - ($secs_remaining / 604800)}")
            burning_fast=false
            if [ "$seven_day_pct" -ge 75 ] && awk "BEGIN {exit !($time_pct <= 0.60)}"; then burning_fast=true; fi
            if [ "$seven_day_pct" -ge 50 ] && awk "BEGIN {exit !($time_pct <= 0.35)}"; then burning_fast=true; fi
            if [ "$seven_day_pct" -ge 25 ] && awk "BEGIN {exit !($time_pct <= 0.15)}"; then burning_fast=true; fi
            if $burning_fast; then
                burn_rate+=" ${red}⚡${reset}"
            fi
        fi
    fi

    rate_lines+="\n${white}weekly${reset}  ${seven_day_bar} ${seven_day_pct_color}${seven_day_pct_fmt}%${reset} ${dim}resets${reset} ${white}${seven_day_reset_fmt}${reset}"
    if [ -n "$burn_rate" ]; then
        rate_lines+="  ${burn_rate}"
    fi
fi

# ── Fetch from API (fallback for rate limits + extra usage) ─
cache_file="/tmp/claude/statusline-usage-cache.json"
cache_max_age=60
mkdir -p /tmp/claude 2>/dev/null

needs_refresh=true
usage_data=""

if [ -f "$cache_file" ]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
    now=$(date +%s)
    cache_age=$(( now - cache_mtime ))
    if [ "$cache_age" -lt "$cache_max_age" ]; then
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
            -H "User-Agent: claude-code/$(claude --version 2>/dev/null | awk '{print $1}')" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
            usage_data="$response"
            echo "$response" > "$cache_file"
        fi
    fi
    if [ -z "$usage_data" ] && [ -f "$cache_file" ]; then
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
fi

if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
    # Use API data as fallback if input JSON had no rate limits
    if [ -z "$rate_lines" ]; then
        f_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
        f_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
        s_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
        s_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')

        f_reset_fmt=$(format_reset_time "$f_reset_iso" "time")
        s_reset_fmt=$(format_reset_time "$s_reset_iso" "datetime")

        rate_lines+="${white}current${reset} $(build_bar "$f_pct" "$bar_width") $(color_for_pct "$f_pct")$(printf "%3d" "$f_pct")%${reset} ${dim}resets${reset} ${white}${f_reset_fmt}${reset}"

        if $is_peak; then
            rate_lines+="  🔥 ${red}PEAK${reset}"
            if [ -n "$peak_end_local" ]; then
                rate_lines+=" ${dim}til${reset} ${white}${peak_end_local}${reset}"
            fi
        fi

        # Burn rate from API data
        burn_rate=""
        if [ -n "$s_reset_iso" ] && [ "$s_pct" -gt 0 ]; then
            reset_epoch=$(to_epoch "$s_reset_iso")
            if [ -n "$reset_epoch" ]; then
                now_epoch=$(date +%s)
                secs_remaining=$(( reset_epoch - now_epoch ))
                days_elapsed=$(awk "BEGIN {d = 7 - ($secs_remaining / 86400); if (d < 0.1) d = 0.1; printf \"%.1f\", d}")
                burn_per_day=$(awk "BEGIN {printf \"%.0f\", $s_pct / $days_elapsed}")
                projected=$(awk "BEGIN {printf \"%.0f\", $burn_per_day * 7}")

                burn_color="$green"
                [ "$projected" -ge 80 ] 2>/dev/null && burn_color="$yellow"
                [ "$projected" -ge 100 ] 2>/dev/null && burn_color="$red"

                burn_rate="${burn_color}~${burn_per_day}%/day${reset}"
            fi
        fi

        rate_lines+="\n${white}weekly${reset}  $(build_bar "$s_pct" "$bar_width") $(color_for_pct "$s_pct")$(printf "%3d" "$s_pct")%${reset} ${dim}resets${reset} ${white}${s_reset_fmt}${reset}"
        if [ -n "$burn_rate" ]; then
            rate_lines+="  ${burn_rate}"
        fi
    fi

    # Extra usage (always from API — not available in input JSON)
    extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
    if [ "$extra_enabled" = "true" ]; then
        extra_pct=$(echo "$usage_data" | jq -r '.extra_usage.utilization // 0' | awk '{printf "%.0f", $1}')
        extra_used=$(echo "$usage_data" | jq -r '.extra_usage.used_credits // 0' | awk '{printf "%.2f", $1/100}')
        extra_limit=$(echo "$usage_data" | jq -r '.extra_usage.monthly_limit // 0' | awk '{printf "%.2f", $1/100}')
        extra_bar=$(build_bar "$extra_pct" "$bar_width")
        extra_pct_color=$(color_for_pct "$extra_pct")

        extra_reset=$(date -v+1m -v1d +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [ -z "$extra_reset" ]; then
            extra_reset=$(date -d "$(date +%Y-%m-01) +1 month" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        fi

        rate_lines+="\n${white}extra${reset}   ${extra_bar} ${extra_pct_color}\$${extra_used}${dim}/${reset}${white}\$${extra_limit}${reset} ${dim}resets${reset} ${white}${extra_reset}${reset}"
    fi
fi

# ── Output ──────────────────────────────────────────────
printf "%b\n" "$line1"
printf "%b\n" "$line2"
[ -n "$rate_lines" ] && printf "%b" "$rate_lines"

exit 0
