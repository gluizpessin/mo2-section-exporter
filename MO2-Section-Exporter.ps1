param([switch]$CoreOnly)
$ErrorActionPreference = 'Stop'
$AppVersion = '0.1.8'
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
            $section.Mods.Add([pscustomobject]@{ Name = $name; Path = $path; Enabled = $enabled; Section = $section.Name })
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

function Export-Section($Source, $Destination, $Section, $Selected, $Profile, $Report, [switch]$Merged, [Threading.CancellationToken]$Cancellation = [Threading.CancellationToken]::None) {
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
        $Cancellation.ThrowIfCancellationRequested()
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
    $manifest.sha256 = [ordered]@{}
    $manifest.format = if ($Merged) { 'merged' } else { 'individual' }
    try {
        $jobs = if ($Merged) {
            $manifest.mergeWinners = [ordered]@{}
            $winningFiles = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($mod in $Selected) {
        $Cancellation.ThrowIfCancellationRequested()
                $manifest.mods += [ordered]@{ name = $mod.Name; enabled = $mod.Enabled }
                foreach ($file in $paths[$mod.Name]) {
                    $relative = $file.FullName.Substring($mod.Path.Length + 1).Replace('\', '/')
                    if ($relative -ieq 'meta.ini' -or $relative -match '(?i)\.mohidden(?:/|$)') { continue }
                    if ($winningFiles.ContainsKey($relative)) { $manifest.mergeWinners[$relative] = $mod.Name }
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
        $Cancellation.ThrowIfCancellationRequested()
                $filename = $mod.Name + '.zip'
                $manifest.mods += [ordered]@{ name = $mod.Name; archive = $filename; enabled = $mod.Enabled; section = $mod.Section }
                $entries = foreach ($file in $paths[$mod.Name]) {
                    [pscustomobject]@{ Relative = $file.FullName.Substring($mod.Path.Length + 1).Replace('\', '/'); File = $file }
                }
                [pscustomobject]@{ Name = $mod.Name; Archive = $filename; Files = @($entries) }
            }
        }
        [long]$totalWork = 0
        foreach ($job in $jobs) {
            $Cancellation.ThrowIfCancellationRequested()
            $totalWork += 2 * [long](($job.Files | ForEach-Object { $_.File.Length } | Measure-Object -Sum).Sum)
        }
        [long]$processed = 0
        $clock = [Diagnostics.Stopwatch]::StartNew()
        [long]$lastUpdate = -200
        & $Report ('#progress|0|{0}' -f $totalWork)
        foreach ($job in $jobs) {
            $Cancellation.ThrowIfCancellationRequested()
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
                                    $Cancellation.ThrowIfCancellationRequested()
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
                                $Cancellation.ThrowIfCancellationRequested()
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
            $Cancellation.ThrowIfCancellationRequested()
            $manifest.sha256[$filename] = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
            $Cancellation.ThrowIfCancellationRequested()
            [IO.File]::Move($partial, (Join-Path $folder $filename))
        }
        $Cancellation.ThrowIfCancellationRequested()
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $folder 'section.json') -Encoding UTF8
        & $Report ('#progress|{0}|{0}' -f $processed)
    } catch {
        $partialFiles = Get-ChildItem -LiteralPath $folder -File -Filter '*.partial'
        foreach ($file in $partialFiles) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
        if ($Cancellation.IsCancellationRequested) { throw [OperationCanceledException]::new("Export canceled. Any verified ZIPs are in $folder.") }
        throw "Export incomplete. Any verified ZIPs are in $folder. $($_.Exception.Message)"
    }
    $folder
}


function Read-Masters($Path, [IO.Stream]$ArchiveEntry) {
    if ($ArchiveEntry) {
        $source = [IO.BinaryReader]::new($ArchiveEntry)
        try {
            $prefix = $source.ReadBytes(24)
            if ($prefix.Length -ne 24) { throw 'Truncated TES4 header' }
            $length = [BitConverter]::ToUInt32($prefix, 4)
            if ($length -gt 4MB) { throw 'TES4 header exceeds preview limit' }
            $payload = $source.ReadBytes([int]$length)
            $stream = [IO.MemoryStream]::new([byte[]]($prefix + $payload))
        } finally { $source.Dispose() }
    } else { $stream = [IO.File]::OpenRead($Path) }
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


function Assert-ImportName([string]$Name) {
    if (!$Name -or $Name -match '[<>:"/\\|?*\x00-\x1f]|[. ]$' -or
        $Name -match '^(?:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)' -or $Name -in '.', '..') {
        throw "Invalid Windows file or folder name: $Name"
    }
}

function Get-DestinationReview($ProfilePath, $Mods, $IncomingFiles, $IncomingPlugins, $References) {
    $destPlugins = @{}
    $overrides = @{}
    $base = @($BaseGameMasters + '_ResourcePack.esl')
    $pluginState = @{}
    $pluginsFile = Join-Path (Split-Path $ProfilePath) 'plugins.txt'
    if (Test-Path -LiteralPath $pluginsFile -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($pluginsFile)) {
            if ($line -match '^(\*?)([^#].+\.(?:esp|esm|esl))$') {
                $pluginState[$Matches[2]] = $Matches[1] -eq '*'
            }
        }
    }
    foreach ($line in [IO.File]::ReadAllLines($ProfilePath)) {
        if ($line -notmatch '^\+(.+)$') { continue }
        $name = $Matches[1]
        if ($name -match '[\\/:]' -or $name -in '.', '..') { continue }
        $path = Join-Path $Mods $name
        $directory = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if (!$directory -or !$directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $path -File -Recurse) {
            $relative = $file.FullName.Substring($path.Length + 1).Replace('\','/')
            if ($relative -notmatch '/' -and $relative -match '\.(esp|esm|esl)$' -and !$destPlugins.ContainsKey($relative)) {
                $destPlugins[$relative] = $name
            }
            if ($IncomingFiles.ContainsKey($relative) -and !$overrides.ContainsKey($relative)) {
                $overrides[$relative] = $name
            }
        }
    }
    $dependencies = foreach ($reference in $References) {
        $master = $reference.Master
        $status = if ($master -in $base) { 'Base game' }
        elseif ($IncomingPlugins.ContainsKey($master)) { 'Included; check plugin activation' }
        elseif ($destPlugins.ContainsKey($master)) {
            if ($pluginState[$master]) { 'Active in destination' } else { 'Destination mod present; check plugin activation' }
        } else { 'Missing from enabled mods and bundle' }
        "$master | $status | required by $($reference.Plugin)"
    }
    $conflicts = foreach ($relative in @($overrides.Keys | Sort-Object)) {
        "$relative | $($IncomingFiles[$relative]) overrides $($overrides[$relative])"
    }
    [pscustomobject]@{ Dependencies = @($dependencies | Sort-Object -Unique); Conflicts = @($conflicts) }
}

function Get-DirectFiles($Source) {
    Assert-OrdinaryPath $Source
    $items = @(Get-ChildItem -LiteralPath $Source -Force -Recurse)
    if ($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1) {
        throw "Direct transfer does not support links or junctions in $Source."
    }
    $items | Where-Object { !$_.PSIsContainer -and !(Test-BaseGameFile $_.FullName.Substring($Source.Length + 1)) }
}

function Copy-DirectMod($Source, $Destination) {
    $files = @(Get-DirectFiles $Source)
    if (!$files.Count) { throw "No mod files to copy from $Source." }
    $excluded = @(Get-ChildItem -LiteralPath $Source -Force -File | Where-Object { Test-BaseGameFile $_.Name })
    $arguments = @($Source, $Destination, '/E', '/XJ', '/R:0', '/W:0', '/MT:8', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($excluded.Count) { $arguments += '/XF'; $arguments += @($excluded.FullName) }
    $output = & (Join-Path $env:WINDIR 'System32\robocopy.exe') @arguments
    if ($LASTEXITCODE -notin 0,1) { throw "Robocopy returned $LASTEXITCODE for $Source. $($output -join ' ')" }
    foreach ($file in $files) {
        $copy = Get-Item -LiteralPath (Join-Path $Destination $file.FullName.Substring($Source.Length + 1))
        if ($copy.Length -ne $file.Length) { throw "Incomplete copy: $($file.Name)" }
    }
    foreach ($file in $excluded) {
        if (Test-Path -LiteralPath (Join-Path $Destination $file.Name)) { throw "Stock file was copied: $($file.Name)" }
    }
}

function Get-ImportPlan($Package, $Target, $ProfileName, $SeparatorName, [switch]$Preview, [switch]$KeepSections, [ValidateSet('Block','Skip','Rename')][string]$DuplicateAction = 'Block', $DirectMods) {
    Assert-ImportName $SeparatorName
    Assert-ImportName $ProfileName
    $profile = Join-Path (Join-Path $Target 'profiles') $ProfileName
    $mods = Join-Path $Target 'mods'
    foreach ($path in $profile, $mods) { Assert-OrdinaryPath $path }
    $profilePath = Join-Path $profile 'modlist.txt'
    Assert-OrdinaryPath $profilePath
    if ($DirectMods) {
        $manifest = [pscustomobject]@{ format = 'individual' }
        $separator = $SeparatorName + '_separator'
        $jobs = @(foreach ($mod in $DirectMods) {
            Assert-OrdinaryPath $mod.Path
            if ((Test-Within $mod.Path $mods) -or (Test-Within $mods $mod.Path)) {
                throw 'Choose a different MO2 installation for direct transfer.'
            }
            [pscustomobject]@{Name=$mod.Name; DirectPath=$mod.Path; Enabled=$mod.Enabled; SourceSection=$mod.Section}
        })
    } else {
        Assert-OrdinaryPath $Package
        $manifestPath = Join-Path $Package 'section.json'
        $profilePath = Join-Path $profile 'modlist.txt'
        Assert-OrdinaryPath $manifestPath
        Assert-OrdinaryPath $profilePath
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($manifest.version -ne 1 -or $manifest.format -notin 'individual','merged' -or !@($manifest.mods).Count) {
            throw 'Choose an export folder with a supported section.json.'
        }
        $separator = $SeparatorName + '_separator'
        $jobs = @(if ($manifest.format -eq 'merged') {
            [pscustomobject]@{ Name = $SeparatorName + ' (Merged)'; Archive = [string]$manifest.archive; Enabled = $true }
        } else {
            foreach ($mod in $manifest.mods) {
                if ($mod.enabled -isnot [bool]) { throw 'Invalid enabled state in section.json.' }
                [pscustomobject]@{ Name = [string]$mod.name; Archive = [string]$mod.archive; Enabled = $mod.enabled; SourceSection = [string]$mod.section }
            }
        })
    
    }
    $existing = [IO.File]::ReadAllLines($profilePath)
    $occupied = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $existing) { if ($line -match '^[+-](.+)$') { $null = $occupied.Add($Matches[1]) } }
    foreach ($item in Get-ChildItem -LiteralPath $mods -Force) { $null = $occupied.Add($item.Name) }
    $decisions = [Collections.Generic.List[string]]::new()
    $jobs = @(foreach ($job in $jobs) {
        Assert-ImportName $job.Name
        if ($DuplicateAction -ne 'Block' -and $occupied.Contains($job.Name)) {
            if ($DuplicateAction -eq 'Skip') { $decisions.Add("Skipped $($job.Name); existing copy kept."); continue }
            $name = $job.Name
            $suffix = 1
            do {
                $job.Name = if ($suffix -eq 1) { "$name (Imported)" } else { "$name (Imported $suffix)" }
                $suffix++
            } while ($occupied.Contains($job.Name))
            $decisions.Add("$name imported as $($job.Name).")
        }
        $null = $occupied.Add($job.Name)
        $job
    })
    if (!$jobs.Count) { throw 'No incoming mods remain after skipping duplicates.' }
    $canKeep = $manifest.format -eq 'individual' -and @($jobs | Where-Object SourceSection | Select-Object -ExpandProperty SourceSection -Unique).Count -gt 1
    $layout = [Collections.Generic.List[object]]::new()
    $separatorNames = [Collections.Generic.List[string]]::new()
    if ($KeepSections -and $canKeep) {
        $previous = $null
        foreach ($job in $jobs) {
            $group = if ($job.SourceSection) { $job.SourceSection } else { 'Ungrouped' }
            if ($group -ne $previous) {
                $name = "$SeparatorName - "+$group+'_separator'
                $separatorNames.Add($name)
                $layout.Add('-'+$name)
                $previous = $group
            }
            $layout.Add($(if ($job.Enabled) { '+' } else { '-' }) + $job.Name)
        }
    } else {
        $separatorNames.Add($separator)
        $layout.Add('-'+$separator)
        foreach ($job in $jobs) { $layout.Add($(if ($job.Enabled) { '+' } else { '-' }) + $job.Name) }
    }
    $existing = [IO.File]::ReadAllLines($profilePath)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $collisions = [Collections.Generic.List[string]]::new()
    foreach ($name in @($separatorNames.ToArray()) + @($jobs.Name)) {
        Assert-ImportName $name
        if (!$names.Add($name) -or (Test-Path -LiteralPath (Join-Path $mods $name)) -or
            ($existing -contains "+$name") -or ($existing -contains "-$name")) {
            $collisions.Add($name)
        }
    }
    if ($collisions.Count -and !$Preview) {
        throw "A mod or separator already uses this name: $($collisions -join ', ')."
    }
    [long]$unpackedBytes = 0
    $incomingFiles = @{}
    $incomingPlugins = @{}
    $references = [Collections.Generic.List[object]]::new()
    $reviewNotes = [Collections.Generic.List[string]]::new()
    foreach ($job in $jobs) {
        if ($job.Name.EndsWith('_separator', [StringComparison]::OrdinalIgnoreCase)) { throw "Invalid mod name: $($job.Name)" }
        if ($job.DirectPath) {
            if ($Preview) {
                foreach ($file in Get-DirectFiles $job.DirectPath) {
                    $unpackedBytes += $file.Length
                    if (!$job.Enabled) { continue }
                    $relative = $file.FullName.Substring($job.DirectPath.Length + 1).Replace('\','/')
                    if ($relative -ieq 'meta.ini' -or $relative -match '\.mohidden(?:/|$)') { continue }
                    $incomingFiles[$relative] = $job.Name
                    if ($relative -match '^[^/]+\.(esp|esm|esl)$') {
                        $incomingPlugins[$relative] = $job.Name
                        try {
                            foreach ($master in @(Read-Masters $file.FullName)) {
                                $references.Add([pscustomobject]@{Master=$master;Plugin=$relative;Provider=$job.Name})
                            }
                        } catch { $reviewNotes.Add("Could not read plugin masters for $relative.") }
                    }
                }
            }
            continue
        }
        Assert-ImportName $job.Archive
        if ([IO.Path]::GetExtension($job.Archive) -ine '.zip') { throw 'Expected a ZIP archive.' }
        $archive = Join-Path $Package $job.Archive
        Assert-OrdinaryPath $archive
        if (!(Test-Path -LiteralPath $archive -PathType Leaf)) { throw "ZIP is missing: $($job.Archive)" }
        $job | Add-Member -NotePropertyName Hash -NotePropertyValue ''
        if ($null -ne $manifest.sha256) {
            $checksum = $manifest.sha256.PSObject.Properties[$job.Archive]
            if (!$checksum -or [string]$checksum.Value -notmatch '^[a-fA-F0-9]{64}$') {
                throw "Missing or invalid SHA-256 for $($job.Archive)."
            }
            $job.Hash = [string]$checksum.Value
        }
        if ($Preview) {
            $stream = [IO.File]::OpenRead($archive)
            try {
                if ($job.Hash) {
                    if ((Get-FileHash -InputStream $stream -Algorithm SHA256).Hash -ine $job.Hash) { throw "SHA-256 mismatch for $($job.Name)." }
                    $stream.Position = 0
                }
                $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
                try {
                    foreach ($entry in $zip.Entries) {
                        $unpackedBytes += $entry.Length
                        if (!$job.Enabled -or !$entry.Name) { continue }
                        $relative = $entry.FullName.Replace('\','/')
                        if ($relative -ieq 'meta.ini' -or $relative -match '\.mohidden(?:/|$)') { continue }
                        $incomingFiles[$relative] = $job.Name
                        if ($relative -match '^[^/]+\.(esp|esm|esl)$') {
                            $incomingPlugins[$relative] = $job.Name
                            try {
                                $pluginRefs = @(Read-Masters -ArchiveEntry $entry.Open())
                                foreach ($master in $pluginRefs) { $references.Add([pscustomobject]@{Master=$master;Plugin=$relative;Provider=$job.Name}) }
                            } catch { $reviewNotes.Add("Could not read plugin masters for $relative in $($job.Name).") }
                        }
                    }
                } finally { $zip.Dispose() }
            } finally { $stream.Dispose() }
        }
        $job.Archive = $archive
    }
    $review = if ($Preview) { Get-DestinationReview $profilePath $mods $incomingFiles $incomingPlugins @($references.ToArray() | Where-Object { $incomingPlugins[$_.Plugin] -eq $_.Provider }) }
    $winners = if ($Preview -and $manifest.mergeWinners) {
        @($manifest.mergeWinners.PSObject.Properties | ForEach-Object { "$($_.Name) | $($_.Value)" })
    }
    [pscustomobject]@{
        Decisions = $decisions.ToArray(); Review = $review; MergeWinners = @($winners | Where-Object { $_ }); ReviewNotes = $reviewNotes.ToArray()
        Mods = $mods; Profile = $profilePath; Existing = $existing; Separator = $separator; Jobs = $jobs
        Collisions = @($collisions.ToArray()); UnpackedBytes = $unpackedBytes; CanKeepSections = $canKeep; Layout = $layout.ToArray(); Separators = $separatorNames.ToArray()
        FreeBytes = (Get-Item -LiteralPath $mods).PSDrive.Free; HasChecksums = $null -ne $manifest.sha256
    }
}

function Assert-Mo2Closed {
    if (Get-Process -Name ModOrganizer -ErrorAction SilentlyContinue) {
        throw 'Close Mod Organizer 2 before importing.'
    }
}

function Import-Section($Package, $Target, $ProfileName, $SeparatorName, $Report, [switch]$KeepSections, [ValidateSet('Block','Skip','Rename')][string]$DuplicateAction = 'Block', $DirectMods) {
    Assert-Mo2Closed
    $plan = Get-ImportPlan $Package $Target $ProfileName $SeparatorName -KeepSections:$KeepSections -DuplicateAction $DuplicateAction -DirectMods $DirectMods
    $token = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $plan.Mods ('.mo2-import-' + $token)
    $newProfile = $plan.Profile + '.' + $token + '.tmp'
    $backup = $plan.Profile + '.before-import-' + $token + '.bak'
    $published = [Collections.Generic.List[string]]::new()
    $null = New-Item -Path $stage -ItemType Directory
    try {
        foreach ($job in $plan.Jobs) {
            & $Report "Extracting $($job.Name)..."
            $modFolder = Join-Path $stage $job.Name
            $null = New-Item -Path $modFolder -ItemType Directory
            if ($job.DirectPath) {
                & $Report "Copying $($job.Name)..."
                Copy-DirectMod $job.DirectPath $modFolder
                continue
            }
            $archiveStream = [IO.File]::OpenRead($job.Archive)
            try {
                if ($job.Hash) {
                    & $Report "Verifying $($job.Name)..."
                    if ((Get-FileHash -InputStream $archiveStream -Algorithm SHA256).Hash -ine $job.Hash) {
                        throw "SHA-256 mismatch for $($job.Name). The ZIP differs from the original export."
                    }
                    $archiveStream.Position = 0
                }
                $zip = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Read, $true)
                try {
                if (!$zip.Entries.Count) { throw "ZIP is empty: $($job.Archive)" }
                foreach ($entry in $zip.Entries) {
                    $entryPath = $entry.FullName.Replace('\','/')
                    $isDirectory = $entryPath.EndsWith('/')
                    $parts = $entryPath.TrimEnd('/').Split('/')
                    foreach ($part in $parts) { Assert-ImportName $part }
                    $output = Join-Path $modFolder ($parts -join '\')
                    if (!(Test-Within $output $modFolder)) { throw 'ZIP entry points outside its mod folder.' }
                    if ($isDirectory) { $null = [IO.Directory]::CreateDirectory($output); continue }
                    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output))
                    $input = $entry.Open()
                    try {
                        $file = [IO.File]::Open($output, [IO.FileMode]::CreateNew)
                        try {
                            $input.CopyTo($file)
                            if ($file.Length -ne $entry.Length) { throw "Incomplete ZIP entry: $entryPath" }
                        } finally { $file.Dispose() }
                    } finally { $input.Dispose() }
                }
                } finally { $zip.Dispose() }
            } finally { $archiveStream.Dispose() }
        }
        foreach ($separator in $plan.Separators) {
            $separatorFolder = Join-Path $stage $separator
            $null = New-Item -Path $separatorFolder -ItemType Directory
            [IO.File]::WriteAllLines((Join-Path $separatorFolder 'meta.ini'), [string[]]@('[General]','modid=0','category="-1,"'))
        }
        $lines = $plan.Layout
        [array]::Reverse($lines)
        $start = 0
        while ($start -lt $plan.Existing.Count -and $plan.Existing[$start] -match '^(#|\s*$)') { $start++ }
        $combined = @($plan.Existing | Select-Object -First $start) + $lines + @($plan.Existing | Select-Object -Skip $start)
        [IO.File]::WriteAllLines($newProfile, [string[]]$combined, [Text.UTF8Encoding]::new($false))
        Assert-Mo2Closed
        $current = [IO.File]::ReadAllLines($plan.Profile)
        if (($current -join "`n") -cne ($plan.Existing -join "`n")) { throw 'The destination profile changed during import.' }
        foreach ($name in @($plan.Separators) + @($plan.Jobs.Name)) {
            $output = Join-Path $plan.Mods $name
            [IO.Directory]::Move((Join-Path $stage $name), $output)
            $published.Add($name)
        }
        [IO.File]::Replace($newProfile, $plan.Profile, $backup)
        [pscustomobject]@{ Count = $plan.Jobs.Count; Backup = $backup; Separator = $SeparatorName }
    } catch {
        foreach ($name in $published) {
            [IO.Directory]::Move((Join-Path $plan.Mods $name), (Join-Path $stage $name))
        }
        throw
    } finally {
        if ([IO.File]::Exists($newProfile)) { [IO.File]::Delete($newProfile) }
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($CoreOnly) { return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$script:codes = @('en','zh','hi','es','ar','fr','bn','pt','ru','id')
$script:windowsLanguage = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
if ($script:windowsLanguage -notin $script:codes) { $script:windowsLanguage = 'en' }
$script:language = $script:windowsLanguage
$script:languageChoice = 0
$script:translations = @{}
foreach ($line in ('What would you like to do?|??????|?? ???? ???? ????? ????|�Qu� quieres hacer?|???? ???? ?? ?????|Que souhaitez-vous faire ?|???? ?? ???? ????|O que voc� quer fazer?|??? ?? ?????? ????????|Apa yang ingin Anda lakukan?
Import section|????|?????? ???? ????|Importar secci�n|??????? ???|Importer une section|????? ?????? ????|Importar se��o|?????? ???????|Impor bagian
Export section|????|?????? ??????? ????|Exportar secci�n|????? ???|Exporter une section|????? ??????? ????|Exportar se��o|??????? ???????|Ekspor bagian
Default export folder|???????|???????? ??????? ???????|Carpeta de exportaci�n predeterminada|???? ??????? ?????????|Dossier d''exportation par d�faut|?????? ??????? ???????|Pasta padr�o de exporta��o|????? ???????? ?? ?????????|Folder ekspor bawaan
Change...|??...|?????...|Cambiar...|?????...|Modifier.|???????? ????...|Alterar.|????????.|Ubah...
Dark mode|????|???? ???|Modo oscuro|????? ??????|Mode sombre|????? ???|Modo escuro|?????? ?????|Mode gelap
Light mode|????|????? ???|Modo claro|????? ??????|Mode clair|???? ???|Modo claro|??????? ?????|Mode terang
Browse...|??...|??????? ????...|Examinar.|???????...|Parcourir.|?????? ????...|Procurar.|?????.|Telusuri...
Profile|????|?????????|Perfil|??? ???????|Profil|????????|Perfil|???????|Profil
Separator|???|??????|Separador|??????|S�parateur|??????|Separador|???????????|Pemisah
MO2 installation|MO2 ??|MO2 ??????????|Instalaci�n de MO2|????? MO2|Installation de MO2|MO2 ?????????|Instala��o do MO2|????????? MO2|Instalasi MO2
Filter by mod name|???????|??? ??? ?? ??????|Filtrar por nombre|????? ??? ??? ?????|Filtrer par nom|???? ??? ????? ??????? ????|Filtrar por nome|?????? ?? ?????|Filter berdasarkan nama
Select shown|?????|????? ?? ?????|Seleccionar visibles|????? ??????|S�lectionner les �l�ments visibles|???????????? ???????? ????|Selecionar vis�veis|??????? ???????|Pilih yang terlihat
Clear shown|?????|????? ?? ?????|Deseleccionar visibles|????? ????? ??????|D�s�lectionner les �l�ments visibles|????????????? ???????? ????|Desmarcar vis�veis|????? ????? ???????|Hapus pilihan terlihat
Export format|????|??????? ???????|Formato de exportaci�n|???? ???????|Format d''exportation|??????? ???????|Formato de exporta��o|?????? ????????|Format ekspor
Individual ZIPs|?? ZIP|???-??? ZIP|ZIP individuales|????? ZIP ??????|ZIP individuels|???? ZIP|ZIPs individuais|????????? ZIP|ZIP terpisah
Single merged ZIP|???? ZIP|?? ??????? ZIP|Un ZIP combinado|??? ZIP ????|Un seul ZIP fusionn�|???? ???????? ZIP|Um ZIP mesclado|???? ???????????? ZIP|Satu ZIP gabungan
Review dependencies before export|????????|??????? ?? ???? ?????????? ?????|Revisar dependencias antes de exportar|?????? ???????? ??? ???????|V�rifier les d�pendances avant l''exportation|???????? ??? ???????? ?????|Revisar depend�ncias antes de exportar|????????? ??????????? ????? ?????????|Tinjau dependensi sebelum ekspor
Review selection|????|??? ?? ??????? ????|Revisar selecci�n|?????? ???????|V�rifier la s�lection|???????? ?????????? ????|Revisar sele��o|????????? ?????|Tinjau pilihan
Export ZIPs...|?? ZIP...|ZIP ??????? ????...|Exportar ZIP.|????? ZIP...|Exporter les ZIP.|ZIP ??????? ????...|Exportar ZIPs.|??????? ZIP.|Ekspor ZIP...
Cancel export|????|??????? ???? ????|Cancelar exportaci�n|????? ???????|Annuler l''exportation|??????? ????? ????|Cancelar exporta��o|???????? ???????|Batalkan ekspor
Review dependencies|?????|?????????? ?????|Revisar dependencias|?????? ????????|V�rifier les d�pendances|???????? ?????|Revisar depend�ncias|????????? ???????????|Tinjau dependensi
Compatibility notes|?????|?????? ??????????|Notas de compatibilidad|??????? ???????|Notes de compatibilit�|??????????? ???|Notas de compatibilidade|?????????? ? ?????????????|Catatan kompatibilitas
Requirement|???|????????|Requisito|???????|D�pendance|?????????????|Requisito|???????????|Persyaratan
Provided by|???|???????|Proporcionado por|?????|Fourni par|??????????|Fornecido por|?????????????|Disediakan oleh
Required by mod|????????|?????? ???? ???|Mod que lo requiere|????? ???? ??????|Mod qui en d�pend|?? ??? ????????|Mod que exige|????????? ???|Mod yang memerlukan
Status|??|??????|Estado|??????|�tat|??????|Status|??????|Status
Cancel|??|???? ????|Cancelar|?????|Annuler|????? ????|Cancelar|??????|Batal
Back|??|????|Atr�s|????|Retour|???? ???|Voltar|?????|Kembali
Choose destination...|???????...|?????? ?????...|Elegir destino.|?????? ??????...|Choisir la destination.|??????? ???? ???...|Escolher destino.|??????? ?????.|Pilih tujuan...
Import a saved section|????????|????? ??? ?????? ???? ????|Importar una secci�n guardada|??????? ??? ?????|Importer une section enregistr�e|???????? ????? ?????? ????|Importar se��o salva|?????? ???????????? ???????|Impor bagian tersimpan
Export folder containing section.json and ZIPs|?? section.json ? ZIP ????|section.json ?? ZIP ???? ???????|Carpeta con section.json y los ZIP|???? ????? ??? section.json ?????? ZIP|Dossier contenant section.json et les ZIP|section.json ? ZIP ???? ???????|Pasta com section.json e os ZIPs|????? ? section.json ? ZIP|Folder berisi section.json dan ZIP
Destination MO2 installation|?? MO2 ??|?????? MO2 ??????????|Instalaci�n de MO2 de destino|????? MO2 ??????|Installation MO2 de destination|??????? MO2 ?????????|Instala��o de destino do MO2|??????? ????????? MO2|Instalasi MO2 tujuan
Destination profile|??????|?????? ?????????|Perfil de destino|??? ????? ??????|Profil de destination|??????? ????????|Perfil de destino|??????? ???????|Profil tujuan
New separator name|??????|?? ?????? ?? ???|Nombre del nuevo separador|??? ?????? ??????|Nom du nouveau s�parateur|???? ???????? ???|Nome do novo separador|??? ?????? ???????????|Nama pemisah baru
Update and open|?????|????? ???? ?? ?????|Actualizar y abrir|????? ????|Mettre � jour et ouvrir|????? ??? ?????|Atualizar e abrir|???????? ? ???????|Perbarui dan buka
Hide|??|??????|Ocultar|?????|Masquer|?????|Ocultar|??????|Sembunyikan
Language|??|????|Idioma|?????|Langue|????|Idioma|????|Bahasa
Windows default|Windows ??|Windows ????????|Predeterminado de Windows|??????? Windows|Langue de Windows|Windows ??????|Padr�o do Windows|??? ? Windows|Bawaan Windows' -split '\r?\n')) {
    $parts = $line.Split('|')
    if ($parts.Count -ne 10) { throw 'Invalid translation row.' }
    $script:translations[$parts[0]] = $parts
}
foreach ($line in ('More sections...|????.|?? ??????.|M�s secciones.|????? ????.|Plus de sections.|??? ?????.|Mais se��es.|?????? ???????.|Bagian lainnya.
Apply|??|???? ????|Aplicar|?????|Appliquer|??????? ????|Aplicar|?????????|Terapkan
Recreate original separators|??????|??? ?????? ??? ?????|Recrear separadores originales|????? ????? ??????? ???????|Recr�er les s�parateurs d''origine|??? ?????? ??????? ???? ????|Recriar separadores originais|?????????? ???????? ???????????|Buat ulang pemisah asli
Preview.|??.|???????????.|Vista previa.|??????.|Aper�u.|??????????.|Pr�via.|????????????.|Pratinjau.
Import preview|????|???? ?? ???????????|Vista previa de importaci�n|?????? ?????????|Aper�u de l''importation|??????? ??????????|Pr�via da importa��o|???????????? ???????|Pratinjau impor
Checking selected mod files...|??????????.|???? ?? ??? ??????? ????? ?? ??? ???.|Comprobando archivos seleccionados.|???? ??? ????? ??????? ???????.|V�rification des fichiers s�lectionn�s.|????????? ?? ???? ??????? ??? ?????.|Verificando arquivos dos mods selecionados.|???????? ????????? ?????? ?????.|Memeriksa file mod yang dipilih.
Scanning for plugin dependencies...|?????????.|?????? ?????????? ???? ?? ??? ???.|Buscando dependencias de plugins.|???? ????? ?? ?????? ????????.|Recherche des d�pendances des plugins.|????????? ???????? ????? ?????.|Buscando depend�ncias dos plugins.|????? ???????????? ????????.|Memindai dependensi plugin.
Canceling export...|??????.|??????? ???? ???? ?? ??? ??.|Cancelando la exportaci�n.|???? ????? ???????.|Annulation de l''exportation.|??????? ????? ??? ?????.|Cancelando a exporta��o.|?????? ????????.|Membatalkan ekspor.
Export stopped.|??????|??????? ??? ????|Exportaci�n detenida.|???? ???????.|Exportation interrompue.|??????? ???? ???????|Exporta��o interrompida.|??????? ??????????.|Ekspor dihentikan.
Select at least one mod to export.|??????????????|??????? ?? ??? ?? ?? ?? ?? ??? ??????|Selecciona al menos un mod para exportar.|???? ????? ?????? ??? ????? ???????.|S�lectionnez au moins un mod � exporter.|???????? ???? ????? ???? ?? ???? ????|Selecione pelo menos um mod para exportar.|???????? ???? ?? ???? ??? ??? ????????.|Pilih setidaknya satu mod untuk diekspor.
Checking import files...|????????.|???? ??????? ????? ?? ??? ???.|Comprobando archivos de importaci�n.|???? ??? ????? ?????????.|V�rification des fichiers � importer.|??????? ???? ??????? ??? ?????.|Verificando arquivos da importa��o.|???????? ?????? ???????.|Memeriksa file impor.
Close Mod Organizer 2 before importing.|???? Mod Organizer 2?|???? ?? ???? Mod Organizer 2 ??? ?????|Cierra Mod Organizer 2 antes de importar.|???? Mod Organizer 2 ??? ?????????.|Fermez Mod Organizer 2 avant l''importation.|??????? ??? Mod Organizer 2 ???? ?????|Feche o Mod Organizer 2 antes de importar.|???????? Mod Organizer 2 ????? ????????.|Tutup Mod Organizer 2 sebelum mengimpor.
Compressing {0}|???? {0}|{0} ???????? ???? ?? ??? ??|Comprimiendo {0}|???? ??? {0}|Compression de {0}|{0} ??????? ?????|Compactando {0}|?????? {0}|Mengompresi {0}
Verifying {0}|???? {0}|{0} ???????? ???? ?? ??? ??|Verificando {0}|???? ?????? ?? {0}|V�rification de {0}|{0} ????? ?????|Verificando {0}|???????? {0}|Memverifikasi {0}
Extracting {0}|???? {0}|{0} ?????? ?? ??? ??|Extrayendo {0}|???? ??????? {0}|Extraction de {0}|{0} ???????? ??? ?????|Extraindo {0}|?????????? {0}|Mengekstrak {0}
The destination has insufficient free space.|????????????|?????? ?? ???????? ???? ??? ???? ???|El destino no tiene suficiente espacio libre.|??????? ????? ?? ?????? ??? ?????.|L''espace libre est insuffisant dans la destination.|???????? ???????? ???? ?????? ????|O destino n�o tem espa�o livre suficiente.|? ????? ?????????? ???????????? ?????????? ?????.|Ruang kosong di tujuan tidak cukup.
Older export. ZIP checksums are unavailable.|????,? ZIP ????|?????? ???????? ZIP ????? ?????? ???? ????|Exportaci�n antigua. No hay sumas de verificaci�n ZIP.|????? ????. ??? ?????? ?????? ZIP ??? ??????.|Ancienne exportation. Sommes de contr�le ZIP indisponibles.|?????? ???????? ZIP ?????? ????|Exporta��o antiga. Checksums dos ZIPs indispon�veis.|?????? ???????. ??????????? ????? ZIP ??????????.|Ekspor lama. Checksum ZIP tidak tersedia.
ZIP checksums will be verified during import.|?????? ZIP ????|???? ?? ????? ZIP ????? ????? ???????|Se verificar�n las sumas de los ZIP al importar.|???? ?????? ?? ??? ZIP ????? ?????????.|Les sommes de contr�le ZIP seront v�rifi�es � l''importation.|??????? ???? ZIP ?????? ????? ????|Os checksums dos ZIPs ser�o verificados na importa��o.|??????????? ????? ZIP ????? ????????? ??? ???????.|Checksum ZIP akan diperiksa saat impor.
Name collisions|????|??? ?????|Conflictos de nombres|????? ???????|Conflits de noms|????? ?????|Conflitos de nomes|????????? ????|Konflik nama
Destination profile|??????|?????? ?????????|Perfil de destino|??? ????? ??????|Profil de destination|??????? ????????|Perfil de destino|??????? ???????|Profil tujuan
New separators|????|?? ??????|Separadores nuevos|??????? ???????|Nouveaux s�parateurs|???? ??????|Novos separadores|????? ???????????|Pemisah baru
Mods|??|???|Mods|???????|Mods|??|Mods|????|Mod
Estimated extraction size|??????|???????? ????????? ????|Tama�o estimado de extracci�n|????? ???????? ??? ?????????|Taille d''extraction estim�e|?????????? ???????? ????|Tamanho estimado da extra��o|????????? ????? ??????????|Perkiraan ukuran ekstraksi
Destination free space|??????|?????? ?? ???? ???|Espacio libre en el destino|??????? ????? ?? ??????|Espace libre dans la destination|???????? ???? ??????|Espa�o livre no destino|????????? ????? ? ????? ??????????|Ruang kosong di tujuan' -split '\r?\n')) {
    $parts = $line.Split('|')
    if ($parts.Count -ne 10) { throw 'Invalid translation row.' }
    $script:translations[$parts[0]] = $parts
}
$script:translations['Export & import'] = @(
    'Export & import','?????','??????? ?? ????','Exportar e importar','??????? ??????????',
    'Exporter et importer','??????? ? ??????','Exportar e importar','??????? ? ??????','Ekspor dan impor'
)
function Get-UiText([string]$text) {
    $index = [array]::IndexOf($script:codes, $script:language)
    if ($index -gt 0 -and $script:translations.ContainsKey($text)) { return $script:translations[$text][$index] }
    $text
}
function Get-UiMessage([string]$Message) {
    if ($Message -match '^(Compressing|Verifying|Extracting) (.+?)(?:\.\.\.)?$') {
        return (Get-UiText ($Matches[1] + ' {0}')) -f $Matches[2]
    }
    Get-UiText $Message
}

function Update-ControlLanguage($window) {
    $window.RightToLeft = if ($script:language -eq 'ar') { 'Yes' } else { 'No' }
    foreach ($control in $window.Controls) {
        if ($control.Tag -is [string] -and $control.Tag) { $control.Text = Get-UiText $control.Tag }
    }
}


$form = New-Object Windows.Forms.Form
$form.Text = 'MO2 Section Exporter'
$form.ClientSize = New-Object Drawing.Size(820, 807)
$form.BackColor = [Drawing.ColorTranslator]::FromHtml('#F3F6FA')
$form.ForeColor = [Drawing.ColorTranslator]::FromHtml('#17243A')
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'

function Add-Control($Type, $Text, $X, $Y, $Width, $Height) {
    $control = New-Object "Windows.Forms.$Type"
    $control.Tag = $Text
    $control.Text = Get-UiText $Text
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
$separator = Add-Control ComboBox '' 412 240 243 30
$chooseSections = Add-Control Button 'More sections...' 666 236 128 36
$chooseSections.Anchor = 'Top,Right'
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

$formatLabel = Add-Control Label 'Export format' 26 586 118 24
$format = Add-Control ComboBox '' 155 581 300 31
$format.DropDownStyle = 'DropDownList'
$null = $format.Items.Add('Individual ZIPs')
$null = $format.Items.Add('Single merged ZIP')
$format.SelectedIndex = 0
$formatHelp = Add-Control Label '' 26 639 555 24
$formatHelp.ForeColor = $muted
$format.Add_SelectedIndexChanged({
    $formatHelp.Text = if ($format.SelectedIndex -eq 1) { 'Higher-priority selected mods win file conflicts. Plugin order is unchanged.' } else { '' }
})
$status = Add-Control Label 'Choose an installed MO2 modlist.' 26 663 540 40
$status.ForeColor = $muted
$progress = Add-Control ProgressBar '' 26 704 768 13
$progress.Style = 'Continuous'
$progress.Maximum = 100
$progress.Visible = $false
$metrics = Add-Control Label '' 26 725 768 28
$metrics.ForeColor = $muted
$versionLabel = Add-Control Label "v$AppVersion" 26 772 120 24
$versionLabel.ForeColor = $muted
$reviewToggle = Add-Control CheckBox 'Review dependencies before export' 26 612 420 26
$reviewToggle.Checked = $true
$cancelExport = Add-Control Button 'Cancel export' 606 646 188 46
$cancelExport.Visible = $false
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

$reviewToggle.Add_CheckedChanged({
    $export.Text = if ($reviewToggle.Checked) { Get-UiText 'Review selection' } elseif ($script:exportThenImport) { Get-UiText 'Choose destination...' } else { Get-UiText 'Export ZIPs...' }
})
foreach ($control in $install,$search,$separator) { $control.Anchor = 'Top,Left,Right' }
foreach ($control in $theme,$browse,$all,$none) { $control.Anchor = 'Top,Right' }
foreach ($control in $form.Controls) {
    if ($control.Top -ge 575) { $control.Anchor = 'Bottom,Left' }
}
$checks.Anchor = 'Top,Bottom,Left,Right'
foreach ($control in $progress,$status,$metrics,$formatHelp) { $control.Anchor = 'Bottom,Left,Right' }
$export.Anchor = 'Bottom,Right'
$cancelExport.Anchor = 'Bottom,Right'
$cancelExport.Add_Click({
    if ($script:job -and $script:job.Cancellation) {
        $script:job.Cancellation.Cancel()
        $cancelExport.Enabled = $false
        $status.Text = Get-UiText 'Canceling export...'
    }
})
$script:darkMode = $false
function Set-AppTheme([bool]$Dark) {
    $script:darkMode = $Dark
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
    foreach ($control in $subtitle, $formatHelp, $status, $metrics, $versionLabel) { $control.ForeColor = $muted }
    foreach ($control in $install, $profile, $separator, $checks, $format, $search, $browse, $all, $none, $theme, $cancelExport) {
        $control.ForeColor = $form.ForeColor
        $control.BackColor = $surface
    }
    $export.BackColor = $accent
    $theme.Text = if ($script:darkMode) { Get-UiText 'Light mode' } else { Get-UiText 'Dark mode' }
    Set-GuidedStep $script:currentStep
}
function Switch-Theme { Set-AppTheme (!$script:darkMode) }

function Get-WindowsAppDarkMode {
    $personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $value = (Get-ItemProperty -LiteralPath $personalize -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
    return ($null -ne $value -and $value -eq 0)
}

$theme.Add_Click({ Switch-Theme })
Set-AppTheme (Get-WindowsAppDarkMode)
$theme.FlatStyle = 'Flat'
$theme.FlatAppearance.BorderSize = 0
$theme.BackColor = $surface
$script:selectedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:sectionMods = @()
$script:visibleMods = @()
$script:refreshingList = $false

function Update-Selection {
    $count = $script:selectedNames.Count
    $selection.Text = "$(Get-UiText 'Mods')  |  $count of $($script:sectionMods.Count) selected  |  $($script:visibleMods.Count) shown"
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

$script:settingsKey = 'HKCU:\Software\MO2SectionExporter'
$script:exportDestination = [string](Get-ItemProperty -LiteralPath $script:settingsKey -Name ExportDestination -ErrorAction SilentlyContinue).ExportDestination

function Set-ExportDestination($Owner) {
    if (!('Mo2Exporter.FolderPicker' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Mo2Exporter {
    public static class FolderPicker {
        [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
        private class OpenDialog {}
        [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface Dialog {
            [PreserveSig] int Show(IntPtr owner);
            void SetFileTypes(uint count, IntPtr specs);
            void SetFileTypeIndex(uint index);
            void GetFileTypeIndex(out uint index);
            void Advise(IntPtr events, out uint cookie);
            void Unadvise(uint cookie);
            void SetOptions(uint options);
            void GetOptions(out uint options);
            void SetDefaultFolder(Item folder);
            void SetFolder(Item folder);
            void GetFolder(out Item folder);
            void GetCurrentSelection(out Item item);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
            void GetFileName(out IntPtr name);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
            void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
            void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            void GetResult(out Item item);
        }
        [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface Item {
            void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
            void GetParent(out Item parent);
            void GetDisplayName(uint form, out IntPtr name);
        }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out Item item);

        public static string Pick(IntPtr owner, string initialFolder) {
            var dialog = (Dialog)new OpenDialog();
            Item initial = null, selected = null;
            try {
                uint options;
                dialog.GetOptions(out options);
                dialog.SetOptions(options | 0x20 | 0x40 | 0x800); // PickFolders, ForceFileSystem, PathMustExist
                dialog.SetTitle("Choose export destination");
                if (System.IO.Directory.Exists(initialFolder)) {
                    var iid = typeof(Item).GUID;
                    SHCreateItemFromParsingName(initialFolder, IntPtr.Zero, ref iid, out initial);
                    dialog.SetFolder(initial);
                }
                int result = dialog.Show(owner);
                if (result == unchecked((int)0x800704C7)) return null;
                Marshal.ThrowExceptionForHR(result);
                dialog.GetResult(out selected);
                IntPtr path;
                selected.GetDisplayName(0x80058000, out path);
                try { return Marshal.PtrToStringUni(path); }
                finally { Marshal.FreeCoTaskMem(path); }
            } finally {
                if (selected != null) Marshal.ReleaseComObject(selected);
                if (initial != null) Marshal.ReleaseComObject(initial);
                Marshal.ReleaseComObject(dialog);
            }
        }
    }
}
'@
    }
    $path = [Mo2Exporter.FolderPicker]::Pick($Owner.Handle, $script:exportDestination)
    if (!$path) { return }
    Assert-OrdinaryPath $path
    $null = New-Item -Path $script:settingsKey -Force
    Set-ItemProperty -LiteralPath $script:settingsKey -Name ExportDestination -Value $path
    $script:exportDestination = $path
}

function Get-ExportDestination($Owner, $Source) {
    try {
        if ([IO.Directory]::Exists($script:exportDestination)) {
            if (!(Test-Within $script:exportDestination $Source)) { return $script:exportDestination }
            [void][Windows.Forms.MessageBox]::Show($Owner, 'Choose an export folder outside the source installation.', $Owner.Text)
        }
        $previous = $script:exportDestination
        Set-ExportDestination $Owner
        if ($script:exportDestination -ne $previous -and
            !(Test-Within $script:exportDestination $Source)) { return $script:exportDestination }
        if ($script:exportDestination -ne $previous) {
            [void][Windows.Forms.MessageBox]::Show($Owner, 'The selected folder is inside the source installation. Change the export destination before continuing.', $Owner.Text)
        }
    } catch {
        [void][Windows.Forms.MessageBox]::Show($Owner, $_.Exception.Message, $Owner.Text)
    }
}

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
$script:sectionIndexes = @()
function Set-SectionSelection($Indexes, [switch]$RetainSelection) {
    $previous = @($script:sectionMods | ForEach-Object Name)
    $script:sectionIndexes = @($Indexes | Sort-Object -Unique)
    $script:sectionMods = @(foreach ($index in $script:sectionIndexes) { $script:sections[$index].Mods.ToArray() })
    if ($RetainSelection) {
        $names = @($script:sectionMods | ForEach-Object Name)
        $script:selectedNames.RemoveWhere([Predicate[string]]{ param($name); $name -notin $names }) | Out-Null
    } else { $script:selectedNames.Clear() }
    foreach ($mod in $script:sectionMods) {
        if (!$RetainSelection -or $mod.Name -notin $previous) { $null = $script:selectedNames.Add($mod.Name) }
    }
    $chooseSections.Text = if ($script:sectionIndexes.Count -gt 1) { "$($script:sectionIndexes.Count) selected" } else { Get-UiText 'More sections...' }
    Refresh-ModList
}
$separator.Add_SelectedIndexChanged({
    if ($separator.SelectedIndex -lt 0) { Set-SectionSelection @(); return }
    Set-SectionSelection @($separator.SelectedIndex)
    $search.Clear()
})
$chooseSections.Add_Click({
    if (!$script:sections.Count) { return }
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = Get-UiText 'More sections...'
    $dialog.ClientSize = New-Object Drawing.Size(560,440)
    $dialog.MinimumSize = $dialog.Size
    $dialog.StartPosition = 'CenterParent'
    $dialog.BackColor = $form.BackColor
    $dialog.ForeColor = $form.ForeColor
    $dialog.Font = $form.Font
    $items = New-Object Windows.Forms.CheckedListBox
    $items.SetBounds(16,16,528,365)
    $items.Anchor = 'Top,Bottom,Left,Right'
    $items.CheckOnClick = $true
    $items.BackColor = $surface
    $items.ForeColor = $form.ForeColor
    for ($i=0; $i -lt $script:sections.Count; $i++) {
        $null = $items.Items.Add($script:sections[$i].Name, $i -in $script:sectionIndexes)
    }
    $dialog.Controls.Add($items)
    $done = New-Object Windows.Forms.Button
    $done.Text = Get-UiText 'Apply'
    $done.DialogResult = 'OK'
    $done.SetBounds(414,391,130,34)
    $done.Anchor = 'Bottom,Right'
    $dialog.Controls.Add($done)
    try {
        if ($dialog.ShowDialog($form) -eq 'OK' -and $items.CheckedIndices.Count) {
            Set-SectionSelection @($items.CheckedIndices) -RetainSelection
        }
    } finally { $dialog.Dispose() }
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
$controls = @($install, $browse, $profile, $separator, $checks, $export, $all, $none, $format, $search, $reviewToggle, $chooseSections)
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
            $status.Text = Get-UiMessage $message
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
        $status.Text = if ($job.Cancellation.IsCancellationRequested) { 'Export canceled. Your selection is ready to edit.' } else { Get-UiText 'Export stopped.' }
        if ($job.Cancellation.IsCancellationRequested) {
            $metrics.Text = $_.Exception.Message
        } else {
            $metrics.Text = 'Export incomplete  |  ' + $metrics.Text
            [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, $form.Text)
        }
    } finally {
        $job.Cancellation.Dispose()
        $cancelExport.Visible = $false
        $export.Visible = $true
        $job.Worker.Dispose()
        $script:job = $null
        foreach ($control in $controls) { $control.Enabled = $true }
        Update-Selection
    }
})
function Start-Export($destination, $section, $selected) {
    if ($script:exportThenImport) {
        $script:pendingDirect = @{ Mods = $selected; Section = $section.Name }
        $form.DialogResult = 'OK'
        return
    }
    $cancellation = [Threading.CancellationTokenSource]::new()
    $queue = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    $worker = [PowerShell]::Create()
    try {
        $null = $worker.AddScript({
            param($ScriptPath, $Source, $Destination, $Section, $Selected, $Profile, $Queue, $Merged, $Cancellation)
            . $ScriptPath -CoreOnly
            Export-Section $Source $Destination $Section $Selected $Profile {
                param($message)
                $Queue.Enqueue($message)
            } -Merged:$Merged -Cancellation:$Cancellation
        }).AddArgument($scriptFile).AddArgument([string]$install.SelectedItem).AddArgument($destination).
            AddArgument($section.Name).AddArgument($selected).AddArgument([string]$profile.SelectedItem).AddArgument($queue).AddArgument($format.SelectedIndex -eq 1).AddArgument($cancellation.Token)
        $script:job = @{ Worker = $worker; Cancellation = $cancellation; Queue = $queue; Clock = [Diagnostics.Stopwatch]::StartNew(); Bytes = [long]0; Total = [long]0; Handle = $worker.BeginInvoke(); Count = $(if ($format.SelectedIndex -eq 1) { 1 } else { $selected.Count }) }
        foreach ($control in $controls) { $control.Enabled = $false }
        $export.Visible = $false
        $cancelExport.Enabled = $true
        $cancelExport.Visible = $true
        Set-GuidedStep 2
        $status.Text = Get-UiText 'Checking selected mod files...'
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
    $review.RightToLeft = $form.RightToLeft
    $review.Text = 'MO2 Section Exporter'
    $review.ClientSize = New-Object Drawing.Size(820, 650)
    $review.FormBorderStyle = 'Sizable'
    $review.MaximizeBox = $true
    $review.MinimumSize = $review.Size
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
        $null = $grid.Columns.Add($column, (Get-UiText $column))
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

    $back = Add-ReviewControl Button 'Cancel' 26 602 106 34
    $back.DialogResult = 'Cancel'
    $next = Add-ReviewControl Button 'Choose destination...' 606 601 188 38
    $next.DialogResult = 'OK'
    $next.FlatStyle = 'Flat'
    $next.BackColor = $accent
    $next.ForeColor = [Drawing.Color]::White
    $reviewVersion = Add-ReviewControl Label "v$AppVersion" 350 607 120 24
    $reviewVersion.ForeColor = $muted
    foreach ($control in $review.Controls) {
        if ($control.Top -ge 459) { $control.Anchor = 'Bottom,Left' }
    }
    $selectedList.Anchor = 'Top,Left,Right'
    $notes.Anchor = 'Bottom,Left,Right'
    $grid.Anchor = 'Top,Bottom,Left,Right'
    $next.Anchor = 'Bottom,Right'
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
    $destination = if ($script:exportThenImport) { 'direct' } else { Get-ExportDestination $form ([string]$install.SelectedItem) }
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
        $status.Text = Get-UiText 'Select at least one mod to export.'
        return
    }
    $section = if ($script:sectionIndexes.Count -eq 1) { $script:sections[$script:sectionIndexes[0]] } else { [pscustomobject]@{Name = 'Selected sections'} }
    $selected = @($script:sectionMods | Where-Object { $script:selectedNames.Contains($_.Name) })

    if (!$reviewToggle.Checked) {
        $destination = if ($script:exportThenImport) { 'direct' } else { Get-ExportDestination $form ([string]$install.SelectedItem) }
        if ($destination) { Start-Export $destination $section $selected }
        return
    }
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
        $status.Text = Get-UiText 'Scanning for plugin dependencies...'
        $metrics.Text = ''
        $progress.Style = 'Marquee'
        $progress.Visible = $true
        $timer.Start()
    } catch {
        $worker.Dispose()
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, $form.Text)
    }
})


function Show-ImportWindow([string]$InitialPackage, $DirectMods, [string]$DirectSection) {
    $w = New-Object Windows.Forms.Form
    $w.RightToLeft = $form.RightToLeft
    $w.Text = Get-UiText 'Import section'
    $w.ClientSize = New-Object Drawing.Size(740, 496)
    $w.StartPosition = 'CenterScreen'
    $w.Font = $form.Font
    $w.BackColor = $form.BackColor
    function Add-Field($type,$text,$x,$y,$width,$height) {
        $item = New-Object "Windows.Forms.$type"
        $item.Text = Get-UiText $text
        $item.SetBounds($x,$y,$width,$height)
        $w.Controls.Add($item)
        $item
    }
    function Pick-ImportFolder {
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        try { if ($dialog.ShowDialog($w) -eq 'OK') { $dialog.SelectedPath } }
        finally { $dialog.Dispose() }
    }
    $heading = Add-Field Label 'Import a saved section' 24 18 690 44
    $heading.Font = New-Object Drawing.Font('Segoe UI',22,[Drawing.FontStyle]::Bold)
    $null = Add-Field Label 'Export folder containing section.json and ZIPs' 26 78 688 24
    $package = Add-Field TextBox '' 26 105 565 30
    $packageButton = Add-Field Button 'Browse...' 608 102 105 33
    $null = Add-Field Label 'Destination MO2 installation' 26 149 688 24
    $target = Add-Field ComboBox '' 26 175 565 30
    $target.DropDownStyle = 'DropDownList'
    $targetButton = Add-Field Button 'Browse...' 608 172 105 33
    foreach ($item in $install.Items) { $null = $target.Items.Add($item) }
    $null = Add-Field Label 'Destination profile' 26 222 330 23
    $targetProfile = Add-Field ComboBox '' 26 248 330 30
    $targetProfile.DropDownStyle = 'DropDownList'
    $null = Add-Field Label 'New separator name' 380 222 333 23
    $newSeparator = Add-Field TextBox '' 380 248 333 30
        $keepSections = Add-Field CheckBox 'Recreate original separators' 26 280 600 27
    $keepSections.Enabled = $false
    $null = Add-Field Label 'Duplicate mods' 26 315 160 25
    $duplicateMode = Add-Field ComboBox '' 192 311 522 28
    $duplicateMode.DropDownStyle = 'DropDownList'
    $duplicateMode.Items.AddRange(@('Stop and review', 'Keep existing and skip incoming', 'Rename incoming copies'))
    $duplicateMode.SelectedIndex = 0
    $duplicateMode.Anchor = 'Top,Left,Right'
    $statusImport = Add-Field Label 'Close MO2 before importing. The destination profile will be backed up.' 26 344 688 58
    $statusImport.ForeColor = $muted
    $back = Add-Field Button 'Back' 26 430 100 38
    $go = Add-Field Button 'Preview.' 535 428 178 42
    $go.FlatStyle = 'Flat'
    $go.BackColor = $accent
    $go.ForeColor = [Drawing.Color]::White
    $w.FormBorderStyle = 'Sizable'
    $w.MinimumSize = $w.Size
    $importVersion = Add-Field Label "v$AppVersion" 150 440 115 23
    $importVersion.ForeColor = $muted
    foreach ($control in $package,$target,$statusImport,$newSeparator) { $control.Anchor = 'Top,Left,Right' }
    foreach ($control in $packageButton,$targetButton) { $control.Anchor = 'Top,Right' }
    $back.Anchor = 'Bottom,Left'
    $go.Anchor = 'Bottom,Right'
    $importVersion.Anchor = 'Bottom,Left'
    $back.Add_Click({ $w.Close() })
    $target.Add_SelectedIndexChanged({
        $targetProfile.Items.Clear()
        if (!$target.SelectedItem) { return }
        foreach ($dir in Get-ChildItem -LiteralPath (Join-Path ([string]$target.SelectedItem) 'profiles') -Directory) {
            if (Test-Path -LiteralPath (Join-Path $dir.FullName 'modlist.txt')) { $null = $targetProfile.Items.Add($dir.Name) }
        }
        if ($targetProfile.Items.Count) { $targetProfile.SelectedIndex = 0 }
    })
    $targetButton.Add_Click({
        $path = Pick-ImportFolder
        if (!$path) { return }
        Add-Install $path
        if (!$install.Items.Contains($path)) { $statusImport.Text = 'No portable MO2 installation found in that folder.'; return }
        if (!$target.Items.Contains($path)) { $null = $target.Items.Add($path) }
        $target.SelectedItem = $path
    })
    function Set-ImportBundle([string]$path) {
        try {
            $manifest = Get-Content -LiteralPath (Join-Path $path 'section.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($manifest.version -ne 1 -or $manifest.format -notin 'individual','merged') { throw 'Unsupported export folder.' }
            $package.Text = $path
            $newSeparator.Text = $manifest.section
            $keepSections.Enabled = $manifest.format -eq 'individual' -and @($manifest.mods | Where-Object section | Select-Object -ExpandProperty section -Unique).Count -gt 1
            $script:canKeepSections = $keepSections.Enabled
            if (!$keepSections.Enabled) { $keepSections.Checked = $false }
            $statusImport.Text = if ($manifest.format -eq 'merged') { 'Bundle contains one merged mod.' } else { "Bundle contains $(@($manifest.mods).Count) separate mods." }
        } catch { $statusImport.Text = Get-UiMessage $_.Exception.Message }
    }
    $packageButton.Add_Click({
        $path = Pick-ImportFolder
        if ($path) { Set-ImportBundle $path }
    })
    if ($DirectMods) {
        $package.Text = 'Direct folder transfer'
        $package.ReadOnly = $true
        $packageButton.Visible = $false
        $newSeparator.Text = $DirectSection
        $keepSections.Enabled = @($DirectMods | Select-Object -ExpandProperty Section -Unique).Count -gt 1
        $script:canKeepSections = $keepSections.Enabled
        $statusImport.Text = 'Choose the destination MO2 instance and profile. Close MO2 before confirming.'
    } elseif ($InitialPackage) {
        Set-ImportBundle $InitialPackage
        $statusImport.Text += ' Choose the destination instance and profile.'
    } elseif ($target.Items.Count) { $target.SelectedIndex = 0 }
    $importTimer = New-Object Windows.Forms.Timer
    $importTimer.Interval = 150
    $script:importWorker = $null
    $w.Add_FormClosing({ param($sender,$eventArgs); if ($script:importWorker) { $eventArgs.Cancel = $true } })
    $inputs = @($package,$packageButton,$target,$targetButton,$targetProfile,$newSeparator,$duplicateMode,$back,$go)
    $importTimer.Add_Tick({
        $job = $script:importWorker
        $message = $null
        while ($job.Queue.TryDequeue([ref]$message)) { $statusImport.Text = Get-UiMessage $message }
        if (!$job.Handle.IsCompleted) { return }
        $importTimer.Stop()
        try {
            $result = $job.Worker.EndInvoke($job.Handle)[0]
            if ($job.Worker.HadErrors) { throw $job.Worker.Streams.Error[0] }
            if ($job.Preview) {
                $summary = @(
                    "$(Get-UiText 'Destination profile'): $($result.Profile)"
                    "$(Get-UiText 'New separators'): $(($result.Separators -replace '_separator$','') -join ', ')"
                    "$(Get-UiText 'Mods'): $($result.Jobs.Count)"
                    ((Get-UiText 'Estimated extraction size') + (': {0:N1} MiB' -f ($result.UnpackedBytes / 1MB)))
                )
                if ($null -ne $result.FreeBytes) { $summary += ((Get-UiText 'Destination free space') + (': {0:N1} MiB' -f ($result.FreeBytes / 1MB))) }
                $summary += if ($result.HasChecksums) { 'ZIP checksums verified in this dry run.' } elseif ($DirectMods) { 'Files will be copied directly. No ZIP is needed.' } else { Get-UiText 'Older export. ZIP checksums are unavailable.' }
                $blocked = $result.Collisions.Count -gt 0 -or ($null -ne $result.FreeBytes -and $result.FreeBytes -lt $result.UnpackedBytes)
                if ($result.Collisions.Count) { $summary += (Get-UiText 'Name collisions') + ': ' + ($result.Collisions -join ', ') }
                if ($null -ne $result.FreeBytes -and $result.FreeBytes -lt $result.UnpackedBytes) { $summary += Get-UiText 'The destination has insufficient free space.' }
                $summary += ''
                $summary += @($result.Jobs | ForEach-Object { $_.Name + $(if ($_.Enabled) { ' (enabled)' } else { ' (disabled)' }) })
                foreach ($group in @(
                    @{ Title = 'Duplicate handling'; Items = $result.Decisions }
                    @{ Title = 'Skyrim master checks'; Items = $result.Review.Dependencies }
                    @{ Title = 'File overrides against enabled destination mods'; Items = $result.Review.Conflicts }
                    @{ Title = 'Merged ZIP file winners'; Items = $result.MergeWinners }
                    @{ Title = 'Review notes'; Items = $result.ReviewNotes }
                )) {
                    if ($group.Items.Count) { $summary += @('', $group.Title) + @($group.Items) }
                }
                $preview = New-Object Windows.Forms.Form
                $preview.Text = Get-UiText 'Import preview'
                $preview.ClientSize = New-Object Drawing.Size(660, 450)
                $preview.MinimumSize = $preview.Size
                $preview.StartPosition = 'CenterParent'
                $preview.BackColor = $w.BackColor
                $preview.ForeColor = $w.ForeColor
                $preview.Font = $w.Font
                $details = New-Object Windows.Forms.TextBox
                $details.SetBounds(16,16,628,359)
                $details.Multiline = $true
                $details.ReadOnly = $true
                $details.ScrollBars = 'Vertical'
                $details.Anchor = 'Top,Bottom,Left,Right'
                $details.Text = $summary -join [Environment]::NewLine
                $preview.Controls.Add($details)
                $cancel = New-Object Windows.Forms.Button
                $cancel.Text = 'Done without importing'
                $cancel.DialogResult = 'Cancel'
                $cancel.SetBounds(16,398,192,34)
                $cancel.Anchor = 'Bottom,Left'
                $preview.Controls.Add($cancel)
                $confirm = New-Object Windows.Forms.Button
                $confirm.Text = Get-UiText 'Import section'
                $confirm.DialogResult = 'OK'
                $confirm.Enabled = !$blocked
                $confirm.SetBounds(483,398,161,34)
                $confirm.Anchor = 'Bottom,Right'
                $preview.Controls.Add($confirm)
                $preview.CancelButton = $cancel
                try { $confirmed = $preview.ShowDialog($w) -eq 'OK' } finally { $preview.Dispose() }
                $statusImport.Text = if ($blocked) { 'Change the destination or resolve the conflicts shown in the preview.' } else { 'Review the destination before importing.' }
                if ($confirmed) { $script:confirmedImport = $true }
                return
            }
            $statusImport.Text = "Imported $($result.Count) mod(s) under $($result.Separator)."
            [void][Windows.Forms.MessageBox]::Show($w, "$($statusImport.Text)$([Environment]::NewLine)Profile backup: $($result.Backup)", $w.Text)
        } catch { $statusImport.Text = Get-UiMessage $_.Exception.Message }
        finally {
            $job.Worker.Dispose()
            $script:importWorker = $null
            foreach ($item in $inputs) { $item.Enabled = $true }
            $keepSections.Enabled = $script:canKeepSections
            if ($script:confirmedImport) { Start-ImportWork $false }
        }
    })
    function Start-ImportWork([bool]$Preview) {
        $script:confirmedImport = $false
        if (!$package.Text -or !$targetProfile.SelectedItem -or !$newSeparator.Text.Trim()) {
            $statusImport.Text = 'Choose an export folder, destination profile, and separator name.'
            return
        }
        $workerImport = [PowerShell]::Create()
        $queueImport = [Collections.Concurrent.ConcurrentQueue[string]]::new()
        try {
            $null = $workerImport.AddScript({
                param($Script,$Package,$Target,$Profile,$Separator,$Queue,$Preview,$KeepSections,$Duplicates,$DirectMods)
                . $Script -CoreOnly
                if ($Preview) { Get-ImportPlan $Package $Target $Profile $Separator -Preview -KeepSections:$KeepSections -DuplicateAction $Duplicates -DirectMods $DirectMods }
                else { Import-Section $Package $Target $Profile $Separator { param($message); $Queue.Enqueue($message) } -KeepSections:$KeepSections -DuplicateAction $Duplicates -DirectMods $DirectMods }
            }).AddArgument($scriptFile).AddArgument($package.Text).AddArgument([string]$target.SelectedItem).
                AddArgument([string]$targetProfile.SelectedItem).AddArgument($newSeparator.Text.Trim()).AddArgument($queueImport).AddArgument($Preview).AddArgument($keepSections.Checked).AddArgument(@('Block','Skip','Rename')[$duplicateMode.SelectedIndex]).AddArgument($DirectMods)
            $script:importWorker = @{ Preview = $Preview; Worker = $workerImport; Queue = $queueImport; Handle = $workerImport.BeginInvoke() }
            foreach ($item in $inputs) { $item.Enabled = $false }
            $keepSections.Enabled = $false
            $statusImport.Text = Get-UiText 'Checking import files...'
            $importTimer.Start()
        } catch { $workerImport.Dispose(); $statusImport.Text = Get-UiMessage $_.Exception.Message }
    }
    $go.Add_Click({ Start-ImportWork $true })
    $w.ForeColor = $form.ForeColor
    foreach ($field in $package,$target,$targetProfile,$newSeparator,$packageButton,$targetButton,$back) {
        $field.BackColor = $surface
        $field.ForeColor = $form.ForeColor
    }
    try { [void]$w.ShowDialog() } finally { $importTimer.Dispose(); $w.Dispose() }
}

function Select-Workflow {
    $welcome = New-Object Windows.Forms.Form
    $welcome.Text = 'MO2 Section Exporter'
    $welcome.ClientSize = New-Object Drawing.Size(640, 452)
    $welcome.StartPosition = 'CenterScreen'
    $welcome.Font = $form.Font
    $welcome.MinimumSize = $welcome.Size
    $welcome.BackColor = $form.BackColor
    $heading = New-Object Windows.Forms.Label
    $heading.Tag = 'What would you like to do?'
    $heading.Font = New-Object Drawing.Font('Segoe UI', 22, [Drawing.FontStyle]::Bold)
    $heading.SetBounds(25, 22, 460, 50)
    $welcome.Controls.Add($heading)
    $startupTheme = New-Object Windows.Forms.Button
    $startupTheme.SetBounds(505, 27, 106, 34)
    $startupTheme.Anchor = 'Top,Right'
    $welcome.Controls.Add($startupTheme)
    $actions = @(
        @{ Text='Import section'; Result='Yes'; X=26 }
        @{ Text='Export section'; Result='No'; X=225 }
        @{ Text='Export & import'; Result='Retry'; X=424 }
    )
    foreach ($action in $actions) {
        $button = New-Object Windows.Forms.Button
        $button.UseMnemonic = $false
        $button.Tag = $action.Text
        $button.Text = Get-UiText $action.Text
        $button.DialogResult = $action.Result
        $button.SetBounds($action.X, 103, 187, 91)
        $button.FlatStyle = 'Flat'
        $button.BackColor = $surface
        $button.ForeColor = $accent
        $button.Anchor = 'Top,Left'
        $welcome.Controls.Add($button)
    }
    $welcomeVersion = New-Object Windows.Forms.Label
    $welcomeVersion.Text = "v$AppVersion"
    $welcomeVersion.ForeColor = $muted
    $welcomeVersion.SetBounds(26, 414, 125, 24)
    $welcomeVersion.Anchor = 'Bottom,Left'
    $welcome.Controls.Add($welcomeVersion)

    $destinationCaption = New-Object Windows.Forms.Label
    $destinationCaption.Tag = 'Default export folder'
    $destinationCaption.SetBounds(26, 205, 440, 23)
    $welcome.Controls.Add($destinationCaption)
    $savedFolder = New-Object Windows.Forms.TextBox
    $savedFolder.ReadOnly = $true
    $savedFolder.Text = $script:exportDestination
    $savedFolder.SetBounds(26, 231, 465, 29)
    $savedFolder.Anchor = 'Top,Left,Right'
    $welcome.Controls.Add($savedFolder)
    $changeFolder = New-Object Windows.Forms.Button
    $changeFolder.Tag = 'Change...'
    $changeFolder.SetBounds(505, 229, 106, 32)
    $changeFolder.Anchor = 'Top,Right'
    $welcome.Controls.Add($changeFolder)
    $changeFolder.Add_Click({
        try {
            Set-ExportDestination $welcome
            $savedFolder.Text = $script:exportDestination
        } catch {
            [void][Windows.Forms.MessageBox]::Show($welcome, $_.Exception.Message, $welcome.Text)
        }
    })
    $updateStatus = New-Object Windows.Forms.Label
    $updateStatus.SetBounds(26, 325, 585, 36)
    $updateStatus.ForeColor = $muted
    $welcome.Controls.Add($updateStatus)
    $updateButton = New-Object Windows.Forms.Button
    $updateButton.Tag = 'Update and open'
    $updateButton.SetBounds(26, 366, 165, 32)
    $updateButton.Visible = $false
    $welcome.Controls.Add($updateButton)
    $hideUpdate = New-Object Windows.Forms.Button
    $hideUpdate.Tag = 'Hide'
    $hideUpdate.SetBounds(205, 366, 90, 32)
    $hideUpdate.Visible = $false
    $welcome.Controls.Add($hideUpdate)
    $update = @{ Worker = $null; Handle = $null; Offer = $null; Downloading = $false }
    $updateTimer = New-Object Windows.Forms.Timer
    $updateTimer.Interval = 180
    $hideUpdate.Add_Click({
        $updateStatus.Text = ''
        $updateButton.Visible = $false
        $hideUpdate.Visible = $false
    })
    $updateTimer.Add_Tick({
        if (!$update.Handle.IsCompleted) { return }
        $updateTimer.Stop()
        try {
            $result = $update.Worker.EndInvoke($update.Handle)
            if ($update.Worker.HadErrors) { throw $update.Worker.Streams.Error[0] }
            if ($update.Downloading) {
                $downloaded = [string]$result[0]
                Start-Process -FilePath $downloaded -WindowStyle Hidden -ErrorAction Stop
                $update.Downloading = $false
                $welcome.Close()
            } elseif ($result.Count) {
                $update.Offer = $result[0]
                $updateStatus.Text = "Version $($update.Offer.Version) is available. Update now or keep using v$AppVersion."
                $updateButton.Visible = $true
                $hideUpdate.Visible = $true
            }
        } catch {
            if ($update.Downloading) {
                $updateStatus.Text = "Update download failed. $($_.Exception.Message)"
                $updateButton.Enabled = $true
                $hideUpdate.Enabled = $true
            }
        } finally {
            $update.Worker.Dispose()
            $update.Worker = $null
            $update.Handle = $null
        }
    })
    $updateButton.Add_Click({
        if ($update.Worker -or !$update.Offer) { return }
        $update.Downloading = $true
        $updateButton.Enabled = $false
        $hideUpdate.Enabled = $false
        $updateStatus.Text = 'Downloading and verifying the update...'
        $update.Worker = [PowerShell]::Create()
        $null = $update.Worker.AddScript({
            param($Url, $Hash, $Name, $RunningExe)
            $ErrorActionPreference = 'Stop'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $path = Join-Path ([IO.Path]::GetDirectoryName($RunningExe)) $Name
            if (Test-Path -LiteralPath $path) {
                if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ieq $Hash) { return $path }
                throw 'An executable with a different checksum already exists at the update path.'
            }
            $temp = $path + '.' + [guid]::NewGuid().ToString('N') + '.partial'
            try {
                Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 45 -OutFile $temp
                if ((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -ine $Hash) {
                    throw 'The download checksum did not match the GitHub release.'
                }
                [IO.File]::Move($temp, $path)
                $path
            } finally {
                if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
            }
        }).AddArgument($update.Offer.Url).AddArgument($update.Offer.Hash).AddArgument($update.Offer.Name).AddArgument($env:MO2_EXPORTER_EXE_PATH)
        $update.Handle = $update.Worker.BeginInvoke()
        $updateTimer.Start()
    })

    $languageLabel = New-Object Windows.Forms.Label
    $languageLabel.Tag = 'Language'
    $languageLabel.SetBounds(26, 277, 140, 27)
    $welcome.Controls.Add($languageLabel)
    $languagePicker = New-Object Windows.Forms.ComboBox
    $languagePicker.SetBounds(170, 273, 300, 30)
    $languagePicker.DropDownStyle = 'DropDownList'
    $languagePicker.AccessibleName = 'Language'
    $languagePicker.Items.AddRange([object[]]@('Windows default','English','????','??????','Espa�ol','???????','Fran�ais','?????','Portugu�s','???????','Bahasa Indonesia'))
    $languagePicker.SelectedIndex = $script:languageChoice
    $languagePicker.Add_SelectedIndexChanged({
        $script:languageChoice = $languagePicker.SelectedIndex
        $script:language = if ($script:languageChoice -gt 0) { $script:codes[$script:languageChoice - 1] } else { $script:windowsLanguage }
        Update-ControlLanguage $form
        Update-ExportLanguage
        Update-WelcomeTheme
    })
    $welcome.Controls.Add($languagePicker)
    function Update-WelcomeTheme {
        $welcome.BackColor = $form.BackColor
        $welcome.ForeColor = $form.ForeColor
        Update-ControlLanguage $welcome
        $startupTheme.Text = $theme.Text
        $welcomeVersion.ForeColor = $muted
        $updateStatus.ForeColor = $muted
        foreach ($control in $welcome.Controls) {
            if ($control -is [Windows.Forms.Button] -or $control -is [Windows.Forms.TextBox]) {
                $control.BackColor = $surface
                $control.ForeColor = $form.ForeColor
            }
        }
    }
    $startupTheme.Add_Click({ Switch-Theme; Update-WelcomeTheme })
    Update-WelcomeTheme
    $welcome.Add_Shown({
        if (!$env:MO2_EXPORTER_EXE_PATH) { return }
        $update.Worker = [PowerShell]::Create()
        $null = $update.Worker.AddScript({
            param($Current)
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $api = 'https://api.github.com/repos/gluizpessin/mo2-section-exporter/releases'
            $releases = Invoke-RestMethod -Uri $api -UserAgent 'MO2-Section-Exporter' -TimeoutSec 8
            $offers = foreach ($release in $releases) {
                if ($release.draft -or $release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$') { continue }
                $version = [version]$Matches[1]
                if ($version -le [version]$Current) { continue }
                $name = "MO2-Section-Exporter-v$version.exe"
                $url = "https://github.com/gluizpessin/mo2-section-exporter/releases/download/v$version/$name"
                foreach ($asset in $release.assets) {
                    if ($asset.name -ceq $name -and $asset.browser_download_url -ceq $url -and $asset.digest -match '^sha256:([0-9a-f]{64})$') {
                        [pscustomobject]@{ Version = $version; Name = $name; Url = $url; Hash = $Matches[1] }
                    }
                }
            }
            $offers | Sort-Object Version -Descending | Select-Object -First 1
        }).AddArgument($AppVersion)
        $update.Handle = $update.Worker.BeginInvoke()
        $updateTimer.Start()
    })
    $welcome.Add_FormClosing({
        param($sender, $eventArgs)
        if ($update.Downloading -and $update.Worker) { $eventArgs.Cancel = $true }
    })
    try { $welcome.ShowDialog() } finally {
        $updateTimer.Dispose()
        if ($update.Worker) {
            $pending = $update.Worker
            $null = $pending.BeginStop($null, $null)
        }
        $welcome.Dispose()
    }
}

foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
    foreach ($folderName in 'Modlists', 'Wabbajack') {
        $directory = Join-Path $drive.Root $folderName
        foreach ($child in Get-ChildItem -LiteralPath $directory -Directory -ErrorAction SilentlyContinue) { Add-Install $child.FullName }
    }
}

function Update-ExportLanguage {
    $all.Text = Get-UiText 'Select shown'
    $none.Text = Get-UiText 'Clear shown'
    $reviewStep.Text = '2   ' + (Get-UiText 'Review dependencies')
    $export.Text = if ($reviewToggle.Checked) { Get-UiText 'Review selection' } elseif ($script:exportThenImport) { Get-UiText 'Choose destination...' } else { Get-UiText 'Export ZIPs...' }
    $index = $format.SelectedIndex
    $format.Items.Clear()
    $null = $format.Items.Add((Get-UiText 'Individual ZIPs'))
    $null = $format.Items.Add((Get-UiText 'Single merged ZIP'))
    $format.SelectedIndex = [Math]::Max(0,$index)
    Set-AppTheme $script:darkMode
}
Update-ControlLanguage $form
Update-ExportLanguage
if ($install.Items.Count) { $install.SelectedIndex = 0 }
while ($true) {
    $workflow = Select-Workflow
    if ($workflow -eq 'Yes') { Show-ImportWindow; continue }
    if ($workflow -eq 'Retry') {
        $script:exportThenImport = $true
        $script:pendingDirect = $null
        $previousFormat = $format.SelectedIndex
        $format.SelectedIndex = 0
        $format.Visible = $false
        $formatLabel.Visible = $false
        $formatHelp.Text = 'Selected mod folders will be copied directly to another MO2 installation.'
        if (!$reviewToggle.Checked) { $export.Text = Get-UiText 'Choose destination...' }
        try { [void]$form.ShowDialog() } finally {
            $script:exportThenImport = $false
            $format.SelectedIndex = $previousFormat
            $format.Visible = $true
            $formatLabel.Visible = $true
            $export.Text = if ($reviewToggle.Checked) { Get-UiText 'Review selection' } else { Get-UiText 'Export ZIPs...' }
            if ($format.SelectedIndex -eq 0) { $formatHelp.Text = '' }
        }
        if ($script:pendingDirect) {
            Show-ImportWindow '' $script:pendingDirect.Mods $script:pendingDirect.Section
            $script:pendingDirect = $null
        }
        continue
    }
    if ($workflow -eq 'No') { [void]$form.ShowDialog() }
    break
}
$timer.Dispose()
$form.Dispose()
