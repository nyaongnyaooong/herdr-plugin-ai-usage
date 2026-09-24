$ErrorActionPreference = "Stop"
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pluginRoot = Split-Path -Parent $scriptDir

function Find-Python {
    $candidates = @()
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notmatch "WindowsApps") {
        $candidates += $cmd.Source
    }
    $candidates += @(
        (Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"),
        "C:\QMK_MSYS\ucrt64\bin\python.exe"
    )
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        & $path -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)"
        if ($LASTEXITCODE -eq 0) { return $path }
    }
    throw "Python 3.9+ was not found"
}

$python = Find-Python
$runner = Join-Path $scriptDir "ai-usage.py"
$command = if ($args.Count -gt 0) { $args[0] } else { "dashboard" }

if ($command -eq "watch-start") {
    $state = $env:HERDR_PLUGIN_STATE_DIR
    if (-not $state) { $state = Join-Path $pluginRoot ".state" }
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    $pidFile = Join-Path $state "watch.pid"
    if (Test-Path -LiteralPath $pidFile) {
        $old = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($old -match "^\d+$") {
            Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue
        }
    }
    $stdout = Join-Path $state "watch.log"
    $stderr = Join-Path $state "watch.err"
    $proc = Start-Process -FilePath $python -ArgumentList @($runner, "watch") -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    Set-Content -LiteralPath $pidFile -Value $proc.Id -Encoding ascii
    exit 0
}

& $python $runner @args
exit $LASTEXITCODE
