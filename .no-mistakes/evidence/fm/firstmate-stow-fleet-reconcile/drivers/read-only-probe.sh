#!/usr/bin/env bash
source .test-live/common.sh
case_home probe scout
mkdir "$CASE/archive"
mv "$FM_HOME/state/$ID.meta" "$CASE/archive/$ID.meta"
manifest() {
python3 - "$FM_HOME" <<'PY'
import pathlib,sys,hashlib
root=pathlib.Path(sys.argv[1])
for p in sorted(root.rglob('*')):
 if p.is_file(): print(p.relative_to(root), hashlib.sha256(p.read_bytes()).hexdigest())
PY
}
manifest > "$CASE/before"
bash bin/fm-reconcile-underway.sh --archive "$CASE/archive"
manifest > "$CASE/after"
diff -u "$CASE/before" "$CASE/after" || true
