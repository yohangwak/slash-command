# Build the Windows release and package it as dist\Slash-Command-Windows-x64.zip.
# Run on Windows from the repository root, with the Swift toolchain on PATH:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package-windows.ps1
# The zip holds one folder, "Slash Command", with the tray app, the command line tool,
# the translations, the icon and the Swift runtime DLLs the two programs load.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

swift build -c release
if ($LASTEXITCODE -ne 0) { throw "swift build failed ($LASTEXITCODE)" }
$bin = (swift build -c release --show-bin-path | Select-Object -Last 1).Trim()

# The Swift runtime of the toolchain that built the programs.
$runtimes = Join-Path $env:LOCALAPPDATA 'Programs\Swift\Runtimes'
$version = (swift --version 2>&1 | Select-String -Pattern 'Swift version (\d+\.\d+(\.\d+)?)').Matches[0].Groups[1].Value
$runtime = Join-Path $runtimes "$version\usr\bin"
if (-not (Test-Path $runtime)) { throw "Swift runtime not found: $runtime" }

$dist = Join-Path (Get-Location) 'dist'
$stage = Join-Path $dist 'Slash Command'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'Resources') | Out-Null

Copy-Item (Join-Path $bin 'SlashCommandWin.exe') (Join-Path $stage 'Slash Command.exe')
Copy-Item (Join-Path $bin 'slashcommand.exe') $stage
Get-ChildItem 'Resources' -Directory -Filter '*.lproj' | ForEach-Object {
    $to = Join-Path $stage "Resources\$($_.Name)"
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    Copy-Item (Join-Path $_.FullName 'Localizable.strings') $to
}
Copy-Item 'Resources\AppIcon.ico' $stage
Copy-Item 'LICENSE' (Join-Path $stage 'LICENSE.txt')

# Copy the DLLs the programs import from the runtime folder, following their imports in turn.
# PE imports are read directly so that no Visual Studio tool is needed.
function Get-Imports([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    $sections = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $optional = $pe + 24
    $optionalSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $importRva = [BitConverter]::ToUInt32($bytes, $optional + 120)   # PE32+ data directory 1
    $table = $optional + $optionalSize
    function Offset([uint32]$rva) {
        for ($i = 0; $i -lt $sections; $i++) {
            $s = $table + 40 * $i
            $va = [BitConverter]::ToUInt32($bytes, $s + 12); $size = [BitConverter]::ToUInt32($bytes, $s + 8)
            if ($rva -ge $va -and $rva -lt $va + [Math]::Max($size, [BitConverter]::ToUInt32($bytes, $s + 16))) {
                return $rva - $va + [BitConverter]::ToUInt32($bytes, $s + 20)
            }
        }
        throw "RVA outside sections in $path"
    }
    $names = @()
    if ($importRva -eq 0) { return $names }
    $entry = Offset $importRva
    while ($true) {
        $nameRva = [BitConverter]::ToUInt32($bytes, $entry + 12)
        if ($nameRva -eq 0) { break }
        $o = Offset $nameRva; $end = $o
        while ($bytes[$end] -ne 0) { $end++ }
        $names += [Text.Encoding]::ASCII.GetString($bytes, $o, $end - $o)
        $entry += 20
    }
    return $names
}
$queue = New-Object System.Collections.Queue
$queue.Enqueue((Join-Path $stage 'Slash Command.exe')); $queue.Enqueue((Join-Path $stage 'slashcommand.exe'))
$seen = @{}
while ($queue.Count -gt 0) {
    foreach ($name in Get-Imports $queue.Dequeue()) {
        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $from = Join-Path $runtime $name
        if (Test-Path $from) { Copy-Item $from $stage; $queue.Enqueue((Join-Path $stage $name)) }
    }
}

$zip = Join-Path $dist 'Slash-Command-Windows-x64.zip'
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $stage -DestinationPath $zip
$hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
"$hash  Slash-Command-Windows-x64.zip" | Set-Content -Encoding ASCII (Join-Path $dist 'Slash-Command-Windows-x64.zip.sha256')
"$zip"
"sha256 $hash"
"files $(@(Get-ChildItem -Recurse -File $stage).Count), DLLs $(@(Get-ChildItem $stage -Filter *.dll).Count)"
