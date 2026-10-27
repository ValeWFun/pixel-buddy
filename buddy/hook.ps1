# Hook-Seite des Pixel-Buddy. Wird vom Mod (hooks/register.ts) aufgerufen, die Anfrage als JSON auf stdin:
#   -Mode permission  (PermissionRequest) Frage als Sprechblase zeigen und auf deinen Klick warten
#   -Mode notify      (Stop)              kurz Bescheid geben, dass Claude fertig ist
#   -Mode ensure      (SessionStart)      Figürchen starten, falls es noch nicht läuft
# Keine Ausgabe = Claude Code fragt ganz normal im Chat nach.
param([string]$Mode = 'permission')

$ErrorActionPreference = 'Stop'
$BuddyDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir    = Join-Path $env:LOCALAPPDATA 'PixelBuddy'   # Warteschlange und Log
$Queue      = Join-Path $DataDir 'queue'
$LogFile    = Join-Path $DataDir 'buddy.log'
$TimeoutSec = 120   # danach fällt die Frage zurück in den Chat

function Write-Log($msg) {
    try { Add-Content -Path $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  [hook] {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

function Test-Buddy {
    $m = $null
    if ([Threading.Mutex]::TryOpenExisting('Local\PixelBuddy', [ref]$m)) { $m.Dispose(); return $true }
    $false
}

function Start-Buddy {
    if (Test-Buddy) { return $true }
    $pwsh = (Get-Process -Id $PID).Path
    Start-Process -FilePath $pwsh -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f (Join-Path $BuddyDir 'buddy.ps1')))
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 150
        if (Test-Buddy) { return $true }
    }
    $false
}

function Send-Request([string]$id, $data) {
    New-Item -ItemType Directory -Force $Queue | Out-Null
    $tmp = Join-Path $Queue "$id.reqtmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json $data -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -Force $tmp (Join-Path $Queue "$id.req.json")
}

function Get-ProjectName($cwd) {
    if (-not $cwd) { return 'Claude Code' }
    $name = Split-Path -Leaf $cwd
    if ($name -match '^scratch-') { 'Claude Code' } else { $name }
}

try {
    [Console]::InputEncoding  = [Text.Encoding]::UTF8
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

    if ($Mode -eq 'ensure') { Start-Buddy | Out-Null; exit 0 }

    $req = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $project = Get-ProjectName $req.cwd

    if ($Mode -eq 'notify') {
        if (Test-Buddy) {
            Send-Request ([guid]::NewGuid().ToString('N')) @{ kind = 'notify'; title = $project; subtitle = 'Claude ist fertig ' + [char]0x2713 }
        }
        exit 0
    }

    $tool = [string]$req.tool_name
    # Rückfragen und Pläne brauchen deine Antwort im Chat selbst
    if ($tool -in @('AskUserQuestion', 'ExitPlanMode')) { exit 0 }

    # --- Was will Claude tun? ---
    $in = $req.tool_input
    switch -Regex ($tool) {
        '^(Bash|PowerShell)$' { $action = 'möchte einen Befehl ausführen'; $detail = [string]$in.command
                                if ($in.description) { $detail = "# $($in.description)`r`n$detail" } }
        '^(Edit|MultiEdit)$'  { $action = 'möchte eine Datei bearbeiten';  $detail = [string]$in.file_path }
        '^Write$'             { $action = 'möchte eine Datei schreiben';   $detail = [string]$in.file_path }
        '^Read$'              { $action = 'möchte eine Datei lesen';       $detail = [string]$in.file_path }
        '^NotebookEdit$'      { $action = 'möchte ein Notebook bearbeiten'; $detail = [string]$in.notebook_path }
        '^WebFetch$'          { $action = 'möchte eine Webseite abrufen';  $detail = [string]$in.url }
        '^WebSearch$'         { $action = 'möchte im Web suchen';          $detail = [string]$in.query }
        '^mcp__'              { $parts = $tool -split '__'
                                $action = "möchte $($parts[-1]) nutzen ($($parts[1]))"
                                $detail = ($in | ConvertTo-Json -Depth 6 -Compress) }
        default               { $action = "möchte $tool nutzen"
                                $detail = ($in | ConvertTo-Json -Depth 6 -Compress) }
    }
    if (-not $detail) { $detail = '(keine Details)' }
    if ($detail.Length -gt 2000) { $detail = $detail.Substring(0, 2000) + ' …' }
    $detail = $detail -replace "(?<!`r)`n", "`r`n"
    $suggestions = @($req.permission_suggestions | Where-Object { $_ })

    if (-not (Start-Buddy)) { Write-Log 'Buddy startet nicht - Frage geht in den Chat'; exit 0 }

    $id = [guid]::NewGuid().ToString('N')
    Send-Request $id @{
        kind = 'permission'; title = $project; subtitle = $action; detail = $detail
        canAlways = ($suggestions.Count -gt 0); timeout = $TimeoutSec
    }

    $resFile = Join-Path $Queue "$id.res.json"
    $choice = 'chat'
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $resFile) {
            $choice = [string](Get-Content $resFile -Raw | ConvertFrom-Json).choice
            break
        }
        if (-not (Test-Buddy)) { break }   # Figürchen wurde beendet
        Start-Sleep -Milliseconds 150
    }
    Remove-Item $resFile, (Join-Path $Queue "$id.req.json") -ErrorAction SilentlyContinue

    # --- Antwort an Claude Code ---
    $decision = switch ($choice) {
        'allow'  { @{ behavior = 'allow' } }
        'always' { @{ behavior = 'allow'; updatedPermissions = $suggestions } }
        'deny'   { @{ behavior = 'deny'; message = 'Im Buddy abgelehnt.' } }
        default  { $null }
    }
    Write-Log "$tool -> $choice"
    if ($decision) {
        $out = @{ hookSpecificOutput = @{ hookEventName = 'PermissionRequest'; decision = $decision } }
        [Console]::Out.Write((ConvertTo-Json -InputObject $out -Depth 12 -Compress))
    }
    exit 0
} catch {
    # Im Fehlerfall nie blockieren: Claude Code fragt dann einfach im Chat
    Write-Log "FEHLER: $($_.Exception.Message)"
    exit 0
}
