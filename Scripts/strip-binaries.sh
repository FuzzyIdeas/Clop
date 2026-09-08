#!/usr/bin/env bash
# Strip the symbol tables of the bundled binaries before they get signed.
# Executables lose every symbol, dylibs keep the exported ones so their
# dependents still link. Files that are already stripped come out
# byte-identical, so their signature stays valid and `make bin` doesn't
# send them through notarization again.
set -euo pipefail

dir="${1:-Clop/bin}"
before=0 after=0

while IFS= read -r -d '' f; do
    case "$(file -b "$f")" in
    *Mach-O*dynamically\ linked\ shared\ library*) args=(-x -S) ;;
    *Mach-O*executable*) args=() ;;
    *) continue ;;
    esac

    b=$(stat -f%z "$f")
    # the signature invalidation warning is expected, the sign step follows
    strip "${args[@]}" "$f" 2>&1 | grep -v 'will invalidate the code signature' || true
    before=$((before + b))
    after=$((after + $(stat -f%z "$f")))
done < <(find "$dir" -type f -print0)

echo "stripped $dir: $before -> $after bytes ($((before - after)) saved)"
