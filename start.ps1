param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8765,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$url = "http://127.0.0.1:$Port/"
$python = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'

function Test-PhotoMgr {
    try {
        $state = Invoke-RestMethod -Uri ($url + 'api/batches') -TimeoutSec 2
        return ($null -ne $state.PSObject.Properties['batches'] -and
                $null -ne $state.PSObject.Properties['token'])
    } catch {
        return $false
    }
}

try {
    if (-not (Test-PhotoMgr)) {
        if (-not (Test-Path -LiteralPath $python)) {
            $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
            if ($launcher) {
                & $launcher.Source -3.14 -c 'import sys; raise SystemExit(sys.version_info[:2] != (3,14))'
            }
            if ($launcher -and $LASTEXITCODE -eq 0) {
                & $launcher.Source -3.14 -m venv .venv
            } else {
                $systemPython = Get-Command python.exe -ErrorAction SilentlyContinue
                if (-not $systemPython) { throw 'Install Python 3.14 for Windows from https://www.python.org/downloads/windows/ and run this launcher again.' }
                & $systemPython.Source -c 'import sys; raise SystemExit(sys.version_info[:2] != (3,14))'
                if ($LASTEXITCODE -ne 0) { throw 'Python 3.14 is required. Install it from https://www.python.org/downloads/windows/ and run this launcher again.' }
                & $systemPython.Source -m venv .venv
            }
            if ($LASTEXITCODE -ne 0) { throw 'Could not create .venv.' }
        }

        $fingerprint = & $python -c "import hashlib; from pathlib import Path; print(hashlib.sha256(Path('requirements.txt').read_bytes()).hexdigest())"
        if ($LASTEXITCODE -ne 0) { throw 'Could not read requirements.txt.' }
        $marker = '.venv\requirements.sha256'
        if (!(Test-Path -LiteralPath $marker) -or (Get-Content -LiteralPath $marker -Raw).Trim() -ne $fingerprint) {
            Write-Host 'Installing PhotoMgr dependencies...'
            & $python -m pip install --disable-pip-version-check -r requirements.txt
            if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed. Check access to your Python package index and try again.' }
            Set-Content -LiteralPath $marker -Value $fingerprint -Encoding ascii
        }

        New-Item -ItemType Directory -Path '.data' -Force | Out-Null
        $server = Start-Process -FilePath $python -ArgumentList @('photo_review.py', 'serve', '--port', $Port) `
            -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput '.data\server.log' -RedirectStandardError '.data\server-errors.log'
        $ready = $false
        for ($attempt = 0; $attempt -lt 12; $attempt++) {
            if (Test-PhotoMgr) { $ready = $true; break }
            if ($server.HasExited) { break }
            Start-Sleep -Milliseconds 350
        }
        if (-not $ready) {
            if (Test-Path -LiteralPath '.data\server-errors.log') {
                Get-Content -LiteralPath '.data\server-errors.log' -Tail 12
            }
            throw "PhotoMgr could not start on port $Port. If the port is occupied, try .\start.ps1 -Port 8766."
        }
    }
    Write-Host "PhotoMgr is ready at $url"
    if (-not $NoBrowser) { Start-Process $url }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
