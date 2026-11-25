$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$script = Join-Path $PSScriptRoot 'MO2-Section-Exporter.ps1'
$source = Join-Path $PSScriptRoot 'Program.cs'
$output = Join-Path $PSScriptRoot 'MO2-Section-Exporter.exe'
& $compiler /nologo /target:winexe /optimize+ /reference:System.Windows.Forms.dll "/resource:$script,ExporterScript" "/out:$output" $source
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
