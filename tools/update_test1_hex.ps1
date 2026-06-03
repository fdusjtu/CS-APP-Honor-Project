param(
    [string]$CondaEnv = "dsa"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DebugDir = Join-Path $RepoRoot "fpga\test1\Debug"
$HexdumpDir = Join-Path $RepoRoot "fpga\hexdump"

$SrcBin = Join-Path $DebugDir "test1.bin"
$DstBin = Join-Path $HexdumpDir "test1.bin"
$HexdumpExe = Join-Path $HexdumpDir "hexdump.exe"
$OutputPy = Join-Path $HexdumpDir "output.py"
$HexOut = Join-Path $HexdumpDir "test1.hex"
$FinalHex = Join-Path $HexdumpDir "test2.hex"

if (!(Test-Path -LiteralPath $SrcBin)) {
    throw "Missing firmware binary: $SrcBin"
}
if (!(Test-Path -LiteralPath $HexdumpExe)) {
    throw "Missing hexdump.exe: $HexdumpExe"
}
if (!(Test-Path -LiteralPath $OutputPy)) {
    throw "Missing output.py: $OutputPy"
}

$CondaCmd = Get-Command conda -ErrorAction SilentlyContinue
if ($null -eq $CondaCmd) {
    throw "conda was not found in PATH"
}

Copy-Item -LiteralPath $SrcBin -Destination $DstBin -Force

Push-Location $HexdumpDir
try {
    $HexLines = & $HexdumpExe -O .\test1.bin |
        ForEach-Object { $_ -replace '\s+', "`n" }
    [System.IO.File]::WriteAllLines($HexOut, [string[]]$HexLines, [System.Text.Encoding]::ASCII)

    conda run -n $CondaEnv python .\output.py
}
finally {
    Pop-Location
}

if (!(Test-Path -LiteralPath $FinalHex)) {
    throw "output.py did not produce expected file: $FinalHex"
}

Write-Host "Updated:"
Write-Host "  $DstBin"
Write-Host "  $HexOut"
Write-Host "  $FinalHex"
