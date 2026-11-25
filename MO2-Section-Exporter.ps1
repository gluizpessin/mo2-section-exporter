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
        $paths[$mod.Name] = $files
        $inputBytes += ($files | Measure-Object Length -Sum).Sum
    }

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

function Get-DependencyPlan($Installed, $Selected, [switch]$Merged) {
    $byMod = @{}
    $providers = @{}
    $gameMasters = @('Skyrim.esm','Update.esm','Dawnguard.esm','HearthFires.esm','Dragonborn.esm')
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
        foreach ($mod in $full) {
            foreach ($plugin in $byMod[$mod.Name]) {
                if ($Merged -and $visible[$plugin.Name] -ne $mod.Name) { continue }
                try { $masters = @(Read-Masters $plugin.FullName) }
                catch { $roundNotes.Add("Could not read $($plugin.Name) in $($mod.Name): $($_.Exception.Message)"); continue }
                foreach ($master in $masters) {
                    if ($master -in $gameMasters) { $roundNotes.Add("Destination game: $master"); continue }
                    $candidates = $providers[$master]
                    if (!$candidates) { $roundNotes.Add("Missing $master, required by $($plugin.Name)"); continue }
                    $included = @($candidates | Where-Object { $chosen.ContainsKey($_.Name) })
                    $active = @($candidates | Where-Object Enabled)
                    if ($included.Count -and ($Merged -or ($included | Where-Object Enabled))) { continue }
                    if ($candidates.Count -gt 1) {
                        $roundNotes.Add("Review providers for $master, required by $($plugin.Name): $($candidates.Name -join ', ')")
                    }
                    $provider = if ($active) { $active[-1] } else { $candidates[$candidates.Count - 1] }
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
    foreach ($mod in $full) {
        $skse = Join-Path $mod.Path 'SKSE\Plugins'
        if (Test-Path -LiteralPath $skse -PathType Container) {
            if (Get-ChildItem -LiteralPath $skse -File -Filter '*.dll' | Select-Object -First 1) {
                $notes.Add("SKSE DLL: $($mod.Name). Check Skyrim runtime and any additional requirements.")
            }
        }
    }
    foreach ($line in $roundNotes) { $notes.Add($line) }
    [pscustomobject]@{
        Mods = $full
        Added = @($full | Where-Object { $additions.ContainsKey($_.Name) } | ForEach-Object { $additions[$_.Name] })
        Notes = @($notes | Sort-Object -Unique)
    }
}

if ($CoreOnly) { return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = 'MO2 Section Exporter'
$form.ClientSize = New-Object Drawing.Size(820, 755)
$form.BackColor = [Drawing.ColorTranslator]::FromHtml('#11151D')
$form.ForeColor = [Drawing.ColorTranslator]::FromHtml('#EDF2FA')
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

$surface = [Drawing.ColorTranslator]::FromHtml('#202837')
$muted = [Drawing.ColorTranslator]::FromHtml('#ABB9CD')
$accent = [Drawing.ColorTranslator]::FromHtml('#86B8FF')

$title = Add-Control Label 'MO2 Section Exporter' 24 18 772 42
$title.Font = New-Object Drawing.Font('Segoe UI', 23, [Drawing.FontStyle]::Bold)
$subtitle = Add-Control Label 'Save selected mods and their requirements for your next modlist.' 26 64 770 26
$subtitle.ForeColor = $muted

$null = Add-Control Label 'MO2 installation' 26 107 600 23
$install = Add-Control ComboBox '' 26 133 650 30
$install.DropDownStyle = 'DropDownList'
$browse = Add-Control Button 'Browse...' 690 131 104 32
$null = Add-Control Label 'Profile' 26 179 360 23
$profile = Add-Control ComboBox '' 26 205 366 30
$profile.DropDownStyle = 'DropDownList'
$null = Add-Control Label 'Separator' 412 179 382 23
$separator = Add-Control ComboBox '' 412 205 382 30
$separator.DropDownStyle = 'DropDownList'

$selection = Add-Control Label 'Mods' 26 253 475 27
$selection.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$all = Add-Control Button 'Select all' 576 248 104 32
$none = Add-Control Button 'Clear' 690 248 104 32
$checks = Add-Control CheckedListBox '' 26 289 768 264
$checks.CheckOnClick = $true
$checks.HorizontalScrollbar = $true
$checks.BorderStyle = 'FixedSingle'

$null = Add-Control Label 'Export format' 26 575 118 24
$format = Add-Control ComboBox '' 155 570 300 31
$format.DropDownStyle = 'DropDownList'
$null = $format.Items.Add('Individual ZIPs')
$null = $format.Items.Add('Single merged ZIP')
$format.SelectedIndex = 0
$formatHelp = Add-Control Label '' 26 603 555 24
$formatHelp.ForeColor = $muted
$format.Add_SelectedIndexChanged({
    $formatHelp.Text = if ($format.SelectedIndex -eq 1) { 'Higher-priority selected mods win file conflicts. Plugin order is unchanged.' } else { '' }
})
$status = Add-Control Label 'Choose an installed MO2 modlist.' 26 630 540 46
$status.ForeColor = $muted
$progress = Add-Control ProgressBar '' 26 674 768 13
$progress.Style = 'Continuous'
$progress.Maximum = 100
$progress.Visible = $false
$metrics = Add-Control Label '' 26 695 768 28
$metrics.ForeColor = $muted
$export = Add-Control Button 'Export ZIPs...' 606 617 188 46
$export.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$export.Enabled = $false

foreach ($field in $install, $profile, $separator, $checks, $format) {
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
$export.ForeColor = $form.BackColor

function Update-Selection([int]$Count) {
    $selection.Text = "Mods  |  $Count of $($checks.Items.Count) selected"
    $export.Enabled = $Count -gt 0
    $all.Enabled = $Count -lt $checks.Items.Count
    $none.Enabled = $Count -gt 0
}

$checks.Add_ItemCheck({
    param($sender, $eventArgs)
    $count = $checks.CheckedItems.Count
    if ($eventArgs.CurrentValue -eq 'Checked') { $count-- }
    if ($eventArgs.NewValue -eq 'Checked') { $count++ }
    Update-Selection $count
})
$all.Add_Click({
    for ($i = 0; $i -lt $checks.Items.Count; $i++) { $checks.SetItemChecked($i, $true) }
})
$none.Add_Click({
    for ($i = 0; $i -lt $checks.Items.Count; $i++) { $checks.SetItemChecked($i, $false) }
})
Update-Selection 0

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
    $checks.Items.Clear()
    Update-Selection 0
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
    $checks.Items.Clear()
    Update-Selection 0
    $root = [string]$install.SelectedItem
    $directory = Join-Path (Join-Path $root 'profiles') ([string]$profile.SelectedItem)
    $script:sections = @(Get-Sections $directory (Join-Path $root 'mods'))
    foreach ($section in $script:sections) { $null = $separator.Items.Add($section.Name) }
    if ($separator.Items.Count) { $separator.SelectedIndex = 0 }
})
$separator.Add_SelectedIndexChanged({
    $checks.Items.Clear()
    Update-Selection 0
    if ($separator.SelectedIndex -lt 0) { return }
    $section = $script:sections[$separator.SelectedIndex]
    foreach ($mod in $section.Mods) {
        $label = if ($mod.Enabled) { $mod.Name } else { $mod.Name + ' (disabled in source)' }
        $null = $checks.Items.Add($label, $true)
    }
    Update-Selection $checks.CheckedItems.Count
    $status.Text = 'Uncheck any mods you want to skip. Choose a destination outside this modlist.'
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
$controls = @($install, $browse, $profile, $separator, $checks, $export, $all, $none, $format)
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:job) {
        $eventArgs.Cancel = $true
        $status.Text = 'An export is still running. Wait for it to finish before closing.'
    }
})
$timer.Add_Tick({
    $job = $script:job
    if (!$job) { return }
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
        $status.Text = "Verified ZIP archives: $($job.Count)."
        [void][Windows.Forms.MessageBox]::Show($form, "Export complete.$([Environment]::NewLine)$result", $form.Text)
    } catch {
        $status.Text = 'Export stopped.'
        $metrics.Text = 'Export incomplete  |  ' + $metrics.Text
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, $form.Text)
    } finally {
        $job.Worker.Dispose()
        $script:job = $null
        foreach ($control in $controls) { $control.Enabled = $true }
        Update-Selection $checks.CheckedItems.Count
    }
})
$export.Add_Click({
    if (!$checks.CheckedIndices.Count) {
        $status.Text = 'Select at least one mod to export.'
        return
    }
    $destination = Select-Folder 'Choose an existing destination outside the source installation.'
    if (!$destination) { return }
    $section = $script:sections[$separator.SelectedIndex]
    $selected = @($checks.CheckedIndices | ForEach-Object { $section.Mods[$_] })

    try {
        $allMods = @($script:sections | ForEach-Object { $_.Mods })
        $plan = Get-DependencyPlan $allMods $selected -Merged:($format.SelectedIndex -eq 1)
        $review = New-Object Windows.Forms.Form
        $review.Text = 'Export dependency preview'
        $review.ClientSize = New-Object Drawing.Size(690,450)
        $review.StartPosition = 'CenterParent'
        $review.Font = $form.Font
        $review.BackColor = $form.BackColor
        $review.ForeColor = $form.ForeColor
        $details = New-Object Windows.Forms.TextBox
        $details.Multiline = $true
        $details.ReadOnly = $true
        $details.ScrollBars = 'Both'
        $details.WordWrap = $false
        $details.BackColor = $surface
        $details.ForeColor = $form.ForeColor
        $details.SetBounds(14,14,662,375)
        $details.Text = (@("$($selected.Count) selected mods. $($plan.Added.Count) required mods found.",'', 'Required mods to add:') +
            $plan.Added + @('', 'Dependency notes:') + $plan.Notes) -join [Environment]::NewLine
        $review.Controls.Add($details)
        foreach ($buttonInfo in @(@('Include required mods','Yes',14), @('Selected mods only','No',226), @('Cancel','Cancel',548))) {
            $button = New-Object Windows.Forms.Button
            $button.Text = $buttonInfo[0]
            $button.DialogResult = $buttonInfo[1]
            $button.SetBounds($buttonInfo[2],401,128,35)
            if ($buttonInfo[1] -ne 'Cancel') { $button.Width = 195 }
            $review.Controls.Add($button)
            if ($buttonInfo[1] -eq 'Cancel') { $review.CancelButton = $button }
        }
        try { $choice = $review.ShowDialog($form) } finally { $review.Dispose() }
        if ($choice -notin 'Yes','No') { return }
        if ($choice -eq 'Yes') { $selected = $plan.Mods }
    } catch {
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Dependency scan failed')
        return
    }
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
        $status.Text = 'Checking selected mod files...'
        $progress.Value = 0
        $metrics.Text = ''
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
