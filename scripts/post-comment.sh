#!/usr/bin/env bash
# Post a PR comment from a Markdown file.
#
# Each comment carries a hidden marker that records the reviewed head sha:
#   <!-- pi-review-action:review reviewed=<sha> -->
# review.sh reads the newest such marker to decide full vs incremental review,
# so we always CREATE a new comment (never edit): successive reviews of new
# commits form a thread. Re-runs on an already-reviewed sha are skipped upstream,
# so this does not double-post.
#
# Usage: post-comment.sh <body-file>
# Env:   GH_TOKEN / GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER
#        REVIEWED_SHA  head sha this review covers (embedded in the marker)
set -euo pipefail

BODY_FILE="${1:?usage: post-comment.sh <body-file>}"
REVIEWED_SHA="${REVIEWED_SHA:-}"
MARKER="<!-- pi-review-action:review reviewed=${REVIEWED_SHA} -->"

# Append the hidden marker so the next run can find this comment.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat "$BODY_FILE" > "$TMP"
printf '\n\n%s\n' "$MARKER" >> "$TMP"

if [[ -z "${PR_NUMBER:-}" ]]; then
  echo "::notice::Not a pull request — skipping PR comment. Body:"
  cat "$TMP"
  exit 0
fi

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"

echo "Creating review comment on PR #${PR_NUMBER} (reviewed=${REVIEWED_SHA:-unknown})"
gh api -X POST "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  -F body=@"${TMP}" >/dev/null
