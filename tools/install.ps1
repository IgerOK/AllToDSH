#requires -Version 5.1
<#
.SYNOPSIS
    Ставит AllToDSH в другой проект: файлы протокола, скиллы, проверку и хук.

.DESCRIPTION
    Копирует AGENTS.md, TASK.md (из шаблона), скиллы, tools и .githooks в целевую
    папку, инициализирует git при необходимости и включает core.hooksPath.
    Существующие файлы не перезаписываются без -Force: AGENTS.md может содержать
    чужие правила, а TASK.md — живую память.

.EXAMPLE
    powershell -File tools/install.ps1 -Target C:\work\my-project
.EXAMPLE
    powershell -File tools/install.ps1 -Target C:\work\my-project -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$source = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $Target -PathType Container)) { throw "нет такой папки: $Target" }
$dst = (Resolve-Path -LiteralPath $Target).Path
$src = (Resolve-Path -LiteralPath $source).Path
if ($dst.TrimEnd('\', '/') -eq $src.TrimEnd('\', '/')) { throw 'источник и цель совпадают: это репозиторий AllToDSH' }

$manifest = @(
    @{ From = 'AGENTS.md'; To = 'AGENTS.md' },
    @{ From = '.gitignore'; To = '.gitignore' },
    @{ From = 'templates\TASK.md'; To = 'TASK.md' },
    @{ From = 'tools\memory-check.ps1'; To = 'tools\memory-check.ps1' },
    @{ From = 'tools\install.ps1'; To = 'tools\install.ps1' },
    @{ From = '.agents\skills\resume\SKILL.md'; To = '.agents\skills\resume\SKILL.md' },
    @{ From = '.agents\skills\checkpoint\SKILL.md'; To = '.agents\skills\checkpoint\SKILL.md' },
    @{ From = '.githooks\pre-commit'; To = '.githooks\pre-commit' }
)

$copied = New-Object System.Collections.ArrayList
$kept = New-Object System.Collections.ArrayList

function Add-GitignoreLines([string]$targetPath) {
    $wanted = @('.notes/', '.tmp/', 'Thumbs.db', 'desktop.ini', '.DS_Store')
    $existing = if (Test-Path -LiteralPath $targetPath) { @(Get-Content -LiteralPath $targetPath -Encoding UTF8) } else { @() }
    $missing = @($wanted | Where-Object { $existing -notcontains $_ })
    if ($missing.Count -eq 0) { return 0 }
    $prefix = if ($existing.Count -gt 0) { @('', '# AllToDSH') } else { @() }
    $text = ((@($prefix) + $missing) -join "`r`n") + "`r`n"
    [System.IO.File]::AppendAllText($targetPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    return $missing.Count
}

foreach ($item in $manifest) {
    $from = Join-Path $src $item.From
    $to = Join-Path $dst $item.To
    if (-not (Test-Path -LiteralPath $from)) { throw "нет исходного файла: $($item.From)" }

    if ((Test-Path -LiteralPath $to) -and -not $Force) {
        if ($item.To -eq '.gitignore') { [void]$kept.Add("$($item.To) (дополнен)") }
        else { [void]$kept.Add($item.To) }
        continue
    }
    $dir = Split-Path -Parent $to
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $from -Destination $to -Force
    [void]$copied.Add($item.To)
}
[void](Add-GitignoreLines (Join-Path $dst '.gitignore'))

$gitNote = 'git уже есть'
if (-not (Test-Path -LiteralPath (Join-Path $dst '.git'))) {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        & git -C $dst init -b main | Out-Null
        $gitNote = 'git init выполнен (ветка main)'
    }
    else {
        $gitNote = 'git не найден — инициализируй вручную'
    }
}
if ((Test-Path -LiteralPath (Join-Path $dst '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
    & git -C $dst config core.hooksPath .githooks
}

Write-Output "AllToDSH → $dst"
Write-Output "  скопировано: $($copied.Count)"
foreach ($c in $copied) { Write-Output "    + $c" }
if ($kept.Count -gt 0) {
    Write-Output "  оставлено как есть: $($kept.Count)"
    foreach ($k in $kept) { Write-Output "    = $k" }
}
Write-Output "  $gitNote"
Write-Output ''
Write-Output 'Дальше:'
if ($kept -contains 'AGENTS.md') {
    Write-Output '  1. AGENTS.md уже был — вставь в него секцию протокола вручную (не перетирай чужие правила).'
}
Write-Output '  2. Заполни TASK.md: цель, следующие шаги, проверка.'
Write-Output '  3. Прогони: powershell -File tools/memory-check.ps1'
Write-Output '  4. Первый коммит: git add -A; git commit -m "AllToDSH init"'
