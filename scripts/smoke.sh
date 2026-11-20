#!/usr/bin/env bash
# pi + Workers AI smoke test — verifies the make-or-break gate:
# does the reviewer model (Kimi K3.1 Pro) actually drive pi's tool loop (bash/read) through the
# Cloudflare OpenAI-compatible endpoint?
#
# Usage:
#   export CLOUDFLARE_ACCOUNT_ID=xxxx
#   export CLOUDFLARE_API_TOKEN=yyyy   # token with Workers AI: Read
#   bash smoke.sh
#   MODEL_REVIEWER=moonshotai/kimi-k3 bash smoke.sh   # gate another reviewer model
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
: "${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID}"
: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"
MODEL_REVIEWER="${MODEL_REVIEWER:-moonshotai/kimi-k3.1-pro}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
envsubst '${CLOUDFLARE_ACCOUNT_ID}' < "$DIR/../config/models.json.tmpl" > "$WORK/models.json"

echo "==> [0] raw endpoint reachability (chat/completions, no tools)"
curl -sS -m 60 -w '\nHTTP %{http_code}\n' \
  "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/v1/chat/completions" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"'"$MODEL_REVIEWER"'","messages":[{"role":"user","content":"reply with the single word PONG"}]}' \
  || { echo "RAW ENDPOINT FAILED"; exit 1; }

echo
echo "==> [1] pi sees the models"
HOME="$WORK" mkdir -p "$WORK/.pi/agent"
cp "$WORK/models.json" "$WORK/.pi/agent/models.json"
HOME="$WORK" pi --list-models 2>&1 | grep -iE "moonshotai|google" || { echo "pi did not register Workers AI models"; exit 1; }

echo
echo "==> [2] $MODEL_REVIEWER must DRIVE THE TOOL LOOP (bash). This is the real gate."
# Force a tool call: ask it to create a file via bash, then we check the file exists.
SENTINEL="kimi_tool_loop_ok_$$"
cd "$WORK"
set +e
OUT=$(HOME="$WORK" pi -p -a \
  --provider cloudflare --model "$MODEL_REVIEWER" \
  --tools bash \
  "Use the bash tool to run exactly: touch $SENTINEL . Then reply DONE." 2>&1)
RC=$?
set -e
echo "--- pi output (kimi) ---"; echo "$OUT" | tail -20
if [[ -f "$WORK/$SENTINEL" ]]; then
  echo "PASS: $MODEL_REVIEWER executed a bash tool call (sentinel file created)."
else
  echo "FAIL: $MODEL_REVIEWER did NOT execute the tool call (no sentinel). rc=$RC"
  echo ">>> Likely tool-calling incompatibility — may need compat flags or a different model."
  exit 2
fi

echo
echo "==> [3] Gemma 4 plain completion (summarizer role, no tools)"
HOME="$WORK" pi -p --provider cloudflare --model "@cf/google/gemma-4-26b-a4b-it" \
  "Summarize in one sentence: the quick brown fox jumps over the lazy dog." 2>&1 | tail -5

echo
echo "ALL SMOKE CHECKS PASSED ✅  (endpoint + model registration + Kimi tool loop + Gemma completion)"
