#!/bin/zsh
# Publish a scrubbed copy of this (private) repo to ../Supervision-public.
#   ./scripts/publish.sh "commit message"
# Copies every tracked file except those in .publicignore, then refuses to commit
# if anything matches scripts/private-patterns.txt. Pushes if a remote is set.
set -e
cd "$(dirname "$0")/.."
SRC=$PWD
PUB=${PUBLIC_DIR:-$SRC/../Supervision-public}
MSG=${1:-"Update"}
mkdir -p "$PUB"
[ -d "$PUB/.git" ] || git -C "$PUB" init -q -b main
# Fresh copy of the tracked, publishable files (keep the public repo's .git).
find "$PUB" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git ls-files -z | while IFS= read -r -d '' f; do
  skip=0
  while IFS= read -r pat; do
    [[ -z "$pat" || "$pat" == \#* ]] && continue
    if [[ "$pat" == */ ]]; then [[ "$f" == "$pat"* ]] && skip=1; else [[ "$f" == "$pat" ]] && skip=1; fi
  done < .publicignore
  [ $skip = 1 ] && continue
  mkdir -p "$PUB/$(dirname "$f")" && cp -p "$f" "$PUB/$f"
done
# Leak check: any private pattern anywhere → stop.
if grep -rniE -f scripts/private-patterns.txt --exclude-dir=.git --exclude=LICENSE "$PUB"; then
  echo "\n❌ Private text found above. Nothing was committed. Scrub it in the private repo and re-run."
  exit 1
fi
cd "$PUB"
git add -A
if git diff --cached --quiet; then echo "Nothing new to publish."; exit 0; fi
git commit -q -m "$MSG"
echo "✅ Committed to $PUB: $(git log --oneline -1)"
if git remote get-url origin >/dev/null 2>&1; then git push -q origin main && echo "Pushed."; else echo "(No remote yet; not pushed.)"; fi
