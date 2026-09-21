#!/usr/bin/env bash
# gh artifact usage: per-repo live Actions artifact bytes for the authed user.
# Sorted by usage, empty repos skipped (count reported). Set
# GH_ARTIFACTS_SHOW_EMPTY=1 to list them.
set -u

# TextMate commands run without Homebrew on PATH; gh lives there.
for d in /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH";; esac
done
command -v gh >/dev/null || { echo "gh not found on PATH"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gh-artifacts.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

OWNER=$(gh api user -q .login) || { echo "gh auth failed"; exit 1; }
gh repo list "$OWNER" --limit 1000 --json nameWithOwner \
  -q '.[].nameWithOwner' > "$TMP/repos.txt"
TOTAL=$(wc -l < "$TMP/repos.txt" | tr -d ' ')

one_repo() {
  r=$1
  out=$(gh api "repos/$r/actions/artifacts?per_page=100" \
    -q '"\( [.artifacts[] | select(.expired==false) | .size_in_bytes] | add // 0) \(.total_count)"' \
    2>/dev/null) || out="ERR 0"
  set -- $out
  printf '%s\t%s\t%s\n' "$1" "$2" "$r"
}
export -f one_repo

xargs -P8 -n1 bash -c 'one_repo "$1"' _ < "$TMP/repos.txt" > "$TMP/usage.txt"

sort -rn "$TMP/usage.txt" | awk -F '\t' -v total="$TOTAL" \
  -v show_empty="${GH_ARTIFACTS_SHOW_EMPTY:-0}" '
  $1 == "ERR" { err++; errlist = errlist "  " $3 "\n"; next }
  $1 == 0     { empty++; if (show_empty) print "       0  " $3; next }
  { used++; sum += $1; trunc = ($2 > 100 ? "+" : "")
    plural = ($2 == 1 ? "" : "s")
    printf "%8.1f MB  %s%s  (%d artifact%s)\n", $1/1048576, $3, trunc, $2, plural }
  END {
    printf "\nTotal: %.1f MB live across %d repos", sum/1048576, used
    printf " (%d of %d listed repos empty", empty, total
    if (err) printf ", %d errored", err
    printf ")\n"
    if (err) printf "\nErrored repos (no Actions access):\n%s", errlist
    printf "\n+ = over 100 artifacts: byte count covers the first 100 only.\n"
  }'
