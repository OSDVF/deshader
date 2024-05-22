if (-not $env:ZIG_LOCAL_CACHE_DIR) {
    $env:ZIG_LOCAL_CACHE_DIR = "zig-cache"
}

Get-ChildItem -Path $env:ZIG_LOCAL_CACHE_DIR -Recurse -Filter cimport.zig | ForEach-Object {
    $file = $_.FullName
    Write-Host "Fixing $file"
    Set-Content -Path $file -Value (get-content -Path $file | Select-String -Pattern 'struct_XSTAT' -NotMatch)
}