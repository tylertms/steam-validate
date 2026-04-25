$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $OutputEncoding = [Text.Encoding]::UTF8
}
catch {}

function FullPath($Path) {
    if (-not $Path) { return $null }
    [IO.Path]::GetFullPath(($Path -replace '/', '\')).TrimEnd('\')
}

function VdfText($Value) {
    if ($null -eq $Value) { return $null }
    $Value -replace '\\\\', '\' -replace '\\"', '"'
}

function VdfValue($Text, $Key) {
    $m = [regex]::Match($Text, '"' + [regex]::Escape($Key) + '"\s+"((?:\\.|[^"\\])*)"')
    if ($m.Success) { VdfText $m.Groups[1].Value }
}

function ReadText($Path) {
    [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function SizeText($Bytes) {
    "{0:N1} GB" -f (($Bytes -as [double]) / 1GB)
}

function TimeText($Seconds) {
    if (-not $Seconds -or $Seconds -lt 1) { return "00:00" }

    $t = [TimeSpan]::FromSeconds($Seconds)

    if ($t.TotalHours -ge 1) {
        return "{0:h\:mm\:ss}" -f $t
    }

    "{0:mm\:ss}" -f $t
}

function FitText($Text, $Width) {
    $s = [string]$Text

    if ($s.Length -le $Width) {
        return $s.PadRight($Width)
    }

    if ($Width -le 3) {
        return $s.Substring(0, $Width)
    }

    $s.Substring(0, $Width - 3) + "..."
}

function FormatLivePrefix($Index, $Count, $Name, $Size, $EtaLeft) {
    "{0,-9} | {1,-30} | {2,10} | {3,13} | " -f `
        "[$Index/$Count]",
        (FitText $Name 30),
        $Size,
        "ETA: $EtaLeft"
}

function FormatDonePrefix($Index, $Count, $Name, $Size, $Time) {
    "{0,-9} | {1,-30} | {2,10} | {3,13} | " -f `
        "[$Index/$Count]",
        (FitText $Name 30),
        $Size,
        $Time
}

function FindSteam {
    $paths = @()

    foreach ($key in @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\SOFTWARE\Wow6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam"
    )) {
        $item = Get-ItemProperty $key -ErrorAction SilentlyContinue
        if ($item) {
            $paths += $item.SteamPath
            $paths += $item.InstallPath
        }
    }

    $paths += Join-Path ${env:ProgramFiles(x86)} "Steam"
    $paths += Join-Path $env:ProgramFiles "Steam"

    foreach ($path in $paths) {
        $path = FullPath $path
        if ($path -and (Test-Path (Join-Path $path "steam.exe"))) {
            return (Get-Item $path).FullName
        }
    }

    throw "Steam was not found."
}

function GetLibraries {
    $paths = @($Steam)

    foreach ($file in @(
        (Join-Path $Steam "steamapps\libraryfolders.vdf"),
        (Join-Path $Steam "config\libraryfolders.vdf")
    )) {
        if (Test-Path $file) {
            $text = ReadText $file

            foreach ($m in [regex]::Matches($text, '"path"\s+"((?:\\.|[^"\\])*)"')) {
                $paths += FullPath (VdfText $m.Groups[1].Value)
            }
        }
    }

    $seen = @{}

    foreach ($path in $paths) {
        $path = FullPath $path
        if (-not $path) { continue }

        $steamapps = Join-Path $path "steamapps"
        $common = Join-Path $steamapps "common"

        if (-not (Test-Path $steamapps)) { continue }

        $path = (Get-Item $path).FullName
        $key = $path.ToLowerInvariant()

        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = [pscustomobject]@{
                Path      = $path
                SteamApps = (Get-Item $steamapps).FullName
                Common    = if (Test-Path $common) { (Get-Item $common).FullName } else { $common }
                Apps      = @()
            }
        }
    }

    @($seen.Values | Sort-Object Path)
}

function GetApps($Libraries) {
    $seen = @{}
    $apps = @()

    foreach ($library in $Libraries) {
        foreach ($manifest in Get-ChildItem $library.SteamApps -Filter "appmanifest_*.acf" -File -ErrorAction SilentlyContinue) {
            $text = ReadText $manifest.FullName
            $id = VdfValue $text "appid"

            if (-not $id -and $manifest.BaseName -match '^appmanifest_(\d+)$') {
                $id = $Matches[1]
            }

            if (-not $id -or $seen.ContainsKey($id)) { continue }

            $name = VdfValue $text "name"
            $size = VdfValue $text "SizeOnDisk"
            $installDir = VdfValue $text "installdir"

            if (-not $name) { $name = "Unknown" }
            if (-not $size) { $size = 0 }

            $app = [pscustomobject]@{
                Name       = $name
                AppId      = $id
                InstallDir = $installDir
                Library    = $library.Path
                Size       = [int64]$size
            }

            $seen[$id] = $true
            $library.Apps += $app
            $apps += $app
        }
    }

    @($apps | Sort-Object Name, AppId)
}

function NewLogReader($Path) {
    [pscustomobject]@{
        Path   = $Path
        Offset = if (Test-Path $Path) { (Get-Item $Path).Length } else { 0 }
    }
}

function ReadLog($State) {
    if (-not (Test-Path $State.Path)) { return @() }

    $stream = [IO.File]::Open($State.Path, "Open", "Read", "ReadWrite")

    try {
        if ($stream.Length -lt $State.Offset) {
            $State.Offset = 0
        }

        $stream.Seek($State.Offset, "Begin") | Out-Null

        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        $text = $reader.ReadToEnd()
        $reader.Dispose()

        $State.Offset = $stream.Position

        if (-not $text) { return @() }

        @($text -split "`r?`n" | Where-Object { $_.Trim() })
    }
    finally {
        $stream.Dispose()
    }
}

function StartValidation($AppId) {
    $uri = "steam://validate/$AppId"

    try {
        $info = [Diagnostics.ProcessStartInfo]::new($uri)
        $info.UseShellExecute = $true
        [Diagnostics.Process]::Start($info) | Out-Null
    }
    catch {
        Start-Process $SteamExe -ArgumentList $uri | Out-Null
    }
}

function ReadResult($Line, $Result, $AppId) {
    $appLine = $Line -match "AppID\s+$AppId\b"

    if (-not $appLine -and $Line -notmatch "Validation:") { return }
    if ($appLine) { $Result.Activity = $true }

    if ($Line -match "AppID\s+$AppId\s+update canceled\s+:\s+(.+)$") {
        $Result.Done = $true
        $Result.Failed = $true
        return
    }

    if ($Line -match "AppID\s+$AppId\s+scheduler finished\s+:\s+removed from schedule\s+\(result\s+(.+?),\s+state") {
        $Result.Done = $true

        if ($Matches[1].Trim() -ne "No Error") {
            $Result.Failed = $true
        }

        return
    }

    if ($Line -match "AppID\s+$AppId\s+App update changed\s+:\s+None\s*$") {
        $Result.NoUpdateAt = Get-Date
        return
    }

    if ($Line -match "AppID\s+$AppId\s+starting commit.*:\s+(\d+)\s+updated,\s+(\d+)\s+moved,\s+(\d+)\s+deleted files") {
        $Result.Fixed = $true
        return
    }

    if ($Line -match 'Validation:\s+missing file\s+"[^"]+"') {
        $Result.Fixed = $true
        return
    }

    if ($Line -match 'Validation:\s+\d+\s+chunks corrupt of\s+\d+\s+total in file\s+"[^"]+"') {
        $Result.Fixed = $true
        return
    }

    if ($Line -match 'Validation:\s+corrupt chunk\b') {
        $Result.Fixed = $true
        return
    }

    if ($Line -match 'Validation:\s+full scan in\s+"[^"]+"\s+found\s+(\d+)/(\d+)\s+mismatching files') {
        if ([int]$Matches[1] -gt 0) {
            $Result.Fixed = $true
        }
    }
}

function ResultStatus($Result) {
    if ($Result.Failed) { return "ERROR" }
    if ($Result.Fixed) { return "FIXED" }
    "OK"
}

function StatusColor($Status) {
    if ($Status -eq "OK") { return "Green" }
    if ($Status -eq "FIXED") { return "Blue" }
    if ($Status -eq "ERROR") { return "Red" }
    "White"
}

function StatusLine($Prefix, $Status, $Color) {
    $lineLength = ($Prefix + $Status).Length
    $extra = [Math]::Max(0, $script:LastStatusLength - $lineLength)

    Write-Host "`r$Prefix" -NoNewline
    Write-Host $Status -ForegroundColor $Color -NoNewline

    if ($extra -gt 0) {
        Write-Host (" " * $extra) -NoNewline
    }

    $script:LastStatusLength = $lineLength
}

function ClearStatusLine {
    if ($script:LastStatusLength -gt 0) {
        Write-Host ("`r" + (" " * $script:LastStatusLength) + "`r") -NoNewline
        $script:LastStatusLength = 0
    }
}

function ShowEta($App, $Index, $Count) {
    $elapsedGame = if ($script:CurrentStarted) {
        ((Get-Date) - $script:CurrentStarted).TotalSeconds
    }
    else {
        0
    }

    $leftBytes = [Math]::Max(
        [int64]0,
        [int64]($script:TotalBytes - $script:DoneBytes)
    )

    $etaLeft = if ($script:LastRate -gt 0) {
        TimeText ([Math]::Max(0, ($leftBytes / $script:LastRate) - $elapsedGame))
    }
    else {
        "--"
    }

    $prefix = FormatLivePrefix $Index $Count $App.Name (SizeText $App.Size) $etaLeft
    StatusLine $prefix "VALIDATING" Yellow
}

function TestApp($App, $Index, $Count) {
    $log = NewLogReader $ContentLog
    $id = [regex]::Escape($App.AppId)

    $result = [pscustomobject]@{
        Done       = $false
        Failed     = $false
        Fixed      = $false
        Activity   = $false
        NoUpdateAt = $null
    }

    StartValidation $App.AppId
    $deadline = (Get-Date).AddMinutes(180)

    while ((Get-Date) -lt $deadline) {
        foreach ($line in ReadLog $log) {
            ReadResult $line $result $id
        }

        if ($result.Done) {
            Start-Sleep -Seconds 2
            foreach ($line in ReadLog $log) {
                ReadResult $line $result $id
            }
            return $result
        }

        if ($result.Activity -and $result.NoUpdateAt -and ((Get-Date) - $result.NoUpdateAt).TotalSeconds -ge 10) {
            $result.Done = $true
            Start-Sleep -Seconds 2
            foreach ($line in ReadLog $log) {
                ReadResult $line $result $id
            }
            return $result
        }

        ShowEta $App $Index $Count
        Start-Sleep -Seconds 2
    }

    $result.Done = $true
    $result.Failed = $true
    $result
}

$Steam = FindSteam
$SteamExe = Join-Path $Steam "steam.exe"
$ContentLog = Join-Path $Steam "logs\content_log.txt"

$libraries = GetLibraries
if (-not $libraries.Count) { throw "No Steam libraries were found." }

$apps = GetApps $libraries
if (-not $apps.Count) { throw "No installed Steam apps were found." }

$script:TotalBytes = [int64](($apps | Measure-Object Size -Sum).Sum)
$script:DoneBytes = [int64]0
$script:MeasuredSeconds = [double]0
$script:LastRate = [double]0
$script:Started = Get-Date
$script:CurrentStarted = $null
$script:LastStatusLength = 0

if (-not (Get-Process steam -ErrorAction SilentlyContinue)) {
    Write-Host "Starting Steam..."
    Start-Process $SteamExe -ArgumentList "-silent" | Out-Null
    Start-Sleep -Seconds 8
}

Write-Host ""
Write-Host "Steam Root"
Write-Host "  $Steam"
Write-Host ""
Write-Host "Steam Libraries"

foreach ($library in $libraries) {
    $libraryBytes = [int64](($library.Apps | Measure-Object Size -Sum).Sum)

    Write-Host (
        "  {0,2} app(s) | {1,9} | {2}" -f `
            $library.Apps.Count,
            (SizeText $libraryBytes),
            $library.Common
    )
}

Write-Host ""

$ok = 0
$fixed = 0
$failed = 0

for ($i = 0; $i -lt $apps.Count; $i++) {
    $app = $apps[$i]
    $n = $i + 1

    $script:CurrentStarted = Get-Date

    ShowEta $app $n $apps.Count

    $result = TestApp $app $n $apps.Count
    $seconds = ((Get-Date) - $script:CurrentStarted).TotalSeconds

    $script:DoneBytes += [int64]$app.Size
    $script:MeasuredSeconds += [double]$seconds

    if ($script:MeasuredSeconds -gt 0 -and $script:DoneBytes -gt 0) {
        $script:LastRate = $script:DoneBytes / $script:MeasuredSeconds
    }

    $status = ResultStatus $result
    $time = TimeText $seconds

    ClearStatusLine

    $prefix = FormatDonePrefix $n $apps.Count $app.Name (SizeText $app.Size) $time
    Write-Host $prefix -NoNewline
    Write-Host $status -ForegroundColor (StatusColor $status)

    if ($status -eq "OK") { $ok++ }
    elseif ($status -eq "FIXED") { $fixed++ }
    else { $failed++ }
}

ClearStatusLine

$totalTime = TimeText (((Get-Date) - $script:Started).TotalSeconds)

Write-Host ""
Write-Host "Summary: OK $ok | Fixed $fixed | Failed $failed | Total $totalTime"
Write-Host "Done."