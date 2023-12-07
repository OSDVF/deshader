#!/bin/bash
for file in ~/.cache/zls/*/*/cimport.zig zig-cache/*/*/cimport.zig
do
    sed -i '/struct_XSTAT/d' "$file"
    sed -i 's/\.hex);/.hexadecimal);/' "$file"
done
