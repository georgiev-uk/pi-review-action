# Reduce a pi `--mode json` JSONL event stream to one line of review stats.
# Usage: jq -rn -f pi-stats.jq < axis.jsonl
#   turns, per-tool call counts, token totals, cost, and a thinking-vs-text
#   character split (a cheap proxy for how much time went to reasoning).
[inputs] as $ev
| [ $ev[] | select(.type == "message_end" and .message.role == "assistant") | .message ] as $am
| ([ $am[].content[] | select(.type == "thinking") | .thinking | length ] | add // 0) as $think
| ([ $am[].content[] | select(.type == "text")     | .text     | length ] | add // 0) as $text
| {
    turns:      ($ev | map(select(.type == "turn_end")) | length),
    tool_calls: ($ev | map(select(.type == "tool_execution_end") | .toolName)
                     | group_by(.) | map("\(.[0])×\(length)") | join(", ")),
    in_tokens:  ($am | map(.usage.input)  | add // 0),
    out_tokens: ($am | map(.usage.output) | add // 0),
    ctx_final:  ($am | last | .usage.input // 0),
    cost_usd:   (($am | map(.usage.cost.total) | add // 0) * 10000 | round / 10000),
    think_chars: $think,
    text_chars:  $text,
    think_pct:   (if ($think + $text) > 0 then ($think * 100 / ($think + $text) | round) else 0 end)
  }
| "turns=\(.turns) tools=[\(.tool_calls)] in_tok=\(.in_tokens) out_tok=\(.out_tokens) ctx_final=\(.ctx_final) cost=$\(.cost_usd) thinking=\(.think_pct)% (think_chars=\(.think_chars) text_chars=\(.text_chars))"
