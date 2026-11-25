$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'MO2-Section-Exporter.ps1') -CoreOnly

$root = Join-Path $env:TEMP ('mo2-smoke-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'Source'
$exports = Join-Path $root 'Exports'
$destination = Join-Path $root 'Destination'
$profile = Join-Path $destination 'profiles\Default'
$mods = Join-Path $destination 'mods'

function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'." }
}

try {
    foreach ($directory in $exports, $profile, $mods) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $modlist = Join-Path $profile 'modlist.txt'
    Set-Content -LiteralPath $modlist -Value '# Fixture', '+Existing' -Encoding UTF8
    $selected = @(foreach ($name in 'Alpha', 'Beta') {
        $directory = Join-Path $source $name
        $null = New-Item -ItemType Directory -Path $directory -Force
        Set-Content -LiteralPath (Join-Path $directory 'example.txt') -Value $name
        [pscustomobject]@{ Name = $name; Path = $directory; Enabled = $name -eq 'Alpha' }
    })
    foreach ($merged in $false, $true) {
        $section = if ($merged) { 'Merged' } else { 'Separate' }
        $bundle = Export-Section $source $exports $section $selected 'Default' {} -Merged:$merged
        $before = Get-Content -LiteralPath $modlist -Raw
        $import = Import-Section $bundle $destination 'Default' $section {}
        Assert-Equal (Get-Content -LiteralPath $import.Backup -Raw) $before
        Assert-Equal (Get-Content -LiteralPath $modlist)[-1] '+Existing'
        if ($merged) {
            Assert-Equal $import.Count 1
            Assert-Equal (Get-Content -LiteralPath (Join-Path $mods 'Merged (Merged)\example.txt')) 'Beta'
        } else {
            Assert-Equal $import.Count 2
            Assert-Equal ((Get-Content -LiteralPath $modlist)[1..3] -join ',') '-Beta,+Alpha,-Separate_separator'
        }
        try {
            $null = Get-ImportPlan $bundle $destination 'Default' $section
            throw 'Expected a name collision.'
        } catch {
            if ($_.Exception.Message -notlike 'A mod or separator already*') { throw }
        }
    }
    $broken = Export-Section $source $exports 'Broken' $selected 'Default' {} -Merged
    Set-Content -LiteralPath (Join-Path $broken 'Merged Section.zip') -Value 'invalid ZIP'
    $before = Get-Content -LiteralPath $modlist -Raw
    try {
        $null = Import-Section $broken $destination 'Default' 'Broken' {}
        throw 'Expected the invalid ZIP to be rejected.'
    } catch {
        if ($_.Exception.Message -eq 'Expected the invalid ZIP to be rejected.') { throw }
    }
    Assert-Equal (Get-Content -LiteralPath $modlist -Raw) $before
    Assert-Equal (Test-Path -LiteralPath (Join-Path $mods 'Broken_separator')) $false
    Write-Host 'Export/import, priority, collision, backup, and invalid ZIP checks passed.'
} finally {
    if ((Test-Path -LiteralPath $root) -and (Test-Within $root $env:TEMP)) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
