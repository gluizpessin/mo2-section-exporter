param([switch]$CoreOnly)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-Sections($Profile, $Mods) {
    $lines = [IO.File]::ReadAllLines((Join-Path $Profile 'modlist.txt'))
    [array]::Reverse($lines)
    $section = [pscustomobject]@{ Name = 'Ungrouped'; Mods = [Collections.Generic.List[object]]::new() }
    foreach ($line in $lines) {
        if ($line -notmatch '^([+-])(.+)$') { continue }
        $enabled = $Matches[1] -eq '+'
        $name = $Matches[2]
        if ([IO.Path]::GetFileName($name) -ne $name -or $name -in '.', '..') { continue }
        if ($name.EndsWith('_separator', [StringComparison]::OrdinalIgnoreCase)) {
            if ($section.Mods.Count) { $section }
            $section = [pscustomobject]@{ Name = $name.Substring(0, $name.Length - 10); Mods = [Collections.Generic.List[object]]::new() }
            continue
        }
        $path = Join-Path $Mods $name
        if (Test-Path -LiteralPath $path -PathType Container) {
            $section.Mods.Add([pscustomobject]@{ Name = $name; Path = $path; Enabled = $enabled })
        }
    }
    if ($section.Mods.Count) { $section }
}

function Test-Within($Child, $Parent) {
    $childPath = [IO.Path]::GetFullPath($Child).TrimEnd('\')
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $childPath.Equals($parentPath, [StringComparison]::OrdinalIgnoreCase) -or
        $childPath.StartsWith($parentPath + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-OrdinaryPath($Path) {
    for ($cursor = [IO.Path]::GetFullPath($Path); $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
        $item = Get-Item -LiteralPath $cursor -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Choose a path without junctions or symbolic links. Found: $cursor"
        }
    }
}

$BaseGameMasters = @('Skyrim.esm','Update.esm','Dawnguard.esm','HearthFires.esm','Dragonborn.esm')

function Test-BaseGameFile($RelativePath) {
    $RelativePath -in $BaseGameMasters -or
        $RelativePath -match '^(?:Skyrim - (?:Animations|Interface|Meshes[01]|Misc|Shaders|Sounds|Textures[0-8]|Voices_[a-z]{2}[0-9]+)|MarketplaceTextures|_ResourcePack)\.bsa$' -or
        $RelativePath -ieq '_ResourcePack.esl'
}

function Export-Section($Source, $Destination, $Section, $Selected, $Profile, $Report, [switch]$Merged) {
    $Source = (Get-Item -LiteralPath $Source).FullName
    $Destination = (Get-Item -LiteralPath $Destination).FullName
    Assert-OrdinaryPath $Destination
    if (Test-Within $Destination $Source) { throw 'Choose an export location outside the source modlist.' }
    $safeSection = ($Section -replace '[<>:"/\\|?*\x00-\x1f]', '_').Trim(' ','.')
    if (!$safeSection) { $safeSection = 'Section' }
    & $Report 'Checking selected mod files...'
    $paths = @{}
    [long]$inputBytes = 0
    foreach ($mod in $Selected) {
        Assert-OrdinaryPath $mod.Path
        $children = @(Get-ChildItem -LiteralPath $mod.Path -Force -Recurse)
        if ($children | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1) {
            throw "This mod contains a junction or symbolic link: $($mod.Name)"
        }
        $files = @($children | Where-Object { !$_.PSIsContainer })
        if (!$files.Count) { throw "This mod has no files: $($mod.Name)" }
        $stockFiles = @($files | Where-Object {
            Test-BaseGameFile $_.FullName.Substring($mod.Path.Length + 1)
        })
        if ($stockFiles.Count) {
            $files = @($files | Where-Object { $_ -notin $stockFiles })
            if (!$files.Count -or ($files.Count -eq 1 -and $files[0].Name -ieq 'meta.ini' -and $files[0].DirectoryName -ieq $mod.Path)) {
                continue
            }
        }
        $paths[$mod.Name] = $files
        $inputBytes += ($files | Measure-Object Length -Sum).Sum
    }

    $Selected = @($Selected | Where-Object { $paths.ContainsKey($_.Name) })
    if (!$Selected.Count) { throw 'The selection contains only Skyrim stock files. There is nothing to export.' }
    $free = (Get-Item -LiteralPath $Destination).PSDrive.Free
    if ($null -ne $free -and $free -le 0) {
        throw 'The destination drive has no free space.'
    }

    & $Report ('Selected files: {0:N2} GiB before compression' -f ($inputBytes / 1GB))
    $folderName = '{0} - {1} - {2}' -f (Split-Path $Source -Leaf), $safeSection, (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    $folder = Join-Path $Destination $folderName
    $null = New-Item -Path $folder -ItemType Directory
    $manifest = [ordered]@{ version = 1; source = (Split-Path $Source -Leaf); profile = $Profile; section = $Section; mods = @() }
    $manifest.format = if ($Merged) { 'merged' } else { 'individual' }
    try {
        $jobs = if ($Merged) {
            $winningFiles = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($mod in $Selected) {
                $manifest.mods += [ordered]@{ name = $mod.Name; enabled = $mod.Enabled }
                foreach ($file in $paths[$mod.Name]) {
                    $relative = $file.FullName.Substring($mod.Path.Length + 1).Replace('\', '/')
                    if ($relative -ieq 'meta.ini' -or $relative -match '(?i)\.mohidden(?:/|$)') { continue }
                    $winningFiles[$relative] = [pscustomobject]@{ Relative = $relative; File = $file }
                }
            }
            if (!$winningFiles.Count) { throw 'The selected mods contain no visible game files.' }
            foreach ($relative in $winningFiles.Keys) {
                $ancestor = $relative
                while (($slash = $ancestor.LastIndexOf('/')) -ge 0) {
                    $ancestor = $ancestor.Substring(0, $slash)
                    if ($winningFiles.ContainsKey($ancestor)) { throw "A file and folder share the same path: $ancestor" }
                }
            }
            $manifest.archive = 'Merged Section.zip'
            [pscustomobject]@{ Name = $Section; Archive = $manifest.archive; Files = $winningFiles.Values }
        } else {
            foreach ($mod in $Selected) {
                $filename = $mod.Name + '.zip'
                $manifest.mods += [ordered]@{ name = $mod.Name; archive = $filename; enabled = $mod.Enabled }
                $entries = foreach ($file in $paths[$mod.Name]) {
                    [pscustomobject]@{ Relative = $file.FullName.Substring($mod.Path.Length + 1).Replace('\', '/'); File = $file }
                }
                [pscustomobject]@{ Name = $mod.Name; Archive = $filename; Files = @($entries) }
            }
        }
        [long]$totalWork = 0
        foreach ($job in $jobs) {
            $totalWork += 2 * [long](($job.Files | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum)
        }
        [long]$processed = 0
        $clock = [Diagnostics.Stopwatch]::StartNew()
        [long]$lastUpdate = -200
        & $Report ('#progress|0|{0}' -f $totalWork)
        foreach ($job in $jobs) {
            & $Report "Compressing $($job.Name)"
            $filename = $job.Archive
            $partial = Join-Path $folder ($filename + '.partial')
            $archive = [IO.Compression.ZipFile]::Open($partial, [IO.Compression.ZipArchiveMode]::Create)
            $sourceFiles = @{}
            $buffer = New-Object byte[] (1MB)
            try {
                foreach ($item in $job.Files) {
                    $file = $item.File
                    $entryName = $item.Relative
                    $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Fastest)
                    $original = [IO.File]::OpenRead($file.FullName)
                    try {
                        $stream = $entry.Open()
                        try {
                            $hash = [Security.Cryptography.SHA256]::Create()
                            try {
                                while (($read = $original.Read($buffer, 0, $buffer.Length)) -gt 0) {
                                    $stream.Write($buffer, 0, $read)
                                    $processed += $read
                                    if ($clock.ElapsedMilliseconds - $lastUpdate -ge 200) {
                                        & $Report ('#progress|{0}|{1}' -f $processed, $totalWork)
                                        $lastUpdate = $clock.ElapsedMilliseconds
                                    }
                                    $null = $hash.TransformBlock($buffer, 0, $read, $buffer, 0)
                                }
                                $null = $hash.TransformFinalBlock($buffer, 0, 0)
                                $sourceFiles[$entryName] = [BitConverter]::ToString($hash.Hash).Replace('-', '')
                            } finally { $hash.Dispose() }
                        } finally { $stream.Dispose() }
                    } finally { $original.Dispose() }
                }
            } finally { $archive.Dispose() }
            & $Report "Verifying $($job.Name)"
            $archive = [IO.Compression.ZipFile]::OpenRead($partial)
            try {
                if ($archive.Entries.Count -ne $sourceFiles.Count) { throw "ZIP entry count differs for $($job.Name)." }
                foreach ($entry in $archive.Entries) {
                    $stream = $entry.Open()
                    try {
                        $hash = [Security.Cryptography.SHA256]::Create()
                        try {
                            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                                $null = $hash.TransformBlock($buffer, 0, $read, $buffer, 0)
                                $processed += $read
                                if ($clock.ElapsedMilliseconds - $lastUpdate -ge 200) {
                                    & $Report ('#progress|{0}|{1}' -f $processed, $totalWork)
                                    $lastUpdate = $clock.ElapsedMilliseconds
                                }
                            }
                            $null = $hash.TransformFinalBlock($buffer, 0, 0)
                            $archived = [BitConverter]::ToString($hash.Hash).Replace('-', '')
                        } finally { $hash.Dispose() }
                    } finally { $stream.Dispose() }
                    if ($archived -ne $sourceFiles[$entry.FullName]) { throw "ZIP verification failed for $($entry.FullName)." }
                }
            } finally { $archive.Dispose() }
            [IO.File]::Move($partial, (Join-Path $folder $filename))
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $folder 'section.json') -Encoding UTF8
        & $Report ('#progress|{0}|{0}' -f $processed)
    } catch {
        $partialFiles = Get-ChildItem -LiteralPath $folder -File -Filter '*.partial'
        foreach ($file in $partialFiles) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
        throw "Export incomplete. Any verified ZIPs are in $folder. $($_.Exception.Message)"
    }
    $folder
}


function Read-Masters($Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'TES4') { throw 'Invalid TES4 header' }
        $length = $reader.ReadUInt32()
        $end = 24L + $length
        if ($end -gt $stream.Length) { throw 'Truncated TES4 header' }
        $stream.Position = 24
        [long]$extended = -1
        while ($stream.Position -lt $end) {
            if ($end - $stream.Position -lt 6) { throw 'Truncated subrecord' }
            $type = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
            [long]$size = $reader.ReadUInt16()
            if ($type -eq 'XXXX') {
                if ($extended -ge 0 -or $size -ne 4 -or $end - $stream.Position -lt 4) { throw 'Invalid extended size' }
                $extended = $reader.ReadUInt32()
                continue
            }
            if ($extended -ge 0) { $size = $extended; $extended = -1 }
            if ($size -gt $end - $stream.Position) { throw 'Truncated subrecord data' }
            if ($type -eq 'MAST') {
                if ($size -lt 2 -or $size -gt 1024) { throw 'Invalid master name' }
                [Text.Encoding]::GetEncoding(1252).GetString($reader.ReadBytes([int]$size)).TrimEnd([char]0)
            } else { $stream.Position += $size }
        }
    } finally { $reader.Dispose() }
}

function Find-SmpMesh($MeshDirectory) {
    $marker = 'HDT Skinned Mesh Physics Object'
    $buffer = [char[]]::new(65536)
    foreach ($mesh in Get-ChildItem -LiteralPath $MeshDirectory -Recurse -File -Filter '*.nif') {
        $reader = [IO.StreamReader]::new($mesh.FullName, [Text.Encoding]::GetEncoding(28591), $false)
        try {
            $header = $reader.ReadLine()
            if (!$header -or !$header.StartsWith('Gamebryo File Format', [StringComparison]::Ordinal)) { continue }
            $tail = ''
            while (($count = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $chunk = $tail + [string]::new($buffer, 0, $count)
                if ($chunk.IndexOf($marker, [StringComparison]::Ordinal) -ge 0) { return $mesh.FullName }
                $tail = $chunk.Substring([Math]::Max(0, $chunk.Length - $marker.Length + 1))
            }
        } finally { $reader.Dispose() }
    }
}

function Get-RuntimeRequirements($Mod, $SmpProvider) {
    $skse = Join-Path $Mod.Path 'SKSE\Plugins'
    $config = Join-Path $Mod.Path 'SKSE\Plugins\hdtSkinnedMeshConfigs'
    if (Test-Path -LiteralPath $skse -PathType Container) {
        $dll = Get-ChildItem -LiteralPath $skse -File -Filter '*.dll' | Select-Object -First 1
        if ($dll) {
            [pscustomobject]@{ Master = 'SKSE runtime'; Provider = 'Destination setup'; RequiredBy = $Mod.Name; Plugin = $dll.Name; Status = 'Check runtime' }
        }
    }
    if ($SmpProvider -eq $Mod.Name -or (Test-Path -LiteralPath (Join-Path $skse 'hdtSMP64.dll') -PathType Leaf)) { return }
    $evidence = $null
    if (Test-Path -LiteralPath $config -PathType Container) {
        $xml = Get-ChildItem -LiteralPath $config -Recurse -File -Filter '*.xml' | Select-Object -First 1
        if ($xml) { $evidence = $xml.FullName }
    }
    $meshes = Join-Path $Mod.Path 'meshes'
    if (!$evidence -and (Test-Path -LiteralPath $meshes -PathType Container)) { $evidence = Find-SmpMesh $meshes }
    if ($evidence) {
        [pscustomobject]@{
            Master = 'HDT-SMP / Faster HDT-SMP'
            Provider = if ($SmpProvider) { $SmpProvider } else { 'Destination setup' }
            RequiredBy = $Mod.Name
            Plugin = $evidence.Substring($Mod.Path.Length + 1)
            Status = 'Check runtime'
        }
    }
}
function Get-DependencyPlan($Installed, $Selected, [switch]$Merged) {
    $byMod = @{}
    $providers = @{}
    $gameMasters = $BaseGameMasters + '_ResourcePack.esl'
    foreach ($mod in $Installed) {
        $plugins = @(Get-ChildItem -LiteralPath $mod.Path -File | Where-Object Extension -in '.esp','.esm','.esl')
        $byMod[$mod.Name] = $plugins
        foreach ($plugin in $plugins) {
            if (!$providers.ContainsKey($plugin.Name)) { $providers[$plugin.Name] = [Collections.Generic.List[object]]::new() }
            $providers[$plugin.Name].Add($mod)
        }
    }
    $chosen = @{}
    $additions = @{}
    $notes = [Collections.Generic.List[string]]::new()
    foreach ($mod in $Selected) { $chosen[$mod.Name] = $true }
    do {
        $changed = $false
        $full = @($Installed | Where-Object { $chosen.ContainsKey($_.Name) })
        $visible = @{}
        if ($Merged) {
            foreach ($mod in $full) {
                foreach ($plugin in $byMod[$mod.Name]) { $visible[$plugin.Name] = $mod.Name }
            }
        }
        $roundNotes = [Collections.Generic.List[string]]::new()
        $requirements = [Collections.Generic.List[object]]::new()
        foreach ($mod in $full) {
            foreach ($plugin in $byMod[$mod.Name]) {
                if ($Merged -and $visible[$plugin.Name] -ne $mod.Name) { continue }
                try { $masters = @(Read-Masters $plugin.FullName) }
                catch { $roundNotes.Add("Could not read $($plugin.Name) in $($mod.Name): $($_.Exception.Message)"); continue }
                foreach ($master in $masters) {
                    $provider = $null
                    $state = 'Missing'
                    if ($master -in $gameMasters) { $state = 'Base game' }
                    else {
                        $candidates = $providers[$master]
                        if ($candidates) {
                            $included = @($candidates | Where-Object { $chosen.ContainsKey($_.Name) })
                            $active = @($candidates | Where-Object Enabled)
                            $usable = if ($Merged) { @($included) } else { @($included | Where-Object Enabled) }
                            $provider = if ($usable) { @($usable)[-1] } elseif ($active) { $active[-1] } else { $candidates[$candidates.Count - 1] }
                            $state = if ($additions.ContainsKey($provider.Name) -or !$chosen.ContainsKey($provider.Name)) { 'To add' } else { 'Selected' }
                            if ($candidates.Count -gt 1 -and !$usable) {
                                $roundNotes.Add("Review providers for $master, required by $($plugin.Name): $($candidates.Name -join ', ')")
                            }
                        }
                    }
                    $requirements.Add([pscustomobject]@{
                        Master = $master
                        Provider = if ($provider) { $provider.Name } else { '' }
                        RequiredBy = $mod.Name
                        Plugin = $plugin.Name
                        Status = $state
                    })
                    if (!$provider) { continue }
                    if (!$provider.Enabled -and !$Merged) {
                        $roundNotes.Add("Enable $($provider.Name) in the destination for $master, required by $($plugin.Name)")
                    }
                    if (!$chosen.ContainsKey($provider.Name)) {
                        $chosen[$provider.Name] = $true
                        $additions[$provider.Name] = "$($provider.Name) - required by $($plugin.Name) ($master)"
                        $changed = $true
                    }
                }
            }
        }
    } while ($changed)
    $smpProvider = $Installed | Where-Object {
        $_.Enabled -and (Test-Path -LiteralPath (Join-Path $_.Path 'SKSE\Plugins\hdtSMP64.dll') -PathType Leaf)
    } | Select-Object -Last 1
    foreach ($mod in $full) {
        try {
            foreach ($requirement in Get-RuntimeRequirements $mod $smpProvider.Name) {
                $requirements.Add($requirement)
                if ($requirement.Master -eq 'SKSE runtime') {
                    $notes.Add("SKSE DLL: $($mod.Name). Check Skyrim runtime and any additional requirements.")
                }
            }
        } catch {
            $notes.Add("Could not finish SKSE/SMP scan for $($mod.Name): $($_.Exception.Message)")
        }
    }
    foreach ($line in $roundNotes) { $notes.Add($line) }
    [pscustomobject]@{
        Mods = $full
        Added = @($full | Where-Object { $additions.ContainsKey($_.Name) } | ForEach-Object { $additions[$_.Name] })
        Requirements = @($requirements | Sort-Object Master, RequiredBy, Plugin -Unique)
        Notes = @($notes | Sort-Object -Unique)
    }
}

if ($CoreOnly) { return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = 'MO2 Section Exporter'
$form.ClientSize = New-Object Drawing.Size(820, 778)
$form.BackColor = [Drawing.ColorTranslator]::FromHtml('#F3F6FA')
$form.ForeColor = [Drawing.ColorTranslator]::FromHtml('#17243A')
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'

function Add-Control($Type, $Text, $X, $Y, $Width, $Height) {
    $control = New-Object "Windows.Forms.$Type"
    $control.Text = $Text
    $control.SetBounds($X, $Y, $Width, $Height)
    $form.Controls.Add($control)
    $control
}

$surface = [Drawing.ColorTranslator]::FromHtml('#FFFFFF')
$muted = [Drawing.ColorTranslator]::FromHtml('#465875')
$accent = [Drawing.ColorTranslator]::FromHtml('#175BCD')

$theme = Add-Control Button 'Dark mode' 674 24 120 33
$title = Add-Control Label 'MO2 Section Exporter' 26 17 630 43
$title.Font = New-Object Drawing.Font('Segoe UI', 23, [Drawing.FontStyle]::Bold)
$subtitle = Add-Control Label 'Save selected mods and their requirements for your next modlist.' 26 61 768 24
$subtitle.ForeColor = $muted
$chooseStep = Add-Control Label '1   Choose mods' 26 99 256 31
$reviewStep = Add-Control Label '2   Review dependencies' 282 99 256 31
$exportStep = Add-Control Label '3   Export' 538 99 256 31
$steps = @($chooseStep, $reviewStep, $exportStep)
foreach ($step in $steps) {
    $step.TextAlign = 'MiddleCenter'
    $step.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
}
function Set-GuidedStep([int]$Current) {
    $script:currentStep = $Current
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $steps[$i].BackColor = if ($i -eq $Current) { $accent } else { $script:stepBackground }
        $steps[$i].ForeColor = if ($i -eq $Current) { [Drawing.Color]::White } else { $muted }
    }
}
$script:stepBackground = [Drawing.ColorTranslator]::FromHtml('#E5EBF5'); Set-GuidedStep 0

$null = Add-Control Label 'MO2 installation' 26 150 600 23
$install = Add-Control ComboBox '' 26 175 650 30
$install.DropDownStyle = 'DropDownList'
$browse = Add-Control Button 'Browse...' 690 173 104 32
$null = Add-Control Label 'Profile' 26 215 360 23
$profile = Add-Control ComboBox '' 26 240 366 30
$profile.DropDownStyle = 'DropDownList'
$null = Add-Control Label 'Separator' 412 215 382 23
$separator = Add-Control ComboBox '' 412 240 382 30
$separator.DropDownStyle = 'DropDownList'

$selection = Add-Control Label 'Mods' 26 288 475 27
$selection.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$all = Add-Control Button 'Select all' 576 283 104 32
$none = Add-Control Button 'Clear' 690 283 104 32
$null = Add-Control Label 'Filter by mod name' 26 326 150 24
$search = Add-Control TextBox '' 180 322 614 29
$search.AccessibleName = 'Filter by mod name'
$checks = Add-Control CheckedListBox '' 26 360 768 206
$checks.CheckOnClick = $true
$checks.HorizontalScrollbar = $true
$checks.BorderStyle = 'FixedSingle'

$null = Add-Control Label 'Export format' 26 586 118 24
$format = Add-Control ComboBox '' 155 581 300 31
$format.DropDownStyle = 'DropDownList'
$null = $format.Items.Add('Individual ZIPs')
$null = $format.Items.Add('Single merged ZIP')
$format.SelectedIndex = 0
$formatHelp = Add-Control Label '' 26 615 555 24
$formatHelp.ForeColor = $muted
$format.Add_SelectedIndexChanged({
    $formatHelp.Text = if ($format.SelectedIndex -eq 1) { 'Higher-priority selected mods win file conflicts. Plugin order is unchanged.' } else { '' }
})
$status = Add-Control Label 'Choose an installed MO2 modlist.' 26 650 540 46
$status.ForeColor = $muted
$progress = Add-Control ProgressBar '' 26 704 768 13
$progress.Style = 'Continuous'
$progress.Maximum = 100
$progress.Visible = $false
$metrics = Add-Control Label '' 26 725 768 28
$metrics.ForeColor = $muted
$export = Add-Control Button 'Review selection' 606 646 188 46
$export.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$export.Enabled = $false

foreach ($field in $install, $profile, $separator, $checks, $format, $search) {
    $field.BackColor = $surface
    $field.ForeColor = $form.ForeColor
}
foreach ($button in $browse, $all, $none, $export) {
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $surface
    $button.ForeColor = $form.ForeColor
}
$export.BackColor = $accent
$export.ForeColor = [Drawing.Color]::White

$script:darkMode = $false
$theme.Add_Click({
    $script:darkMode = !$script:darkMode
    $palette = if ($script:darkMode) {
        @('#111826','#E8EFFA','#202C3F','#B9C8DB','#255CC1','#26344A')
    } else {
        @('#F3F6FA','#17243A','#FFFFFF','#465875','#175BCD','#E5EBF5')
    }
    $colors = @($palette | ForEach-Object { [Drawing.ColorTranslator]::FromHtml($_) })
    $form.BackColor = $colors[0]
    $form.ForeColor = $colors[1]
    $script:surface = $colors[2]
    $script:muted = $colors[3]
    $script:accent = $colors[4]
    $script:stepBackground = $colors[5]
    foreach ($control in $subtitle, $formatHelp, $status, $metrics) { $control.ForeColor = $muted }
    foreach ($control in $install, $profile, $separator, $checks, $format, $search, $browse, $all, $none, $theme) {
        $control.ForeColor = $form.ForeColor
        $control.BackColor = $surface
    }
    $export.BackColor = $accent
    $theme.Text = if ($script:darkMode) { 'Light mode' } else { 'Dark mode' }
    Set-GuidedStep $script:currentStep
})
$theme.FlatStyle = 'Flat'
$theme.FlatAppearance.BorderSize = 0
$theme.BackColor = $surface
$script:selectedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:sectionMods = @()
$script:visibleMods = @()
$script:refreshingList = $false

function Update-Selection {
    $count = $script:selectedNames.Count
    $selection.Text = "Mods  |  $count of $($script:sectionMods.Count) selected  |  $($script:visibleMods.Count) shown"
    $export.Enabled = $count -gt 0
    $all.Enabled = $script:visibleMods.Count -gt $checks.CheckedItems.Count
    $none.Enabled = $checks.CheckedItems.Count -gt 0
}

function Refresh-ModList {
    $filter = $search.Text.Trim()
    $script:visibleMods = @($script:sectionMods | Where-Object {
        $_.Name.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    $script:refreshingList = $true
    $checks.BeginUpdate()
    try {
        $checks.Items.Clear()
        foreach ($mod in $script:visibleMods) {
            $label = if ($mod.Enabled) { $mod.Name } else { $mod.Name + ' (disabled in source)' }
            $null = $checks.Items.Add($label, $script:selectedNames.Contains($mod.Name))
        }
    } finally {
        $checks.EndUpdate()
        $script:refreshingList = $false
    }
    Update-Selection
}

$search.Add_TextChanged({ Refresh-ModList })
$checks.Add_ItemCheck({
    param($sender, $eventArgs)
    if ($script:refreshingList) { return }
    $name = $script:visibleMods[$eventArgs.Index].Name
    if ($eventArgs.NewValue -eq 'Checked') { $null = $script:selectedNames.Add($name) }
    else { $null = $script:selectedNames.Remove($name) }
    Update-Selection
    $checked = $checks.CheckedItems.Count
    if ($eventArgs.CurrentValue -eq 'Checked') { $checked-- }
    if ($eventArgs.NewValue -eq 'Checked') { $checked++ }
    $all.Enabled = $script:visibleMods.Count -gt $checked
    $none.Enabled = $checked -gt 0
})
$all.Text = 'Select shown'
$none.Text = 'Clear shown'
$all.Add_Click({
    foreach ($mod in $script:visibleMods) { $null = $script:selectedNames.Add($mod.Name) }
    Refresh-ModList
})
$none.Add_Click({
    foreach ($mod in $script:visibleMods) { $null = $script:selectedNames.Remove($mod.Name) }
    Refresh-ModList
})
Update-Selection
function Select-Folder($Description) {
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    try {
        if ($dialog.ShowDialog($form) -eq 'OK') { $dialog.SelectedPath }
    } finally { $dialog.Dispose() }
}

function Add-Install($Path) {
    if ((Test-Path -LiteralPath (Join-Path $Path 'ModOrganizer.ini')) -and
        (Test-Path -LiteralPath (Join-Path $Path 'mods') -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $Path 'profiles') -PathType Container)) {
        if (!$install.Items.Contains($Path)) { $null = $install.Items.Add($Path) }
    }
}

$install.Add_SelectedIndexChanged({
    if ($install.SelectedIndex -lt 0) { return }
    $profile.Items.Clear()
    $separator.Items.Clear()
    $script:sectionMods = @(); $script:selectedNames.Clear(); Refresh-ModList
    $root = [string]$install.SelectedItem
    foreach ($dir in Get-ChildItem -LiteralPath (Join-Path $root 'profiles') -Directory) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName 'modlist.txt')) { $null = $profile.Items.Add($dir.Name) }
    }
    if ($profile.Items.Count) {
        $selected = Select-String -LiteralPath (Join-Path $root 'ModOrganizer.ini') -Pattern '^selected_profile=@ByteArray\((.*)\)' | Select-Object -First 1
        $index = if ($selected) { $profile.Items.IndexOf($selected.Matches[0].Groups[1].Value) } else { -1 }
        $profile.SelectedIndex = [Math]::Max(0, $index)
    }
})
$profile.Add_SelectedIndexChanged({
    if ($profile.SelectedIndex -lt 0) { return }
    $separator.Items.Clear()
    $script:sectionMods = @(); $script:selectedNames.Clear(); Refresh-ModList
    $root = [string]$install.SelectedItem
    $directory = Join-Path (Join-Path $root 'profiles') ([string]$profile.SelectedItem)
    $script:sections = @(Get-Sections $directory (Join-Path $root 'mods'))
    foreach ($section in $script:sections) { $null = $separator.Items.Add($section.Name) }
    if ($separator.Items.Count) { $separator.SelectedIndex = 0 }
})
$separator.Add_SelectedIndexChanged({
    $script:sectionMods = @()
    $script:selectedNames.Clear()
    if ($separator.SelectedIndex -ge 0) {
        $section = $script:sections[$separator.SelectedIndex]
        $script:sectionMods = @($section.Mods.ToArray())
        foreach ($mod in $script:sectionMods) { $null = $script:selectedNames.Add($mod.Name) }
    }
    $search.Clear()
    Refresh-ModList
    $status.Text = 'Choose the mods and ZIP format, then review the dependencies.'
})
$browse.Add_Click({
    $path = Select-Folder 'Choose the folder containing ModOrganizer.ini, mods and profiles.'
    if (!$path) { return }
    Add-Install $path
    $index = $install.Items.IndexOf($path)
    if ($index -ge 0) { $install.SelectedIndex = $index }
    else { [void][Windows.Forms.MessageBox]::Show($form, 'This folder does not contain a standard portable MO2 installation.', $form.Text) }
})
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 150
$script:job = $null
$scriptFile = $PSCommandPath
$controls = @($install, $browse, $profile, $separator, $checks, $export, $all, $none, $format, $search)
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:job) {
        $eventArgs.Cancel = $true
        $status.Text = 'A scan or export is running. Wait for it to finish before closing.'
    }
})
$timer.Add_Tick({
    $job = $script:job
    if (!$job) { return }
    if ($job.Kind -eq 'Scan') {
        if (!$job.Handle.IsCompleted) { return }
        $timer.Stop()
        $plan = $null
        try {
            $result = $job.Worker.EndInvoke($job.Handle)
            if ($job.Worker.HadErrors) { throw $job.Worker.Streams.Error[0] }
            $plan = $result[0]
        } catch {
            $status.Text = 'Dependency scan failed.'
            [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, $form.Text)
        } finally {
            $job.Worker.Dispose()
            $script:job = $null
            $progress.Visible = $false
            $progress.Style = 'Continuous'
            foreach ($control in $controls) { $control.Enabled = $true }
            Update-Selection
        }
        if ($plan) { Show-DependencyReview $plan $job.Selected $job.Section } else { Set-GuidedStep 0 }
        return
    }
    $message = $null
    while ($job.Queue.TryDequeue([ref]$message)) {
        if ($message -match '^#progress\|(\d+)\|(\d+)$') {
            $job.Bytes = [long]$Matches[1]
            $job.Total = [long]$Matches[2]
        } else {
            $status.Text = $message
        }
    }
    $elapsed = $job.Clock.Elapsed
    $rate = $job.Bytes / [Math]::Max(0.01, $elapsed.TotalSeconds)
    if ($job.Total -gt 0) {
        $percent = [int][Math]::Floor([Math]::Min(100, 100.0 * $job.Bytes / $job.Total))
        $progress.Value = $percent
        $metrics.Text = '{0}%  |  {1:N1} MiB/s avg  |  {2:hh\:mm\:ss} elapsed' -f $percent, ($rate / 1MB), $elapsed
    } else {
        $metrics.Text = '{0:hh\:mm\:ss} elapsed' -f $elapsed
    }
    if (!$job.Handle.IsCompleted) { return }
    $timer.Stop()
    try {
        $result = $job.Worker.EndInvoke($job.Handle)
        if ($job.Worker.HadErrors) { throw $job.Worker.Streams.Error[0] }
        $progress.Value = 100
        $status.Text = "Verified ZIP archives: $(@(Get-ChildItem -LiteralPath ([string]$result[0]) -File -Filter '*.zip').Count)."
        [void][Windows.Forms.MessageBox]::Show($form, "Export complete.$([Environment]::NewLine)$result", $form.Text)
    } catch {
        Set-GuidedStep 0
        $status.Text = 'Export stopped.'
        $metrics.Text = 'Export incomplete  |  ' + $metrics.Text
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, $form.Text)
    } finally {
        $job.Worker.Dispose()
        $script:job = $null
        foreach ($control in $controls) { $control.Enabled = $true }
        Update-Selection
    }
})
function Start-Export($destination, $section, $selected) {
    $queue = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    $worker = [PowerShell]::Create()
    try {
        $null = $worker.AddScript({
            param($ScriptPath, $Source, $Destination, $Section, $Selected, $Profile, $Queue, $Merged)
            . $ScriptPath -CoreOnly
            Export-Section $Source $Destination $Section $Selected $Profile {
                param($message)
                $Queue.Enqueue($message)
            } -Merged:$Merged
        }).AddArgument($scriptFile).AddArgument([string]$install.SelectedItem).AddArgument($destination).
            AddArgument($section.Name).AddArgument($selected).AddArgument([string]$profile.SelectedItem).AddArgument($queue).AddArgument($format.SelectedIndex -eq 1)
        $script:job = @{ Worker = $worker; Queue = $queue; Clock = [Diagnostics.Stopwatch]::StartNew(); Bytes = [long]0; Total = [long]0; Handle = $worker.BeginInvoke(); Count = $(if ($format.SelectedIndex -eq 1) { 1 } else { $selected.Count }) }
        foreach ($control in $controls) { $control.Enabled = $false }
        Set-GuidedStep 2
        $status.Text = 'Checking selected mod files...'
        $progress.Value = 0
        $metrics.Text = ''
        $progress.Visible = $true
        $timer.Start()
    } catch {
        $worker.Dispose()
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, $form.Text)
    }
}

function Show-DependencyReview($plan, $selected, $section) {
    $review = New-Object Windows.Forms.Form
    $review.Text = 'MO2 Section Exporter'
    $review.ClientSize = New-Object Drawing.Size(820, 650)
    $review.FormBorderStyle = 'FixedDialog'
    $review.MaximizeBox = $false
    $review.MinimizeBox = $false
    $review.StartPosition = 'CenterParent'
    $review.Font = $form.Font
    $review.BackColor = $form.BackColor
    $review.ForeColor = $form.ForeColor

    function Add-ReviewControl($type, $text, $x, $y, $width, $height) {
        $control = New-Object "Windows.Forms.$type"
        $control.Text = $text
        $control.SetBounds($x, $y, $width, $height)
        $review.Controls.Add($control)
        $control
    }

    $heading = Add-ReviewControl Label 'Review dependencies' 24 18 710 43
    $heading.Font = New-Object Drawing.Font('Segoe UI', 23, [Drawing.FontStyle]::Bold)
    $context = Add-ReviewControl Label "$($section.Name)  |  $($format.SelectedItem)" 26 67 708 26
    $context.ForeColor = $muted

    $null = Add-ReviewControl Label "Selected mods ($($selected.Count))" 26 103 768 25
    $selectedList = Add-ReviewControl ListBox '' 26 130 768 77
    $selectedList.HorizontalScrollbar = $true
    foreach ($mod in $selected) { $null = $selectedList.Items.Add($mod.Name) }

    $null = Add-ReviewControl Label "Requirements ($($plan.Requirements.Count))" 26 217 768 25
    $grid = Add-ReviewControl DataGridView '' 26 245 768 205
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.SelectionMode = 'FullRowSelect'
    $grid.EnableHeadersVisualStyles = $false
    $grid.BackgroundColor = $surface
    $grid.GridColor = $script:stepBackground
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $script:stepBackground
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $form.ForeColor
    $grid.DefaultCellStyle.BackColor = $surface
    $grid.DefaultCellStyle.ForeColor = $form.ForeColor
    $grid.DefaultCellStyle.SelectionBackColor = $accent
    $grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
    $grid.DefaultCellStyle.WrapMode = 'True'
    $grid.AutoSizeRowsMode = 'AllCells'
    foreach ($column in 'Requirement', 'Provided by', 'Required by mod', 'Status') {
        $null = $grid.Columns.Add($column, $column)
    }
    $grid.Columns[3].FillWeight = 58
    foreach ($requirement in $plan.Requirements) {
        $row = $grid.Rows.Add([object[]]@($requirement.Master, $requirement.Provider, $requirement.RequiredBy, $requirement.Status))
        $grid.Rows[$row].Cells[2].ToolTipText = $requirement.Plugin
    }

    $null = Add-ReviewControl Label 'Compatibility notes' 26 459 768 25
    $notes = Add-ReviewControl ListBox '' 26 486 768 66
    $notes.HorizontalScrollbar = $true
    foreach ($note in $plan.Notes) { $null = $notes.Items.Add($note) }
    if (!$plan.Notes.Count) { $null = $notes.Items.Add('No compatibility notes from this scan.') }
    foreach ($list in $selectedList, $notes) {
        $list.BackColor = $surface
        $list.ForeColor = $form.ForeColor
    }
    $include = Add-ReviewControl CheckBox "Include required mods ($($plan.Added.Count) to add)" 26 558 500 27
    $include.Checked = $plan.Added.Count -gt 0
    $include.Enabled = $include.Checked

    $back = Add-ReviewControl Button 'Back' 26 602 106 34
    $back.DialogResult = 'Cancel'
    $next = Add-ReviewControl Button 'Choose destination...' 606 601 188 38
    $next.DialogResult = 'OK'
    $next.FlatStyle = 'Flat'
    $next.BackColor = $accent
    $next.ForeColor = [Drawing.Color]::White
    $review.CancelButton = $back
    $review.AcceptButton = $next

    try {
        $choice = $review.ShowDialog($form)
        $includeRequired = $include.Checked
    } finally { $review.Dispose() }
    if ($choice -ne 'OK') {
        Set-GuidedStep 0
        $status.Text = 'Review canceled. Your mod selection is ready to edit.'
        return
    }
    $destination = Select-Folder 'Choose a destination outside the source modlist.'
    if (!$destination) {
        Set-GuidedStep 0
        $status.Text = 'No destination selected. Review the selection to continue.'
        return
    }
    if ($includeRequired) { $selected = $plan.Mods }
    Start-Export $destination $section $selected
}
$export.Add_Click({
    if (!$script:selectedNames.Count) {
        $status.Text = 'Select at least one mod to export.'
        return
    }
    $section = $script:sections[$separator.SelectedIndex]
    $selected = @($script:sectionMods | Where-Object { $script:selectedNames.Contains($_.Name) })

    $worker = [PowerShell]::Create()
    try {
        $allMods = @($script:sections | ForEach-Object { $_.Mods })
        $null = $worker.AddScript({
            param($ScriptPath, $Installed, $Selected, $Merged)
            . $ScriptPath -CoreOnly
            Get-DependencyPlan $Installed $Selected -Merged:$Merged
        }).AddArgument($scriptFile).AddArgument($allMods).AddArgument($selected).AddArgument($format.SelectedIndex -eq 1)
        $script:job = @{
            Kind = 'Scan'; Worker = $worker; Handle = $worker.BeginInvoke()
            Section = $section; Selected = $selected
        }
        foreach ($control in $controls) { $control.Enabled = $false }
        Set-GuidedStep 1
        $status.Text = 'Scanning for plugin dependencies...'
        $metrics.Text = ''
        $progress.Style = 'Marquee'
        $progress.Visible = $true
        $timer.Start()
    } catch {
        $worker.Dispose()
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, $form.Text)
    }
})

foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
    foreach ($folderName in 'Modlists', 'Wabbajack') {
        $directory = Join-Path $drive.Root $folderName
        foreach ($child in Get-ChildItem -LiteralPath $directory -Directory -ErrorAction SilentlyContinue) { Add-Install $child.FullName }
    }
}
if ($install.Items.Count) { $install.SelectedIndex = 0 }
[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
