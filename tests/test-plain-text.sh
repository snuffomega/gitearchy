#!/usr/bin/env bash
# Every Text renders as plain text, so markup in a Gitea-supplied PR title,
# repo or job name is shown literally and never fetched or styled (#24).
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
missing=0
checked=0

while IFS= read -r file; do
  while IFS= read -r line; do
    echo "  FAIL: ${file#"$PLUGIN_DIR"/}:$line Text without textFormat: Text.PlainText"
    missing=$((missing + 1))
  done < <(awk '
    # Track brace depth; for each "Text {" block, note whether a direct
    # child line sets textFormat to PlainText before the block closes.
    {
      if (open && depth == start + 1 && $0 ~ /^[[:space:]]*textFormat:[[:space:]]*Text\.PlainText/) ok = 1
      if (!open && $0 ~ /^[[:space:]]*Text[[:space:]]*\{/) { open = 1; start = depth; ok = 0; at = NR }
      n = gsub(/\{/, "{"); c = gsub(/\}/, "}")
      depth += n - c
      if (open && depth <= start) { if (!ok) print at; open = 0 }
    }' "$file")
  checked=$((checked + $(grep -cE '^[[:space:]]*Text[[:space:]]*\{' "$file" || true)))
done < <(find "$PLUGIN_DIR" -name '*.qml' -not -path '*/tools/*' | sort)

echo "  $checked Text elements checked, $missing without plain text"
[ "$checked" -gt 0 ] && [ "$missing" -eq 0 ]
