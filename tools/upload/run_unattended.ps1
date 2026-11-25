# Windows twin of run_unattended.sh: runs the gated image uploader and commits/pushes its results file every
# 10 minutes. Resumable: re-run after any stop.
#   powershell -File tools/upload/run_unattended.ps1 -UserId <id> [-Jobs 6] [-Batch 100] [-Session Claude-Name]
# The key is read from ROBLOX_API_KEY (this process, else the Windows user variable). It is never printed.
# Output: work/upload/run.log (+ run.err.log). The uploader stops by itself on Rejected, a 403, upload errors,
# or anything still in review after 45 min.
param(
    [Parameter(Mandatory = $true)][string]$UserId,
    [int]$Jobs = 6,
    [int]$Batch = 100,
    [string]$Session = "Claude-Quartz",
    [string]$Task = "UPLOAD-FIX4"
)
Set-Location (Join-Path $PSScriptRoot "..\..")
if (-not $env:ROBLOX_API_KEY) {
    $env:ROBLOX_API_KEY = [Environment]::GetEnvironmentVariable("ROBLOX_API_KEY", "User")
}
if (-not $env:ROBLOX_API_KEY) {
    Write-Output "ROBLOX_API_KEY is not set - nothing uploaded"
    exit 2
}
$env:PYTHONUTF8 = "1"
$ids = "assets/manifest/roblox-images.tsv"
$log = "work/upload/run.log"
$p = Start-Process python -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError "work/upload/run.err.log" `
    -ArgumentList "-u", "tools/upload/upload_images.py", "--user-id", $UserId, "--jobs", $Jobs, "--batch", $Batch

function Save-Progress {
    $ok = @(Select-String -Path $ids -Pattern "`tok`t" -SimpleMatch).Count
    git add $ids
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        git commit -q -m "$Task [$Session] texture upload progress ($ok ok)" -m "Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>"
        git push -q
    }
}

while (-not $p.HasExited) {
    for ($i = 0; $i -lt 60 -and -not $p.HasExited; $i++) { Start-Sleep -Seconds 10 }
    Save-Progress
}
Save-Progress
$ok = @(Select-String -Path $ids -Pattern "`tok`t" -SimpleMatch).Count
Write-Output "unattended run finished: $ok ok. Last lines of ${log}:"
Get-Content $log -Tail 5
