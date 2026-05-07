# Recovery Partition Repair Tool

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)](https://learn.microsoft.com/powershell/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey?logo=windows)](https://www.microsoft.com/windows)

Interaktives PowerShell-Tool zum Reparieren falsch positionierter Recovery-Partitionen auf Windows-VMs und -Servern – mit Pfeiltasten-TUI für den Alltag und CLI-Modus für Automation.

> Maintained by [T-Alpha GmbH](https://t-alpha.ch) – Security & Operations.

---

## Das Problem

Nach dem Vergrössern einer virtuellen Disk erweitert Windows die Systempartition nicht automatisch, wenn dazwischen eine Recovery-Partition liegt:

```
[ EFI | C: | Recovery | UNALLOCATED ]
                        └── lässt sich nicht zu C: hinzufügen
```

Manueller Fix per `diskpart` ist fehleranfällig (WinRE muss vorher ausgehängt werden, GPT-Attribute müssen gesetzt sein, neue Partition braucht den richtigen Type-GUID etc.). Dieses Tool macht den Fix reproduzierbar – idempotent, mit Backup, über mehrere Hosts gleichzeitig.

## Features

- **Interaktives TUI** mit Banner, Pfeiltasten-Menü und Multi-Select
- **Klassischer CLI-Modus** für Scheduled Tasks und CI-Pipelines
- **Multi-Host** via PowerShell Remoting
- **Report-Modus** ohne Schreibzugriff (Default)
- **GPT und MBR** beide unterstützt
- **WinRE-Backup** vor jedem Eingriff (`Winre.wim` + `reagentc /info`-Snapshot)
- **WhatIf / ConfirmImpact=High** – Sicherheitsnetze nach PowerShell-Konvention
- **Idempotent** – ohne Befund passiert nichts

## Reparatur-Sequenz

1. `reagentc /disable` – kopiert `Winre.wim` nach `C:\Windows\System32\Recovery`
2. Backup von `Winre.wim` nach `BackupPath`
3. Recovery-Partition löschen (`diskpart`, `delete partition override`)
4. C: in den freigewordenen + bestehenden Unallocated Space erweitern (abzüglich Reserve)
5. Neue Recovery-Partition am Ende der Disk anlegen (GPT-GUID `de94bba4-…` bzw. MBR-ID `27`)
6. `reagentc /enable` – legt `Winre.wim` in der neuen Partition ab

## Voraussetzungen

- Windows mit PowerShell 5.1 oder höher (PowerShell 7+ funktioniert ebenfalls)
- Ausführung als Administrator (`#Requires -RunAsAdministrator`)
- Für Remote-Modus: PSRemoting aktiviert (`Enable-PSRemoting`) und Firewall offen
- VM-Snapshot oder gleichwertiges Backup **vor** dem Fix-Lauf

## Installation

```powershell
# Direkt aus dem Repo klonen
git clone https://github.com/T-Alpha/recovery-partition-repair.git
cd recovery-partition-repair

# Oder Skript einzeln herunterladen
Invoke-WebRequest `
    -Uri 'https://raw.githubusercontent.com/T-Alpha/recovery-partition-repair/main/Repair-RecoveryPartition.ps1' `
    -OutFile 'Repair-RecoveryPartition.ps1'
```

## Usage

### Interaktives TUI

```powershell
.\Repair-RecoveryPartition.ps1
```

Startet den geführten Workflow:
1. Hauptmenü (lokal / remote / Datei laden)
2. Hosts erfassen
3. Scan-Phase mit Live-Progress
4. Tabellarische Ergebnisliste
5. Multi-Select welche Hosts repariert werden
6. Bestätigung
7. Reparatur-Phase mit Live-Status
8. Final-Summary

### Klassischer Modus

```powershell
# Report über lokale Maschine
.\Repair-RecoveryPartition.ps1 -ComputerName localhost

# Report über mehrere Server
.\Repair-RecoveryPartition.ps1 -ComputerName SRV01,SRV02,SRV03

# Dry-Run vor Reparatur
.\Repair-RecoveryPartition.ps1 -ComputerName SRV01 -Fix -WhatIf

# Tatsächlich reparieren (mit Confirm-Prompt)
.\Repair-RecoveryPartition.ps1 -ComputerName SRV01 -Fix

# Eigene Reserve-Grösse für die neue Recovery-Partition
.\Repair-RecoveryPartition.ps1 -ComputerName SRV01 -Fix -RecoverySizeMB 2048
```

### Hosts aus Datei

CSV mit Spalte `ComputerName`:

```csv
ComputerName
srv01.local
srv02.local
srv03.local
```

Oder einfache TXT (eine Zeile pro Host, `#` für Kommentare).

## Parameter

| Parameter        | Default                | Beschreibung                                                             |
|------------------|------------------------|--------------------------------------------------------------------------|
| `ComputerName`   | `localhost`            | Eine oder mehrere Zielmaschinen                                          |
| `Fix`            | `$false`               | Ohne diesen Schalter nur Report                                          |
| `RecoverySizeMB` | bestehende Grösse      | Grösse der neuen Recovery-Partition                                      |
| `BackupPath`     | `C:\Temp\WinRE-Backup` | Lokaler Backup-Pfad pro Ziel                                             |
| `NoTUI`          | `$false`               | Erzwingt klassischen Modus auch ohne weitere Parameter                   |

## Sicherheit

- **Snapshot vorher.** `diskpart … delete partition override` ist destruktiv.
- **Skript bricht ab**, wenn zwischen C: und Recovery eine andere Partition steht. Es repariert nur das genau definierte Layout `[ … | C: | Recovery | UNALLOCATED ]`.
- **WinRE.wim wird zweifach gesichert**: einmal von `reagentc /disable` nach `C:\Windows\System32\Recovery`, zusätzlich ins `BackupPath`.
- **`ConfirmImpact='High'`** erzwingt einen Prompt im klassischen Modus, ausser `-Confirm:$false` wird gesetzt.

## Entwicklung

Pull Requests willkommen. Vor jedem PR bitte:

```powershell
# PSScriptAnalyzer
Invoke-ScriptAnalyzer -Path .\Repair-RecoveryPartition.ps1 -Severity Warning
```

## Lizenz

[MIT](LICENSE) © T-Alpha GmbH

## Über T-Alpha

[T-Alpha GmbH](https://t-alpha.ch) ist ein inhabergeführtes Schweizer Beratungsunternehmen für Cybersecurity, SIEM/XDR-Operations und Penetration Testing. Wir publizieren regelmässig Tools, die in unseren Mandaten entstehen.
