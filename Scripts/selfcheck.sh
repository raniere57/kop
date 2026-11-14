#!/bin/sh
# Compiles and runs the storage self-check against a throwaway database.
set -e
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/kop-selfcheck"
swiftc -O -o "$OUT" \
    Kop/Core/ClipboardItem.swift \
    Kop/Core/PersistenceManager.swift \
    Kop/Helpers/ImageThumbnail.swift \
    Scripts/selfcheck/main.swift
"$OUT"
