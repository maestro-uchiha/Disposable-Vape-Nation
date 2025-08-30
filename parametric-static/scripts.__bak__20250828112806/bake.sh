#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

BRAND="${1:-}"
MONEY="${2:-}"

# optional: read bake-config.json when args missing
if [[ -z "$BRAND" || -z "$MONEY" ]] && [[ -f bake-config.json ]]; then
  BRAND="${BRAND:-$(jq -r '.brand' bake-config.json 2>/dev/null || echo '')}"
  MONEY="${MONEY:-$(jq -r '.url' bake-config.json 2>/dev/null || echo '')}"
fi
BRAND="${BRAND:-{{BRAND}}}"
MONEY="${MONEY:-https://YOUR-DOMAIN.com}"
YEAR="$(date +%Y)"

if [[ -f VERSION ]]; then echo "[Amaterasu Static Deploy] Version $(cat VERSION)"; else echo "[Amaterasu Static Deploy] Version (unknown)"; fi
echo "[ASD] BRAND=\"$BRAND\" MONEY=\"$MONEY\" YEAR=$YEAR"
echo "[Amaterasu Static Deploy] Baking…"

inject() {
  local f="$1"
  local tmp; tmp="$(mktemp)"
  sed -e "s/{{BRAND}}/${BRAND//\//\\/}/g" \
      -e "s|{{MONEY}}|${MONEY//\//\\/}|g" \
      -e "s/{{YEAR}}/${YEAR}/g" \
      -e "/<!--#include virtual=\"partials\/head-seo.html\" -->/{
            r partials/head-seo.html
            d
          }" \
      -e "/<!--#include virtual=\"partials\/nav.html\" -->/{
            r partials/nav.html
            d
          }" \
      -e "/<!--#include virtual=\"partials\/footer.html\" -->/{
            r partials/footer.html
            d
          }" "$f" > "$tmp" && mv "$tmp" "$f"
}

for f in index.html about.html contact.html sitemap.html 404.html legal/*.html blog/*.html; do
  [[ -f "$f" ]] && inject "$f"
done

# Build blog index
POSTS=""
for f in blog/*.html; do
  [[ "$(basename "$f")" = "index.html" ]] && continue
  TITLE="$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p;T;q' "$f")"; [[ -z "$TITLE" ]] && TITLE="(no title)"
  if date -r "$f" +%F >/dev/null 2>&1; then DATE="$(date -r "$f" +%F)"; else DATE="$(stat -f "%Sm" -t "%Y-%m-%d" "$f")"; fi
  REL="blog/$(basename "$f")"
  POSTS="${POSTS}<li><a href='/${REL}'>${TITLE}</a><small> — ${DATE}</small></li>
"
done
awk -v RS='' -v POSTS="$POSTS" '
  { gsub(/<!-- POSTS_START -->.*<!-- POSTS_END -->/, "<!-- POSTS_START -->\n" POSTS "\n<!-- POSTS_END -->") }
  { print }
' blog/index.html > blog/index.tmp && mv blog/index.tmp blog/index.html

# Update config.json if jq exists
if command -v jq >/dev/null 2>&1 && [[ -f config.json ]]; then
  jq --arg b "$BRAND" --arg m "$MONEY" '.brand=$b | .moneySite=$m' config.json > config.tmp && mv config.tmp config.json
fi

echo "[Amaterasu Static Deploy] Done."
