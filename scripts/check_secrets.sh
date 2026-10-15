#!/bin/zsh
# Refuse to commit or push anything that looks like a credential, a personal
# identifier, firmware, or a binary.
#
#   scripts/check_secrets.sh --staged   files staged for commit (pre-commit hook)
#   scripts/check_secrets.sh --all      every tracked file + all commit emails
#
# Personal strings (your email, device serials, team IDs, ...) go one per line
# in .secret-patterns at the repo root. That file is never committed, so the
# deny-list itself cannot leak.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

mode=${1:---staged}
fail=0
complain() { print -u2 "check_secrets: $1"; fail=1; }

if [[ $mode == --staged ]]; then
	files=("${(@f)$(git diff --cached --name-only --diff-filter=ACMR)}")
else
	files=("${(@f)$(git ls-files)}")
fi
files=(${files:#})

# Generic credential formats.
generic='(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{20,}|(password|passwd|secret|api[_-]?key)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{4,})'

personal=()
if [[ -f .secret-patterns ]]; then
	personal=("${(@f)$(grep -v '^[[:space:]]*\(#\|$\)' .secret-patterns)}")
fi

for f in $files; do
	[[ -f $f ]] || continue
	case $f in
	*.bin|*.exe|*.EXE|*.cab|*.gbf|*.png|*.jpg|*.pdf|*.zip|*.dmg|*.app/*|*.p12|*.cer|*.mobileprovision|.secret-patterns)
		complain "$f: file type is never published"; continue ;;
	esac
	if [[ $(stat -f %z "$f") -gt 524288 ]]; then
		complain "$f: larger than 512 KiB"
	fi
	if grep -IqE "$generic" "$f" 2>/dev/null; then
		complain "$f: looks like it contains a credential"
	fi
	for p in $personal; do
		if grep -IqiF -- "$p" "$f" 2>/dev/null; then
			complain "$f: contains a string from .secret-patterns"
		fi
	done
done

# Commits must not carry a personal email address.
check_email() {
	[[ $1 == *@users.noreply.github.com ]] || complain "$2 uses email '$1' (use your GitHub noreply address)"
}
if [[ $mode == --staged ]]; then
	check_email "$(git config user.email)" "this commit"
else
	git rev-parse -q --verify HEAD >/dev/null && git log --format='%H %ae %ce' | while read -r h ae ce; do
		check_email "$ae" "commit ${h:0:8} (author)"
		check_email "$ce" "commit ${h:0:8} (committer)"
	done
fi

if (( fail )); then
	print -u2 "check_secrets: blocked. Fix the items above (or move them out of the repo)."
	exit 1
fi
print "check_secrets: ok (${#files} files)"
