#!/usr/bin/env bash
# Strict no-emit contract check for the tracked Firstmate Pi extensions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v npm >/dev/null 2>&1 || { echo "skip: Pi extension typecheck prerequisite not found: npm"; exit 0; }
command -v tsc >/dev/null 2>&1 || { echo "skip: Pi extension typecheck prerequisite not found: tsc"; exit 0; }

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: Pi extension typecheck prerequisite not found: installed @earendil-works/pi-coding-agent package"
  exit 0
fi
# npm and bundled Pi installations may hoist dependencies beside the package.
PI_DEPENDENCIES="$PI_PACKAGE_DIR/node_modules"
if [ ! -d "$PI_DEPENDENCIES/typebox" ]; then
  PI_DEPENDENCIES="$(cd "$PI_PACKAGE_DIR/../.." && pwd)"
fi
for dependency in typebox @earendil-works/pi-tui @earendil-works/pi-ai @types/node; do
  if [ ! -d "$PI_DEPENDENCIES/$dependency" ]; then
    echo "not ok - installed Pi package is missing dependency: $dependency" >&2
    exit 1
  fi
done

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/lib" "$TMP_ROOT/node_modules/@earendil-works" "$TMP_ROOT/node_modules/@types"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$TMP_ROOT/fm-branch-supervision.ts"
cp "$ROOT/.pi/extensions/fm-stow.ts" "$TMP_ROOT/fm-stow.ts"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$TMP_ROOT/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$TMP_ROOT/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$TMP_ROOT/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$TMP_ROOT/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$TMP_ROOT/lib/fm-native-contract.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$TMP_ROOT/lib/fm-async-exec.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$TMP_ROOT/lib/fm-branch-model-picker.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$TMP_ROOT/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-preservation.ts" "$TMP_ROOT/lib/fm-calm-preservation.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$TMP_ROOT/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-pending-operational-layout.ts" "$TMP_ROOT/lib/fm-calm-pending-operational-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$TMP_ROOT/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$TMP_ROOT/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts" "$TMP_ROOT/lib/fm-calm-working-ship-sprite.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$TMP_ROOT/lib/fm-operational-input.ts"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_DEPENDENCIES/@earendil-works/pi-tui" "$TMP_ROOT/node_modules/@earendil-works/pi-tui"
ln -s "$PI_DEPENDENCIES/@earendil-works/pi-ai" "$TMP_ROOT/node_modules/@earendil-works/pi-ai"
ln -s "$PI_DEPENDENCIES/typebox" "$TMP_ROOT/node_modules/typebox"
ln -s "$PI_DEPENDENCIES/@types/node" "$TMP_ROOT/node_modules/@types/node"

cat > "$TMP_ROOT/package.json" <<'JSON'
{"type":"module"}
JSON
cat > "$TMP_ROOT/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2022",
    "types": ["node"]
  },
  "include": ["*.ts", "lib/*.ts"]
}
JSON

tsc -p "$TMP_ROOT/tsconfig.json" || exit 1
version=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
printf 'ok - tracked Pi extensions pass strict no-emit typecheck against Pi %s\n' "$version"

# Provider-free scheduling, receipt, recovery, and command contract tests use
# the same real package and checked extension sources in this isolated root.
cp "$ROOT/tests/assets/fm-stow-harness.mjs" "$TMP_ROOT/fm-stow-harness.mjs"
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home/config" "$TMP_ROOT/home/data" "$TMP_ROOT/home/state"
for script in "$ROOT/bin/"*.sh; do ln -s "$script" "$TMP_ROOT/bin/$(basename "$script")"; done
printf '18000\n' > "$TMP_ROOT/home/config/startup-memory-budget"
FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$TMP_ROOT" FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  node "$TMP_ROOT/fm-stow-harness.mjs" || exit 1
