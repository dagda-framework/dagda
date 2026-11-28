$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$compiler = Join-Path $root '.tools\odin-dev-2026-11a\odin.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    [Console]::Error.WriteLine('Pinned Odin is missing. Run: pwsh -File scripts/setup-odin.ps1')
    exit 1
}

& $compiler @args
exit $LASTEXITCODE
