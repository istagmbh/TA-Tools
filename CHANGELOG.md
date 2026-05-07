# Changelog

Alle nennenswerten Änderungen werden hier dokumentiert.
Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
das Projekt folgt [Semantic Versioning](https://semver.org/lang/de/).

## [1.0.0] – 2026-05-07

### Added
- Interaktives TUI mit Pfeiltasten-Menü, Multi-Select und Live-Status
- Klassischer CLI-Modus (`-ComputerName`, `-Fix`, `-WhatIf`) für Automation
- Multi-Host-Support via PowerShell Remoting
- Hosts-aus-Datei laden (CSV mit Spalte `ComputerName` oder TXT)
- Automatisches Backup von `Winre.wim` und `reagentc /info`-Snapshot
- GPT- und MBR-Disks beide unterstützt
- Idempotenter Report-Modus (kein Schreibzugriff ohne `-Fix`)
- `ConfirmImpact='High'` und `SupportsShouldProcess` für Sicherheitsnetze

[1.0.0]: https://github.com/T-Alpha/recovery-partition-repair/releases/tag/v1.0.0
