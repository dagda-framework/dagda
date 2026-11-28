param(
    [Parameter(Position = 0)]
    [string]$ArchivePath
)

$ErrorActionPreference = 'Stop'

$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if ($arch -ne [System.Runtime.InteropServices.Architecture]::X64) {
    [Console]::Error.WriteLine("The current Windows compiler pin supports x64 only (found $arch).")
    exit 1
}

$root = Split-Path -Parent $PSScriptRoot
$lockPath = Join-Path $root 'dagda.lock'
$lock = Get-Content -Path $lockPath -Raw | ConvertFrom-Json
$pin = $lock.platforms.'windows-amd64'
if ($null -eq $pin) {
    [Console]::Error.WriteLine("Missing windows-amd64 entry in dagda.lock.")
    exit 1
}

$toolsDir = Join-Path $root '.tools'
$destination = Join-Path $toolsDir ("odin-" + $pin.version)
$installedExe = Join-Path $destination 'odin.exe'
if (Test-Path -LiteralPath $installedExe -PathType Leaf) {
    & $installedExe version
    exit $LASTEXITCODE
}

New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
$stage = Join-Path $toolsDir ("install." + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
    $archive = Join-Path $stage 'odin.zip'
    if ($ArchivePath) {
        Copy-Item -LiteralPath $ArchivePath -Destination $archive -Force
    } else {
        $downloaded = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -Uri $pin.url -OutFile $archive -UseBasicParsing
                $downloaded = $true
                break
            } catch {
                if ($attempt -eq 3) {
                    throw
                }
                Start-Sleep -Seconds 2
            }
        }
        if (-not $downloaded) {
            throw "Failed to download $($pin.url)"
        }
    }

    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $pin.sha256.ToLowerInvariant()
    if ($actual -ne $expected) {
        [Console]::Error.WriteLine("Odin release checksum mismatch; nothing installed.")
        exit 1
    }

    $unpacked = Join-Path $stage 'unpacked'
    New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $unpacked -Force

    $candidates = @(Get-ChildItem -Path $unpacked -Filter 'odin.exe' -File -Recurse | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.DirectoryName 'core') -PathType Container
    })
    if ($candidates.Count -ne 1) {
        [Console]::Error.WriteLine("Expected one compiler beside its core library in the verified archive.")
        exit 1
    }

    $compilerDir = $candidates[0].DirectoryName
    $compilerExe = $candidates[0].FullName
    & $compilerExe version
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Move-Item -LiteralPath $compilerDir -Destination $destination
    Write-Host "Installed Odin at $installedExe"
    Write-Host "Use pwsh -File scripts/odin.ps1 for the pinned compiler."
} finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
