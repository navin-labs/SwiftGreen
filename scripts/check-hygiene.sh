#!/usr/bin/env bash
# Fails on what must never ship: key material, credential-shaped strings, local tool metadata,
# editor/OS junk, build artifacts, developer paths, release-unsafe logging, billing/ads/cloud SDKs, a missing licence,
# and files that are tracked although .gitignore excludes them. Pattern-based, so a pass is
# not proof of no secret — it catches the common shapes. Checks tracked files plus untracked,
# non-ignored ones (what `git add -A` would publish). NUL-separated throughout, so paths with
# spaces or quotes are checked, not skipped.
set -u
cd "$(dirname "$0")/.." || exit 2
git rev-parse --git-dir >/dev/null 2>&1 || { echo "BLOCKED: not a git checkout, nothing to check"; exit 2; }
fail=0
self=scripts/check-hygiene.sh
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

# The candidate tree: existing files only (a staged deletion is not shipped).
git ls-files -z -co --exclude-standard | while IFS= read -r -d '' f; do [ -f "$f" ] && printf '%s\0' "$f"; done > "$tmp/all"
names() { tr '\0' '\n' < "$tmp/all"; }
# Text files to search, minus this script (its patterns would match themselves).
names | grep -v -x -F "$self" | grep -v -E '\.(png|webp|jpg|jpeg|gif|ico|icns|jar|apk|aab|zip|pdf)$' | tr '\n' '\0' > "$tmp/text"
search() { xargs -0 grep -I -n -E -e "$1" < "$tmp/text" 2>/dev/null; }
report() { [ -n "$2" ] && { echo "$1"; echo "$2"; fail=1; }; }

report "Key material or local config:" "$(names | grep -E '\.(p12|pfx|pem|key|jks|keystore|mobileprovision|provisionprofile|cer|der|crt)$|(^|/)certs/|(^|/)local\.properties$|(^|/)keystore\.properties$|(^|/)google-services\.json$|(^|/)GoogleService-Info\.plist$|(^|/)\.env(\.|$)|(^|/)\.netrc$|(^|/)id_(rsa|ed25519|ecdsa)')"

report "Local AI/tool metadata (generated, not source):" "$(names | grep -E '^(\.project-intelligence|\.agents|\.antigravity|\.claude|\.codex|\.cursor|\.gemini|\.vscode|graphify-out|brag-output|mnt)/|^(AGENTS|CLAUDE|GEMINI)\.md$|^skills-lock\.json$|^\.(gemini|graphify)ignore$|^\.antigravity-rules\.md$')"

report "Website files (kept outside this repository):" "$(names | grep -E '^website/')"

report "Editor/OS junk:" "$(names | grep -E '(^|/)(\.DS_Store|Thumbs\.db|desktop\.ini)$|(^|/)\.idea/|\.iml$|xcuserdata/|\.(swp|swo|orig|rej|bak|tmp)$|~$|\.profraw$')"

report "Build output or artifacts:" "$(names | grep -E '\.(apk|aab|ipa|dmg|xcarchive|class|dex|hprof|log|o|a|dylib)$|\.app/|\.dSYM/|(^|/)(DerivedData|build|\.gradle|\.kotlin|node_modules|dist)/')"

# Split so this file's own source never contains the joined pattern.
pk='-----BEGIN [A-Z ]*PRIVATE'' KEY-----'
creds="$pk|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{40,}|xox[baprs]-[0-9A-Za-z-]{10,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|sk_live_[0-9A-Za-z]{20,}|eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{15,}\.|hooks\.slack\.com/services/|(api[_-]?key|secret|token|passw(or)?d)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][A-Za-z0-9/+_=-]{20,}[\"']"
report "Credential-shaped strings:" "$(search "$creds")"

report "Developer home paths:" "$(search '/Users/[A-Za-z0-9._-]+/|/home/[a-z][a-z0-9._-]+/|[Cc]:\\\\Users\\\\')"

# Release logging (see android/.../Log.kt and SwiftGreenApp.swift): Android code logs only
# through the app's Log object; Swift code may not use loggers that bypass the Release no-op
# print or that mark interpolated values public.
report "android.util.Log outside Log.kt (Release builds would log message text):" "$(search 'android\.util\.Log([^A-Za-z]|$)' | grep '\.kt:' | grep -v 'com/swiftgreen/app/Log\.kt:')"
report "Swift logging that bypasses the Release no-op print:" "$(search '(^|[^A-Za-z])(NSLog|debugPrint|dump)\(|Logger\(|%\{public\}|os_log\([^)]*%@' | grep '\.swift:')"
# V1 is free and local-only: no billing, ads, analytics or cloud SDKs in code or build files.
report "Billing, ads, analytics or cloud SDK (V1 is free and local-only):" "$(search 'com\.android\.billingclient|com\.android\.vending\.BILLING|import StoreKit|play-services-ads|com\.google\.android\.gms:|com\.google\.firebase|firebase-|admob|appcenter|mixpanel|com\.amplitude|sentry-|crashlytics' | grep -E '\.(kt|kts|swift|xml|toml|pbxproj|plist|gradle):')"

grep -q "Apache License" LICENSE 2>/dev/null && grep -q "Version 2.0" LICENSE || { echo "LICENSE missing or not Apache-2.0"; fail=1; }

# Ignored but still tracked: .gitignore alone doesn't unpublish them.
report "Tracked although .gitignore excludes them (run: git rm -r --cached <path>):" "$(git ls-files -ci --exclude-standard)"

[ "$fail" -eq 0 ] && echo "hygiene OK ($(names | wc -l | tr -d ' ') files)"
exit "$fail"
