
# BatchCompressOgg_fixed3.ps1
# Modification: output files go to "compressed" subfolder (created if needed), filenames unchanged.
# Requirements: ffmpeg and ffprobe on PATH

# ---------- CONFIG ----------
$MODE = "bitrate"         # "bitrate" or "target-size"
$TARGET_BITRATE_K = 64    # kbps (for bitrate mode)
$TARGET_SIZE_MB = 1.0     # MB per file (for target-size mode)
$OUTPUT_CODEC = "vorbis"  # "vorbis" or "opus"
$RECURSIVE = $false       # $true to recurse
$OVERWRITE = $false       # unused now, we always write to new folder
# ---------------------------

function Write-ErrorAndExit {
    param([string]$msg)
    Write-Error $msg
    exit 1
}

# Ensure ffmpeg/ffprobe available
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue) -or -not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-ErrorAndExit "ffmpeg and ffprobe must be installed and on PATH."
}

function Parse-DurationStringToSeconds {
    param([string]$durStr)
    if (-not $durStr) { return $null }
    $durStr = $durStr.Trim()
    if ($durStr -match '^[0-9]+(\.[0-9]+)?$') {
        [double]::TryParse($durStr, [ref]$parsed) | Out-Null
        return $parsed
    }
    if ($durStr -match '^(?<h>\d+):(?<m>[0-5]?\d):(?<s>[0-5]?\d(?:\.\d+)?)$') {
        $h = [double]$Matches['h']; $m = [double]$Matches['m']; $s = [double]$Matches['s']
        return ($h * 3600.0 + $m * 60.0 + $s)
    }
    return $null
}

function Get-DurationSeconds {
    param([string]$file)
    $args = @("-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", $file)
    $durationRaw = & ffprobe @args 2>$null
    if ($LASTEXITCODE -eq 0 -and $durationRaw) {
        $duration = $durationRaw.ToString().Trim()
        $parsed = Parse-DurationStringToSeconds -durStr $duration
        if ($parsed) { return $parsed }
    }
    try { $probeOutput = & ffmpeg -i $file 2>&1 } catch { $probeOutput = $_.Exception.Message }
    foreach ($line in $probeOutput -split "`n") {
        if ($line -match 'Duration:\s*(?<dur>\d+:\d{2}:\d{2}(?:\.\d+)?)') {
            return (Parse-DurationStringToSeconds -durStr $Matches['dur'])
        }
    }
    return $null
}

function Process-File {
    param([string]$infile)

    if (-not (Test-Path $infile)) { Write-Warning "File not found: $infile"; return }

    $duration = Get-DurationSeconds -file $infile
    if (-not $duration -or $duration -le 0) {
        Write-Warning "Could not determine duration for:`n$infile"
        return
    }

    if ($MODE -eq "bitrate") {
        $targetKbps = [math]::Round($TARGET_BITRATE_K)
    } else {
        $targetKbps = [math]::Round((($TARGET_SIZE_MB * 8.0 * 1000.0) / $duration), 0)
        if ($targetKbps -lt 8) { $targetKbps = 8 }
    }

    $base = [System.IO.Path]::GetFileName($infile)
    $dir = [System.IO.Path]::GetDirectoryName($infile)
    $outdir = Join-Path $dir "compressed"
    if (-not (Test-Path $outdir)) { New-Item -ItemType Directory -Force -Path $outdir | Out-Null }
    $outfile = Join-Path $outdir $base

    if ($OUTPUT_CODEC -eq "vorbis") {
        $codecArgs = @("-c:a", "libvorbis", "-b:a", "${targetKbps}k")
    } else {
        $codecArgs = @("-c:a", "libopus", "-b:a", "${targetKbps}k")
    }

    $ffArgs = @("-y", "-i", $infile) + $codecArgs + @("-map_metadata", "-1", $outfile)
    Write-Host ("Processing: {0}  -> {1}\n  codec={2}, target={3}k" -f $infile, $outfile, $OUTPUT_CODEC, $targetKbps)
    & ffmpeg @ffArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outfile)) {
        Write-Warning "ffmpeg failed for: $infile"
        return
    }

    $origSize = (Get-Item $infile).Length
    $newSize = (Get-Item $outfile).Length
    if ($newSize -ge $origSize) {
        Write-Warning ("Compressed file not smaller: {0}" -f $infile)
    } else {
        Write-Host ("Saved: {0} ({1} KB → {2} KB)" -f $outfile, [math]::Round($origSize/1KB,2), [math]::Round($newSize/1KB,2))
    }
}

if ($RECURSIVE) {
    Get-ChildItem -Recurse -File -Filter *.ogg | ForEach-Object { Process-File -infile $_.FullName }
} else {
    $list = Get-ChildItem -File -Filter *.ogg
    if ($list.Count -eq 0) { Write-Host "No .ogg files found."; exit 0 }
    foreach ($f in $list) { Process-File -infile $f.FullName }
}

Write-Host "Done."
