#!/bin/bash
for file in /home/mousa/.cache/zls/*/*/cimport.zig zig-cache/*/*/cimport.zig
do
    sed -i '/struct_XSTAT/d' "$file"
done
