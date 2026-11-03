# Build single-file EXE from src/ into dist/
# Requires: Python 3.11+ with PyInstaller and Pillow
# Note: the EXE embeds a copy of Optimize-WinClient.ps1 taken at build time.
#       After editing the .ps1, re-run this script or the EXE keeps old logic.

[CmdletBinding()]
param(
    [string]$Python = '',
    [string]$Name = 'Windows优化工具'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$root = Split-Path -Parent $here
$src = Join-Path $root 'src'
$dist = Join-Path $root 'dist'

if (-not $Python) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe')
    )
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $candidates = @($cmd.Source) + $candidates }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { $Python = $c; break }
    }
}

if (-not $Python) { throw 'Python not found. Pass -Python <path to python.exe>.' }

$ver = (Select-String -LiteralPath (Join-Path $src 'winopt_gui.py') -Pattern '^APP_VERSION\s*=\s*"([^"]+)"' |
        Select-Object -First 1).Matches.Groups[1].Value
if (-not $ver) { $ver = '0.0.0' }

$outName = '{0}_v{1}' -f $Name, ($ver -replace '\.\d+$', '')

Write-Host ('Python : {0}' -f $Python)
Write-Host ('Version: {0}' -f $ver)
Write-Host ('Output : dist\{0}.exe' -f $outName)

# PyInstaller must run inside src/ so --add-data relative paths resolve
Push-Location $src
try {
    & $Python -m PyInstaller --noconfirm --onefile --windowed --clean `
        --name $outName `
        --icon 'icon.ico' `
        --add-data 'Optimize-WinClient.ps1;.' `
        --add-data 'icon.ico;.' `
        winopt_gui.py
    if ($LASTEXITCODE -ne 0) { throw ('PyInstaller failed with exit code {0}' -f $LASTEXITCODE) }
}
finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }
$produced = Join-Path $src ('dist\{0}.exe' -f $outName)
Copy-Item -LiteralPath $produced -Destination $dist -Force

# Clean intermediates, keep dist/
Remove-Item -LiteralPath (Join-Path $src 'build') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $src ('dist')) -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $src ('{0}.spec' -f $outName)) -Force -ErrorAction SilentlyContinue

$final = Join-Path $dist ('{0}.exe' -f $outName)
$size = [math]::Round((Get-Item -LiteralPath $final).Length / 1MB, 2)
Write-Host ('Done: {0} ({1} MB)' -f $final, $size)
