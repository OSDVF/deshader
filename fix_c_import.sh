#!/bin/bash
if [ -z "$ZIG_LOCAL_CACHE_DIR" ]; then
    ZIG_LOCAL_CACHE_DIR=".zig-cache"
fi

for file in ~/.cache/zls/*/*/cimport.zig $ZIG_LOCAL_CACHE_DIR/*/*/cimport.zig
do
    if [ ! -f "$file" ]; then
        continue
    fi
    sed -i '/struct_XSTAT/d' "$file"
done
