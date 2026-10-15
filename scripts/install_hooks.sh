#!/bin/zsh
# Install git hooks that run scripts/check_secrets.sh before every commit
# (staged files) and every push (all tracked files and commit emails).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
hooks=$(git rev-parse --git-path hooks)
mkdir -p "$hooks"
print '#!/bin/zsh\nexec "$(git rev-parse --show-toplevel)/scripts/check_secrets.sh" --staged' > "$hooks/pre-commit"
print '#!/bin/zsh\nexec "$(git rev-parse --show-toplevel)/scripts/check_secrets.sh" --all' > "$hooks/pre-push"
chmod +x "$hooks/pre-commit" "$hooks/pre-push" scripts/check_secrets.sh
print "installed pre-commit and pre-push hooks in $hooks"
