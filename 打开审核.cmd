@echo off
cd /d "%~dp0"
powershell -NoProfile -Command "$url='http://127.0.0.1:8765/'; try { $null=Invoke-RestMethod ($url+'api/project') -TimeoutSec 1 } catch { Start-Process python -ArgumentList 'photo_review.py','serve' -WindowStyle Hidden }; for($i=0;$i -lt 10;$i++){ try { $null=Invoke-RestMethod ($url+'api/project') -TimeoutSec 1; Start-Process $url; exit 0 } catch { Start-Sleep -Milliseconds 300 } }; exit 1"
if errorlevel 1 pause
