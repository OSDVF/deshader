# if ZIG_GLOBAL_CACHE_DIR is not set, set it to zig-cache
if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
    $env:ZIG_GLOBAL_CACHE_DIR = "zig-cache"
}

Get-ChildItem -Path $env:ZIG_GLOBAL_CACHE_DIR -Recurse -Filter cimport.zig | ForEach-Object {
    $file = $_.FullName
    Write-Host "Fixing $file"
    Set-Content -Path $file -Value (get-content -Path $file | Select-String -Pattern 'struct_XSTAT' -NotMatch)
}