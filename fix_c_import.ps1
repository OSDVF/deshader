$zig_cache = "zig-cache"

Get-ChildItem -Path $zig_cache -Recurse -Filter cimport.zig | ForEach-Object {
    $file = $_.FullName
    Write-Host "Fixing $file"
    Set-Content -Path $file -Value (get-content -Path $file | Select-String -Pattern 'struct_XSTAT' -NotMatch)
}