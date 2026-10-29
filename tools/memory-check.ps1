#requires -Version 5.1
<#
.SYNOPSIS
    Проверка памяти проекта AllToDSH: формат, свежесть, секреты.

.DESCRIPTION
    Читает TASK.md и печатает отчёт. Код возврата 1 — есть ошибки (секреты,
    битый формат), 0 — всё в порядке (предупреждения не блокируют).
    С -Quiet молчит, если ошибок нет: так его вызывает pre-commit хук.

.EXAMPLE
    pwsh -File tools/memory-check.ps1
.EXAMPLE
    pwsh -File tools/memory-check.ps1 -Quiet
#>
[CmdletBinding()]
param(
    [string]$Path = 'TASK.md',
    [string]$RepoRoot,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$full = if ($Path -match '^[A-Za-z]:[\\/]') { $Path } else { Join-Path $RepoRoot $Path }

$script:results = New-Object System.Collections.ArrayList
function Add-Result {
    param([string]$Level, [string]$Message)
    [void]$script:results.Add([pscustomobject]@{ Level = $Level; Message = $Message })
}

$allowedStatuses = @('PLANNED', 'IN PROGRESS', 'EXECUTED', 'RESOLVED')
$secretPatterns = @(
    @{ Name = 'ключ вида sk-'; Pattern = 'sk-[A-Za-z0-9_\-]{16,}' },
    @{ Name = 'токен GitHub'; Pattern = 'gh[pousr]_[A-Za-z0-9]{20,}' },
    @{ Name = 'ключ AWS'; Pattern = 'AKIA[0-9A-Z]{16}' },
    @{ Name = 'приватный ключ'; Pattern = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
    @{ Name = 'пароль или токен в присваивании'; Pattern = '(?i)(password|passwd|pwd|secret|api[_-]?key|token)\s*[:=]\s*\S{8,}' },
    @{ Name = 'учётные данные в URL'; Pattern = 'https?://[^\s/:]+:[^\s/@]+@' }
)

if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
    Add-Result 'FAIL' "память не найдена: $Path"
}
else {
    $lines = @(Get-Content -LiteralPath $full -Encoding UTF8)
    $lineCount = $lines.Count

    # --- шапка ---
    $head = @($lines | Select-Object -First 12)
    $protocolSeen = $false
    $updated = $null
    foreach ($l in $head) {
        if ($l -match '^Protocol:\s*(\d+)\s*$') {
            $protocolSeen = $true
            if ($Matches[1] -ne '1') { Add-Result 'WARN' "версия протокола $($Matches[1]), ожидается 1" }
        }
        if ($l -match 'Обновлено:\s*(\d{4}-\d{2}-\d{2})') { $updated = $Matches[1] }
    }
    if (-not $protocolSeen) { Add-Result 'WARN' 'в шапке нет строки Protocol: 1' }
    if (-not $updated) { Add-Result 'FAIL' 'в шапке нет даты «Обновлено: ГГГГ-ММ-ДД»' }

    # --- активная задача ---
    $start = -1
    $status = $null
    for ($i = 0; $i -lt $lineCount; $i++) {
        if ($lines[$i] -match '^##\s+Активная задача\s+\[([^\]]+)\]') {
            $start = $i
            $status = $Matches[1].Trim()
            break
        }
    }
    if ($start -lt 0) {
        Add-Result 'WARN' 'нет секции «Активная задача [СТАТУС]»'
    }
    else {
        if ($allowedStatuses -notcontains $status) {
            Add-Result 'FAIL' "неизвестный статус [$status]: допустимы $($allowedStatuses -join ', ')"
        }
        $end = $lineCount
        for ($j = $start + 1; $j -lt $lineCount; $j++) {
            if ($lines[$j] -match '^##\s') { $end = $j; break }
        }
        $sectionLength = $end - $start
        if ($sectionLength -gt 60) {
            Add-Result 'WARN' "секция активной задачи: $sectionLength строк (лимит 60)"
        }
        $section = if ($end -gt $start + 1) { @($lines[($start + 1)..($end - 1)]) } else { @() }
        $steps = @($section | Where-Object { $_ -match '^\s*\d+\.\s' })
        if ($status -ne 'RESOLVED') {
            if ($steps.Count -eq 0) { Add-Result 'FAIL' 'нет нумерованных следующих шагов' }
            elseif ($steps.Count -lt 2) { Add-Result 'WARN' "следующих шагов: $($steps.Count), нужно 2–3" }
        }
    }

    # --- файлы для чтения ---
    for ($i = 0; $i -lt $lineCount; $i++) {
        if ($lines[$i] -match 'Файлы для чтения') {
            $parts = $lines[$i] -split '`'
            for ($k = 1; $k -lt $parts.Count; $k += 2) {
                $candidate = $parts[$k].Trim()
                if (-not $candidate) { continue }
                if ($candidate -notmatch '[\\/]|\.\w{1,5}$') { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $candidate))) {
                    Add-Result 'WARN' "в «Файлах для чтения» нет пути: $candidate"
                }
            }
            break
        }
    }

    # --- секреты ---
    $secrets = 0
    for ($i = 0; $i -lt $lineCount; $i++) {
        foreach ($p in $secretPatterns) {
            if ($lines[$i] -match $p.Pattern) {
                Add-Result 'FAIL' ("строка {0}: похоже на {1}" -f ($i + 1), $p.Name)
                $secrets++
                break
            }
        }
        if ($secrets -ge 5) { break }
    }

    # --- размер и реестр ---
    if ($lineCount -gt 160) { Add-Result 'WARN' "файл $lineCount строк (лимит 160)" }
    for ($i = 0; $i -lt $lineCount; $i++) {
        if ($lines[$i] -match '^##\s+Реестр') {
            $entries = @($lines[$i..($lineCount - 1)] | Where-Object { $_ -match '^\s*-\s+\S' })
            if ($entries.Count -gt 15) {
                Add-Result 'WARN' "записей в реестре: $($entries.Count) (лимит 15) — старые вынеси в архив"
            }
            break
        }
    }

    # --- свежесть по git ---
    if ((Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
        # git пишет в stderr на пустом репозитории; при Stop это стало бы исключением
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            $head = (& git -C $RepoRoot rev-parse --verify HEAD 2>$null)
            if ($head) {
                $rel = $Path -replace '\\', '/'
                $lastTask = (& git -C $RepoRoot log -1 --format=%cs -- $rel 2>$null)
                $lastAny = (& git -C $RepoRoot log -1 --format=%cs -- . 2>$null)
                $memoryDate = @($updated, "$lastTask".Trim()) |
                    Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}$' } |
                    Sort-Object |
                    Select-Object -Last 1
                $codeDate = "$lastAny".Trim()
                if ($memoryDate -and $codeDate -match '^\d{4}-\d{2}-\d{2}$' -and $codeDate -gt $memoryDate) {
                    Add-Result 'WARN' "память от $memoryDate, код менялся $codeDate — обнови TASK.md"
                }
                $dirty = @(& git -C $RepoRoot status --porcelain 2>$null | Where-Object { $_ })
                $codeDirty = @($dirty | Where-Object { $_.Length -gt 3 -and $_.Substring(3) -notmatch '(^|[/\\])TASK\.md$' })
                $memoryDirty = @($dirty | Where-Object { $_ -match 'TASK\.md$' })
                if ($codeDirty.Count -gt 0 -and $memoryDirty.Count -eq 0) {
                    Add-Result 'WARN' "незакоммиченных изменений: $($codeDirty.Count), память не тронута"
                }
            }
        }
        finally { $ErrorActionPreference = $previous }
    }
}

$fails = @($script:results | Where-Object { $_.Level -eq 'FAIL' })
$warns = @($script:results | Where-Object { $_.Level -eq 'WARN' })

if ($Quiet) {
    foreach ($r in $fails) { Write-Output "AllToDSH: $($r.Message)" }
}
else {
    Write-Output "AllToDSH · проверка памяти: $Path"
    foreach ($r in ($script:results | Where-Object { $_.Level -eq 'FAIL' })) { Write-Output "  ОШИБКА  $($r.Message)" }
    foreach ($r in ($script:results | Where-Object { $_.Level -eq 'WARN' })) { Write-Output "  внимание $($r.Message)" }
}

if (-not $Quiet -or $fails.Count -gt 0) {
    Write-Output "Итог: ошибок $($fails.Count), предупреждений $($warns.Count)"
}

if ($fails.Count -gt 0) { exit 1 } else { exit 0 }
