#!/usr/bin/env bash
# Packs module/ together with README.md and LICENSE into dist/xmsf_netblock-<version>.zip, which
# KernelSU or Magisk installs directly. File order, permissions and timestamps are fixed, and the
# time zone too (zip stores local time), so the same source always gives the same zip.
set -euo pipefail
cd "$(dirname "$0")"

ver=$(sed -n 's/^version=//p' module/module.prop)
[ -n "$ver" ] || { echo "no version in module/module.prop" >&2; exit 1; }
out="$PWD/dist/xmsf_netblock-$ver.zip"
stage=dist/.stage

mkdir -p "$stage"
rm -f "$stage"/* "$out"
cp module/* README.md LICENSE "$stage/"
chmod 0644 "$stage"/*
chmod 0755 "$stage"/*.sh
touch -d @1767225600 "$stage"/*            # 2026-01-01T00:00:00Z
(cd "$stage" && LC_ALL=C ls | TZ=UTC zip -X -q -D "$out" -@)

echo "$out"
sha256sum "$out" | cut -d' ' -f1
