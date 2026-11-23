#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT_DIR"

MOD_ID=$(sed -n 's/^id=//p' module.prop | head -n 1 | tr -d '\r')
MOD_VER=$(sed -n 's/^version=//p' module.prop | head -n 1 | tr -d '\r')

if [ -z "$MOD_ID" ] || [ -z "$MOD_VER" ]; then
  echo "Error: failed to read id/version from module.prop" >&2
  exit 1
fi

OUT_DIR="$ROOT_DIR/dist"
OUT_ZIP="$OUT_DIR/${MOD_ID}-${MOD_VER}.zip"
mkdir -p "$OUT_DIR"
rm -f "$OUT_ZIP"

PAYLOAD="META-INF module.prop system.prop customize.sh action.sh common.sh post-fs-data.sh service.sh uninstall.sh webroot"

if command -v zip >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  zip -r9 "$OUT_ZIP" $PAYLOAD
else
  python3 - "$OUT_ZIP" $PAYLOAD << 'PYEOF'
import os
import stat
import sys
import zipfile

out_zip = sys.argv[1]
targets = sys.argv[2:]

with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for target in sorted(targets):
        if os.path.isdir(target):
            for dirpath, dirnames, filenames in os.walk(target):
                dirnames.sort()
                filenames.sort()
                for fname in filenames:
                    fpath = os.path.join(dirpath, fname)
                    rel = fpath.replace(os.sep, "/")
                    st = os.stat(fpath)
                    zi = zipfile.ZipInfo(rel)
                    zi.compress_type = zipfile.ZIP_DEFLATED
                    zi.external_attr = (stat.S_IFREG | stat.S_IMODE(st.st_mode)) << 16
                    with open(fpath, "rb") as f:
                        zf.writestr(zi, f.read())
        elif os.path.isfile(target):
            rel = target.replace(os.sep, "/")
            st = os.stat(target)
            zi = zipfile.ZipInfo(rel)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (stat.S_IFREG | stat.S_IMODE(st.st_mode)) << 16
            with open(target, "rb") as f:
                zf.writestr(zi, f.read())
PYEOF
fi

SIZE=$(wc -c < "$OUT_ZIP" | tr -d ' ')
echo "Built: $OUT_ZIP ($SIZE bytes)"
