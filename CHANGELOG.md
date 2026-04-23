# Changelog

## [1.3.1](https://github.com/AbdallahAHO/ccline/compare/v1.3.0...v1.3.1) (2026-04-23)


### Bug Fixes

* **statusline:** avoid leaving stale .git/index.lock ([5bbfdae](https://github.com/AbdallahAHO/ccline/commit/5bbfdaec8b2b2df178594a1dbfcefc0e87ff77a1))

# [1.3.0](https://github.com/AbdallahAHO/ccline/compare/v1.1.1...v1.3.0) (2026-04-17)


### Features

* **statusline:** fixes, cross-platform support, and polish ([a8286ba](https://github.com/AbdallahAHO/ccline/commit/a8286ba2283d63c2ffe384cbc075d1473bf79b84))
* **statusline:** sync bin/statusline.sh to local ([8ce58dc](https://github.com/AbdallahAHO/ccline/commit/8ce58dcd35114aa16e86d27387811b236b548c47))

## [1.2.0](https://github.com/AbdallahAHO/ccline/compare/v1.1.1...v1.2.0) (2026-04-17)

### Features

* agent, worktree, session_name, permission_mode, output_style, and vim-mode badges on line 1
* read `rate_limits` directly from Claude Code's input JSON (fresher than the OAuth API), API becomes a fallback
* autocompact thresholds (warn / compacting / blocked) match upstream source exactly
* burn-fast detection on both the 5h and 7d windows
* session duration + API latency ratio on line 2
* 200k+ downgrade warning (`⚠ downgraded`) when Claude Code shifts to the shorter-context tier

### Bug Fixes

* turn counter no longer counts tool results as user turns (~10× overcount fixed)
* cache file moved to `${TMPDIR:-/tmp}/claude-$UID/` with `0700` perms (multi-user safe)
* session duration works on Linux (GNU `stat -c %W` with mtime fallback) and Git Bash/WSL, not just macOS
* single `jq` parse via `eval` replaces ~15 individual spawns per render
* removed `claude --version` subprocess from the OAuth refresh path (was adding ~300–500ms per cache miss)
* combined git branch + dirty check into one `git status --porcelain=v1 -b` call
* portable date formatting via `date -d`/`date -j -r` dual path — works on GNU and BSD

### Chores

* rendering of the 5h/7d rate rows deduplicated into a single `render_rate_lines` helper
* `LC_ALL=C` for stable date parsing under non-English locales
* `printf '%s'`/`'%b'` used consistently for ANSI output

## [1.1.1](https://github.com/AbdallahAHO/ccline/compare/v1.1.0...v1.1.1) (2026-03-30)

# 1.1.0 (2026-03-30)


### Bug Fixes

* skip npm auth check for OIDC trusted publishing ([9b06059](https://github.com/AbdallahAHO/ccline/commit/9b06059f477c8b46f9b8a77947ae0bb963c8608c))
* upgrade to Node 22 + npm latest for OIDC trusted publishing ([90aeafe](https://github.com/AbdallahAHO/ccline/commit/90aeafee2894176c5beb4b9a50c550e83ec89b19))


### Features

* initial release of @abdallahaho/ccline ([7a54e63](https://github.com/AbdallahAHO/ccline/commit/7a54e63bb22e43da751670828c87ce6ecf31aceb))
