$ErrorActionPreference = "Stop"

$python = Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe"
if (-not (Test-Path -LiteralPath $python)) {
    throw "Python was not found at $python"
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $root

while ($true) {
    & $python -u scripts\train_yamnet_local.py --threads 1 --max-files 100
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Output "Embedding extraction, training, and export completed."
        exit 0
    }
    if ($code -ne 10 -and $code -ne 11) {
        throw "The YAMNet worker stopped with exit code $code."
    }
    Write-Output "Starting a fresh low-memory worker for the next batch..."
}
