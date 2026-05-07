#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Interaktives TUI-Tool zum Reparieren falsch positionierter Recovery-
    Partitionen auf Windows-VMs und -Servern.

.DESCRIPTION
    Erkennt das typische Szenario, bei dem eine Recovery-Partition zwischen
    der C:-Partition und freiem (unallocated) Speicherplatz liegt und damit
    eine Erweiterung von C: blockiert.

    Reparatur-Sequenz:
      1. WinRE deaktivieren (kopiert Winre.wim nach C:\Windows\System32\Recovery)
      2. Sicherung von Winre.wim ins BackupPath
      3. Recovery-Partition löschen (diskpart, override)
      4. C: in den freigewordenen + bestehenden Unallocated Space erweitern
         (abzüglich Reserve für neue Recovery-Partition)
      5. Neue Recovery-Partition am Ende des Datenträgers anlegen (GPT oder MBR)
      6. WinRE wieder aktivieren – legt Winre.wim in der neuen Partition ab

.PARAMETER ComputerName
    Eine oder mehrere Zielmaschinen. Default: localhost.
    Wird ein Parameter angegeben, läuft das Skript im klassischen Modus
    (ohne TUI) – ideal für Automation/Scheduled Tasks.

.PARAMETER Fix
    Ohne diesen Schalter läuft das Skript nur als Report.

.PARAMETER RecoverySizeMB
    Grösse der neu anzulegenden Recovery-Partition.
    Default: Grösse der bestehenden Recovery-Partition (sonst 1024 MB).

.PARAMETER BackupPath
    Lokaler Backup-Pfad auf dem Ziel. Default: C:\Temp\WinRE-Backup

.PARAMETER NoTUI
    Erzwingt den klassischen Modus auch ohne weitere Parameter.

.EXAMPLE
    .\Repair-RecoveryPartition.ps1
    Startet das interaktive TUI.

.EXAMPLE
    .\Repair-RecoveryPartition.ps1 -ComputerName SRV01,SRV02
    Klassischer Report-Modus über mehrere Server via PSRemoting.

.EXAMPLE
    .\Repair-RecoveryPartition.ps1 -ComputerName SRV01 -Fix -Verbose
    Reparatur ausführen mit Bestätigungs-Prompt.

.NOTES
    Author  : T-Alpha GmbH / Ivan Stricker
    Project : https://github.com/T-Alpha/recovery-partition-repair
    License : MIT
    Caveat  : Vorher Snapshot/Backup der VM nehmen. diskpart-Operationen
              sind destruktiv. Skript ist idempotent: ohne Befund -> noop.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string[]]$ComputerName,
    [switch]  $Fix,
    [int]     $RecoverySizeMB = 0,
    [string]  $BackupPath     = 'C:\Temp\WinRE-Backup',
    [switch]  $NoTUI
)

# ============================================================================
# TUI HELPERS
# ============================================================================

$Script:Theme = @{
    Primary = 'Cyan'
    Accent  = 'Magenta'
    Success = 'Green'
    Warning = 'Yellow'
    Danger  = 'Red'
    Muted   = 'DarkGray'
    Text    = 'White'
}

function Show-Banner {
    Clear-Host
    $banner = @'
  ╔══════════════════════════════════════════════════════════════════╗
  ║                                                                  ║
  ║     ████████╗     █████╗ ██╗     ██████╗ ██╗  ██╗ █████╗         ║
  ║     ╚══██╔══╝    ██╔══██╗██║     ██╔══██╗██║  ██║██╔══██╗        ║
  ║        ██║       ███████║██║     ██████╔╝███████║███████║        ║
  ║        ██║       ██╔══██║██║     ██╔═══╝ ██╔══██║██╔══██║        ║
  ║        ██║       ██║  ██║███████╗██║     ██║  ██║██║  ██║        ║
  ║        ╚═╝       ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝        ║
  ║                                                                  ║
  ║         R E C O V E R Y   P A R T I T I O N   R E P A I R        ║
  ║                                                                  ║
  ╚══════════════════════════════════════════════════════════════════╝
'@
    Write-Host $banner -ForegroundColor $Script:Theme.Primary
    Write-Host "                              v1.0.0 · T-Alpha GmbH" -ForegroundColor $Script:Theme.Muted
    Write-Host ""
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor $Script:Theme.Accent
    Write-Host ("  " + ("─" * 64)) -ForegroundColor $Script:Theme.Muted
}

function Write-Status {
    param([string]$Msg, [ValidateSet('OK','Warn','Err','Info','Run')]$Lvl = 'Info')
    $icon, $color = switch ($Lvl) {
        'OK'   { '✓', $Script:Theme.Success }
        'Warn' { '⚠', $Script:Theme.Warning }
        'Err'  { '✗', $Script:Theme.Danger  }
        'Run'  { '▸', $Script:Theme.Primary }
        default { '·', $Script:Theme.Text   }
    }
    Write-Host "  $icon $Msg" -ForegroundColor $color
}

function Show-Menu {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Options,
        [string[]]$Hints,
        [int]$DefaultIndex = 0
    )

    $selected = $DefaultIndex
    [Console]::CursorVisible = $false
    $startTop = [Console]::CursorTop

    try {
        while ($true) {
            [Console]::SetCursorPosition(0, $startTop)

            # Render header
            Write-Host "  $Title" -ForegroundColor $Script:Theme.Accent
            Write-Host ("  " + ("─" * 64)) -ForegroundColor $Script:Theme.Muted

            for ($i = 0; $i -lt $Options.Count; $i++) {
                $hint = if ($Hints -and $i -lt $Hints.Count) { "  $($Hints[$i])" } else { '' }
                $line = "    {0,-32}{1}" -f $Options[$i], $hint
                if ($i -eq $selected) {
                    Write-Host ("  ▸$line".Substring(2)) -ForegroundColor $Script:Theme.Primary
                } else {
                    Write-Host $line -ForegroundColor $Script:Theme.Text
                }
            }

            Write-Host ""
            Write-Host "    ↑↓ Navigieren · Enter Auswählen · Q Beenden" -ForegroundColor $Script:Theme.Muted

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($selected -gt 0) { $selected-- } }
                'DownArrow' { if ($selected -lt ($Options.Count - 1)) { $selected++ } }
                'Enter'     { return $selected }
                'Q'         { return -1 }
                'Escape'    { return -1 }
            }
        }
    } finally {
        [Console]::CursorVisible = $true
    }
}

function Show-MultiSelect {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [scriptblock]$Display = { param($x) "$x" },
        [bool[]]$InitialSelection
    )

    $selected = if ($InitialSelection -and $InitialSelection.Count -eq $Items.Count) {
        $InitialSelection.Clone()
    } else {
        New-Object bool[] $Items.Count
    }
    $cursor = 0
    [Console]::CursorVisible = $false
    $startTop = [Console]::CursorTop

    try {
        while ($true) {
            [Console]::SetCursorPosition(0, $startTop)

            Write-Host "  $Title" -ForegroundColor $Script:Theme.Accent
            Write-Host ("  " + ("─" * 64)) -ForegroundColor $Script:Theme.Muted

            for ($i = 0; $i -lt $Items.Count; $i++) {
                $mark   = if ($selected[$i]) { '[✓]' } else { '[ ]' }
                $label  = & $Display $Items[$i]
                $prefix = if ($i -eq $cursor) { '  ▸ ' } else { '    ' }
                $color  =
                    if ($i -eq $cursor)         { $Script:Theme.Primary }
                    elseif ($selected[$i])      { $Script:Theme.Success }
                    else                        { $Script:Theme.Text }
                Write-Host ("$prefix$mark $label") -ForegroundColor $color
            }

            Write-Host ""
            Write-Host "    ↑↓ Navigieren · Space Toggle · A Alle · Enter OK · Q Abbrechen" -ForegroundColor $Script:Theme.Muted

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt ($Items.Count - 1)) { $cursor++ } }
                'Spacebar'  { $selected[$cursor] = -not $selected[$cursor] }
                'A'         {
                    $allOn = -not ($selected -contains $false)
                    for ($j = 0; $j -lt $selected.Count; $j++) { $selected[$j] = -not $allOn }
                }
                'Enter'     {
                    $out = @()
                    for ($k = 0; $k -lt $Items.Count; $k++) {
                        if ($selected[$k]) { $out += $Items[$k] }
                    }
                    return ,$out
                }
                'Q'         { return $null }
                'Escape'    { return $null }
            }
        }
    } finally {
        [Console]::CursorVisible = $true
    }
}

function Read-Styled {
    param([string]$Prompt, [string]$Default)
    $hint = if ($Default) { " [$Default]" } else { '' }
    Write-Host "  ▸ $Prompt$hint`: " -ForegroundColor $Script:Theme.Accent -NoNewline
    $input = Read-Host
    if ([string]::IsNullOrWhiteSpace($input) -and $Default) { return $Default }
    return $input
}

function Confirm-Styled {
    param([string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { '[J/n]' } else { '[j/N]' }
    Write-Host ""
    Write-Host "  ? $Prompt $hint " -ForegroundColor $Script:Theme.Warning -NoNewline
    $a = Read-Host
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return ($a -match '^(j|y|ja|yes)$')
}

function Show-ResultsTable {
    param([object[]]$Results)

    Write-Section "Scan-Ergebnisse"

    $fmt = "  {0,-2} {1,-22} {2,-12} {3,-10} {4}"
    Write-Host ($fmt -f '', 'Computer', 'Status', 'Action', 'Reason') -ForegroundColor $Script:Theme.Muted
    Write-Host ("  " + ("─" * 64)) -ForegroundColor $Script:Theme.Muted

    foreach ($r in $Results) {
        $icon, $color = switch ($r.Action) {
            'None'       { '✓', $Script:Theme.Success }
            'ReportOnly' { '⚠', $Script:Theme.Warning }
            'Fixed'      { '✓', $Script:Theme.Success }
            'Error'      { '✗', $Script:Theme.Danger  }
            default      { '·', $Script:Theme.Text }
        }
        $status = if ($r.NeedsFix -eq $true)  { 'Repair'  }
                  elseif ($r.NeedsFix -eq $false) { 'OK' }
                  else { 'Error' }
        Write-Host ($fmt -f $icon, $r.Computer, $status, $r.Action, $r.Reason) -ForegroundColor $color
    }
    Write-Host ""
}

# ============================================================================
# WORKER (lokal oder via Invoke-Command)
# ============================================================================

$Worker = {
    param($Fix, $RecoverySizeMB, $BackupPath)

    function Write-WLog {
        param([string]$Msg, [string]$Lvl = 'INFO')
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Write-Verbose "[$ts][$env:COMPUTERNAME][$Lvl] $Msg" -Verbose
    }

    function Invoke-Diskpart {
        param([string]$Script)
        $tmp = New-TemporaryFile
        Set-Content -Path $tmp -Value $Script -Encoding ASCII
        try {
            $out = & diskpart.exe /s $tmp.FullName 2>&1
            $out | ForEach-Object { Write-WLog "diskpart: $_" }
            if ($LASTEXITCODE -ne 0) { throw "diskpart exit code $LASTEXITCODE" }
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    Write-WLog "Starte Partitions-Layout-Check"

    try {
        $osPart = Get-Partition -DriveLetter C -ErrorAction Stop
    } catch {
        return [pscustomobject]@{
            Computer = $env:COMPUTERNAME; NeedsFix = $null
            Reason = "C: nicht gefunden: $_"; Action = 'Error'
        }
    }

    $diskNo = $osPart.DiskNumber
    $disk   = Get-Disk -Number $diskNo
    Write-WLog ("OS-Disk {0} ({1}), {2} GB, {3}" -f `
        $diskNo, $disk.FriendlyName, [math]::Round($disk.Size/1GB,2), $disk.PartitionStyle)

    $parts        = Get-Partition -DiskNumber $diskNo | Sort-Object Offset
    $afterC       = $parts | Where-Object { $_.Offset -gt $osPart.Offset } | Sort-Object Offset
    $last         = $parts | Select-Object -Last 1
    $unallocated  = $disk.Size - ($last.Offset + $last.Size)
    $unallocMB    = [math]::Round($unallocated / 1MB, 2)

    $recovery = $afterC | Where-Object { $_.Type -eq 'Recovery' } | Select-Object -First 1

    if (-not $recovery) {
        return [pscustomobject]@{
            Computer = $env:COMPUTERNAME; NeedsFix = $false
            Reason = 'Keine Recovery nach C:'; UnallocatedMB = $unallocMB
            Action = 'None'
        }
    }
    if ($unallocated -lt 100MB) {
        return [pscustomobject]@{
            Computer = $env:COMPUTERNAME; NeedsFix = $false
            Reason = 'Kein Unallocated nach Recovery'; UnallocatedMB = $unallocMB
            Action = 'None'
        }
    }

    $recoveryMB = [math]::Round($recovery.Size / 1MB, 2)

    if (-not $Fix) {
        return [pscustomobject]@{
            Computer = $env:COMPUTERNAME; NeedsFix = $true
            Reason = 'Recovery zwischen C: und Unallocated'
            RecoveryPart = $recovery.PartitionNumber
            RecoverySizeMB = $recoveryMB; UnallocatedMB = $unallocMB
            Action = 'ReportOnly'
        }
    }

    # ---- REPAIR ----
    Write-WLog "Starte Reparatur" 'WARN'

    if ($RecoverySizeMB -le 0) {
        $RecoverySizeMB = [int][math]::Ceiling($recoveryMB)
    }

    if (-not (Test-Path $BackupPath)) {
        New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    }

    & reagentc.exe /info 2>&1 | Out-File "$BackupPath\reagentc-pre.txt" -Encoding utf8

    Write-WLog "Deaktiviere WinRE"
    & reagentc.exe /disable 2>&1 | ForEach-Object { Write-WLog $_ }

    $winreSrc = "$env:SystemRoot\System32\Recovery\Winre.wim"
    if (Test-Path $winreSrc) {
        Copy-Item $winreSrc -Destination "$BackupPath\Winre.wim" -Force
        Write-WLog "Winre.wim gesichert"
    }

    Write-WLog "Lösche Recovery-Partition #$($recovery.PartitionNumber)"
    Invoke-Diskpart @"
select disk $diskNo
select partition $($recovery.PartitionNumber)
delete partition override
exit
"@

    Start-Sleep -Seconds 2
    Update-Disk -Number $diskNo -ErrorAction SilentlyContinue

    $supported  = Get-PartitionSupportedSize -DriveLetter C
    $targetSize = $supported.SizeMax - ($RecoverySizeMB * 1MB)
    Write-WLog ("Erweitere C: auf {0} GB" -f [math]::Round($targetSize/1GB,2))
    Resize-Partition -DriveLetter C -Size $targetSize -ErrorAction Stop

    Write-WLog "Erstelle neue Recovery-Partition ($RecoverySizeMB MB)"
    if ($disk.PartitionStyle -eq 'GPT') {
        $createScript = @"
select disk $diskNo
create partition primary size=$RecoverySizeMB id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
gpt attributes=0x8000000000000001
format quick fs=ntfs label="Recovery"
exit
"@
    } else {
        $createScript = @"
select disk $diskNo
create partition primary size=$RecoverySizeMB
format quick fs=ntfs label="Recovery"
set id=27
exit
"@
    }
    Invoke-Diskpart $createScript

    Write-WLog "Aktiviere WinRE"
    & reagentc.exe /enable 2>&1 | ForEach-Object { Write-WLog $_ }

    $newC = Get-Partition -DiskNumber $diskNo | Where-Object DriveLetter -eq 'C'
    return [pscustomobject]@{
        Computer       = $env:COMPUTERNAME
        NeedsFix       = $true
        Reason         = 'Repaired'
        RecoverySizeMB = $RecoverySizeMB
        NewCSizeGB     = [math]::Round($newC.Size / 1GB, 2)
        Action         = 'Fixed'
    }
}

# ============================================================================
# DISPATCHER (gemeinsam für TUI- und Klassik-Modus)
# ============================================================================

function Invoke-PartitionWorker {
    param(
        [Parameter(Mandatory)][string[]]$Targets,
        [bool]$DoFix,
        [int]$RecoverySize,
        [string]$Backup
    )

    $results = New-Object System.Collections.Generic.List[object]
    $total   = $Targets.Count
    $idx     = 0

    foreach ($cn in $Targets) {
        $idx++
        $isLocal = ($cn -eq $env:COMPUTERNAME) -or ($cn -eq 'localhost') -or ($cn -eq '.')
        $action  = if ($DoFix) { 'Repariere' } else { 'Scanne' }

        Write-Progress -Activity "Recovery-Partition Tool" `
                       -Status "$action $cn ($idx/$total)" `
                       -PercentComplete (($idx / $total) * 100)
        Write-Status "$action $cn ..." 'Run'

        try {
            if ($isLocal) {
                $r = & $Worker $DoFix $RecoverySize $Backup
            } else {
                $r = Invoke-Command -ComputerName $cn -ScriptBlock $Worker `
                                    -ArgumentList $DoFix, $RecoverySize, $Backup `
                                    -ErrorAction Stop
            }
            if ($r) { $results.Add($r) }
        } catch {
            Write-Status "[$cn] Fehler: $_" 'Err'
            $results.Add([pscustomobject]@{
                Computer = $cn; NeedsFix = $null
                Reason = "Error: $_"; Action = 'Error'
            })
        }
    }
    Write-Progress -Activity "Recovery-Partition Tool" -Completed
    return ,$results.ToArray()
}

# ============================================================================
# TUI WORKFLOW
# ============================================================================

function Start-TUI {
    Show-Banner

    while ($true) {
        $choice = Show-Menu -Title 'Hauptmenü' -Options @(
            'Lokales System scannen',
            'Remote-Hosts scannen',
            'Hosts aus Datei laden',
            'Über dieses Tool',
            'Beenden'
        ) -Hints @(
            'Quick-Check des aktuellen Systems',
            'Mehrere Hosts via PSRemoting',
            'CSV/TXT mit einer Spalte ComputerName',
            'Version, Lizenz, Repository',
            'Tool verlassen'
        )

        switch ($choice) {
            0 { Invoke-TUI-Workflow -Targets @($env:COMPUTERNAME) }
            1 {
                Show-Banner
                Write-Section "Remote-Hosts eingeben"
                $raw = Read-Styled -Prompt "Hostnamen (komma-separiert)"
                if (-not $raw) { continue }
                $hosts = $raw -split '\s*,\s*' | Where-Object { $_ }
                Invoke-TUI-Workflow -Targets $hosts
            }
            2 {
                Show-Banner
                Write-Section "Host-Datei laden"
                $path = Read-Styled -Prompt "Pfad zur Datei"
                if (-not (Test-Path $path)) {
                    Write-Status "Datei nicht gefunden" 'Err'
                    Read-Host "  Enter zum Fortfahren"
                    continue
                }
                $hosts = if ($path -match '\.csv$') {
                    (Import-Csv $path).ComputerName
                } else {
                    Get-Content $path | Where-Object { $_ -and $_ -notmatch '^\s*#' }
                }
                Invoke-TUI-Workflow -Targets $hosts
            }
            3 {
                Show-Banner
                Write-Section "Über"
                Write-Host "  T-Alpha Recovery Partition Repair Tool" -ForegroundColor $Script:Theme.Text
                Write-Host "  Version  : 1.0.0" -ForegroundColor $Script:Theme.Muted
                Write-Host "  Author   : Ivan Stricker · T-Alpha GmbH" -ForegroundColor $Script:Theme.Muted
                Write-Host "  License  : MIT" -ForegroundColor $Script:Theme.Muted
                Write-Host "  Repo     : github.com/T-Alpha/recovery-partition-repair" -ForegroundColor $Script:Theme.Muted
                Write-Host ""
                Read-Host "  Enter zum Fortfahren" | Out-Null
            }
            default {
                Write-Host ""
                Write-Status "Bye." 'OK'
                return
            }
        }
    }
}

function Invoke-TUI-Workflow {
    param([string[]]$Targets)

    Show-Banner
    Write-Section "Phase 1 · Scan"
    foreach ($t in $Targets) { Write-Status "Ziel: $t" 'Info' }
    Write-Host ""

    # Scan
    $results = Invoke-PartitionWorker -Targets $Targets -DoFix $false `
                                      -RecoverySize 0 -Backup $BackupPath

    Show-ResultsTable -Results $results

    $needsFix = $results | Where-Object { $_.NeedsFix -eq $true }
    if (-not $needsFix) {
        Write-Status "Alle Systeme sauber – nichts zu reparieren." 'OK'
        Write-Host ""
        Read-Host "  Enter zum Fortfahren" | Out-Null
        return
    }

    Write-Section "Phase 2 · Reparatur-Auswahl"
    Write-Host "  $($needsFix.Count) System(e) brauchen Reparatur." -ForegroundColor $Script:Theme.Warning
    Write-Host ""

    $picks = Show-MultiSelect `
        -Title "Welche Systeme reparieren?" `
        -Items $needsFix `
        -Display { param($x) "{0,-22} ({1} MB Recovery, {2} MB unalloc.)" -f $x.Computer, $x.RecoverySizeMB, $x.UnallocatedMB }

    if (-not $picks -or $picks.Count -eq 0) {
        Write-Status "Keine Auswahl – kehre zurück." 'Info'
        Read-Host "  Enter zum Fortfahren" | Out-Null
        return
    }

    Show-Banner
    Write-Section "Phase 3 · Bestätigung"
    Write-Host "  Folgende Systeme werden REPARIERT:" -ForegroundColor $Script:Theme.Warning
    foreach ($p in $picks) {
        Write-Host ("    • {0}" -f $p.Computer) -ForegroundColor $Script:Theme.Text
    }
    Write-Host ""
    Write-Status "Diese Operation ist destruktiv. VM-Snapshots werden empfohlen." 'Warn'

    if (-not (Confirm-Styled -Prompt "Reparatur jetzt starten?" -Default $false)) {
        Write-Status "Abgebrochen." 'Info'
        Read-Host "  Enter zum Fortfahren" | Out-Null
        return
    }

    Write-Section "Phase 4 · Reparatur"
    $repairTargets = $picks | ForEach-Object { $_.Computer }
    $fixResults = Invoke-PartitionWorker -Targets $repairTargets -DoFix $true `
                                         -RecoverySize $RecoverySizeMB -Backup $BackupPath

    Show-ResultsTable -Results $fixResults

    $ok = ($fixResults | Where-Object { $_.Action -eq 'Fixed' }).Count
    $err = ($fixResults | Where-Object { $_.Action -eq 'Error' }).Count
    Write-Host ""
    Write-Status "$ok repariert · $err Fehler" $(if ($err) { 'Warn' } else { 'OK' })
    Write-Host ""
    Read-Host "  Enter zum Fortfahren" | Out-Null
}

# ============================================================================
# ENTRY POINT
# ============================================================================

# Klassischer Modus: wenn explizit Parameter gesetzt sind oder NoTUI
$useTUI = -not $NoTUI -and -not $ComputerName -and -not $Fix.IsPresent

if ($useTUI) {
    Start-TUI
} else {
    if (-not $ComputerName) { $ComputerName = @($env:COMPUTERNAME) }

    Write-Host ""
    Write-Status "Klassischer Modus – $($ComputerName.Count) Ziel(e)" 'Run'

    foreach ($cn in $ComputerName) {
        if ($Fix -and -not $PSCmdlet.ShouldProcess($cn, 'Recovery-Partition reparieren')) {
            continue
        }
    }

    $results = Invoke-PartitionWorker -Targets $ComputerName `
                                      -DoFix $Fix.IsPresent `
                                      -RecoverySize $RecoverySizeMB `
                                      -Backup $BackupPath
    Show-ResultsTable -Results $results
    return $results
}
