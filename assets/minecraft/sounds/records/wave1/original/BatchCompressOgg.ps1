
# BatchCompressOgg_fixed2.ps1
# Improved: fallback to ffmpeg -i parsing if ffprobe fails to return duration.
# Also optionally dumps probe outputs for debugging when $DEBUG_PROBE = $true
# Requirements: ffmpeg and ffprobe on PATH

# ---------- CONFIG ----------
$MODE = "bitrate"         # "bitrate" or "target-size"
$TARGET_BITRATE_K = 96    # kbps (for bitrate mode)
$TARGET_SIZE_MB = 1.0     # MB per file (for target-size mode)
$OUTPUT_CODEC = "vorbis"  # "vorbis" or "opus"
$RECURSIVE = $false       # $true to recurse
$OVERWRITE = $false       # $true to overwrite originals
$DEBUG_PROBE = $false     # $true to print raw ffprobe/ffmpeg probe outputs for files where duration cannot be determined
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

# Validate settings
if ($MODE -ne "bitrate" -and $MODE -ne "target-size") {
    Write-ErrorAndExit "Invalid MODE. Use 'bitrate' or 'target-size'."
}

if ($OUTPUT_CODEC -ne "vorbis" -and $OUTPUT_CODEC -ne "opus") {
    Write-ErrorAndExit "Invalid OUTPUT_CODEC. Use 'vorbis' or 'opus'."
}

function Parse-DurationStringToSeconds {
    param([string]$durStr)
    # Accept formats like "123.456" or "HH:MM:SS.ss"
    if (-not $durStr) { return $null }
    $durStr = $durStr.Trim()
    # If it's a plain numeric seconds value
    if ($durStr -match '^[0-9]+(\.[0-9]+)?$') {
        [double]::TryParse($durStr, [ref]$parsed) | Out-Null
        return $parsed
    }
    # Match HH:MM:SS(.ms)
    if ($durStr -match '^(?<h>\d+):(?<m>[0-5]?\d):(?<s>[0-5]?\d(?:\.\d+)?)$') {
        $h = [double]$Matches['h']; $m = [double]$Matches['m']; $s = [double]$Matches['s']
        return ($h * 3600.0 + $m * 60.0 + $s)
    }
    return $null
}

function Get-DurationSeconds {
    param([string]$file)
    # Try ffprobe first (prints duration in seconds)
    $args = @(
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        $file
    )
    $durationRaw = & ffprobe @args 2>$null
    if ($LASTEXITCODE -eq 0 -and $durationRaw) {
        $duration = $durationRaw.ToString().Trim()
        $parsed = Parse-DurationStringToSeconds -durStr $duration
        if ($parsed) { return $parsed }
    }

    # Fallback: use ffmpeg -i which prints a "Duration: 00:01:23.45" line to stderr
    try {
        $probeOutput = & ffmpeg -i $file 2>&1
    } catch {
        $probeOutput = $_.Exception.Message
    }

    # Look for "Duration: HH:MM:SS.xx"
    foreach ($line in $probeOutput -split "`n") {
        if ($line -match 'Duration:\s*(?<dur>\d+:\d{2}:\d{2}(?:\.\d+)?)') {
            $durStr = $Matches['dur']
            $parsed = Parse-DurationStringToSeconds -durStr $durStr
            if ($parsed) { return $parsed }
        }
    }

    # Some containers/encodings might print duration as "Duration: 123.456" rarely; catch numbers
    foreach ($line in $probeOutput -split "`n") {
        if ($line -match 'Duration:\s*(?<num>[0-9]+(\.[0-9]+)?)') {
            $num = $Matches['num']
            $parsed = Parse-DurationStringToSeconds -durStr $num
            if ($parsed) { return $parsed }
        }
    }

    if ($DEBUG_PROBE) {
        Write-Host "=== ffprobe raw output for $file ==="
        try { & ffprobe @args 2>&1 | ForEach-Object { Write-Host $_ } } catch {}
        Write-Host "=== ffmpeg -i raw output for $file ==="
        $probeOutput | ForEach-Object { Write-Host $_ }
        Write-Host "====================================="
    }

    return $null
}

function Process-File {
    param([string]$infile)

    if (-not (Test-Path $infile)) {
        Write-Warning "File not found: $infile"
        return
    }

    $duration = Get-DurationSeconds -file $infile
    if (-not $duration -or $duration -le 0) {
        Write-Warning "Could not determine duration for:`n$infile"
        return
    }

    if ($MODE -eq "bitrate") {
        $targetKbps = [math]::Round($TARGET_BITRATE_K)
    } else {
        # target-size mode: compute kbps required to achieve target size (MB)
        $targetKbps = [math]::Round((($TARGET_SIZE_MB * 8.0 * 1000.0) / $duration), 0)
        if ($targetKbps -lt 8) { $targetKbps = 8 } # minimum sanity
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($infile)
    $dir = [System.IO.Path]::GetDirectoryName($infile)
    if ($OVERWRITE) {
        $outfile = Join-Path $dir ("$base" + ".tmp.ogg")
    } else {
        $outfile = Join-Path $dir ("$base" + ".compressed.ogg")
    }

    if ($OUTPUT_CODEC -eq "vorbis") {
        $codecArgs = @("-c:a", "libvorbis", "-b:a", "${targetKbps}k")
    } else {
        $codecArgs = @("-c:a", "libopus", "-b:a", "${targetKbps}k")
    }

    $ffArgs = @(
        "-y",
        "-i", $infile
    ) + $codecArgs + @(
        "-map_metadata", "-1",
        $outfile
    )

    Write-Host ("Processing: {0}  -> codec={1}, target={2}k" -f $infile, $OUTPUT_CODEC, $targetKbps)

    & ffmpeg @ffArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outfile)) {
        Write-Warning "ffmpeg failed for: $infile"
        return
    }

    $origSize = (Get-Item $infile).Length
    $newSize = (Get-Item $outfile).Length

    if ($newSize -ge $origSize) {
        Write-Warning ("Compressed file is not smaller: {0} -> original {1} KB, new {2} KB" -f $infile, [math]::Round($origSize/1KB,2), [math]::Round($newSize/1KB,2))
        if ($OVERWRITE) { Remove-Item $outfile -Force }
        return
    }

    if ($OVERWRITE) {
        try {
            $bak = Join-Path $dir ("$base" + ".bak_ogg")
            if (Test-Path $bak) { Remove-Item $bak -Force }
            Rename-Item -Path $infile -NewName $bak -ErrorAction Stop
            Rename-Item -Path $outfile -NewName (Split-Path $infile -Leaf) -ErrorAction Stop -PathType Leaf
            Remove-Item $bak -Force
            Write-Host ("Overwrote: {0} (size: {1} KB)" -f $infile, [math]::Round($newSize/1KB,2))
        } catch {
            Write-Warning "Failed to overwrite original; restoring backup and keeping files. $_"
            if (Test-Path $bak) {
                Rename-Item -Path $bak -NewName (Split-Path $infile -Leaf) -ErrorAction SilentlyContinue
            }
            if (Test-Path $outfile) { Remove-Item $outfile -Force -ErrorAction SilentlyContinue }
        }
    } else {
        Write-Host ("Wrote: {0} (size: {1} KB)" -f $outfile, [math]::Round($newSize/1KB,2))
    }
}

# Enumerate files and process
if ($RECURSIVE) {
    Get-ChildItem -Recurse -File -Filter *.ogg | ForEach-Object { Process-File -infile $_.FullName }
} else {
    $list = Get-ChildItem -File -Filter *.ogg
    if ($list.Count -eq 0) { Write-Host "No .ogg files found in current directory."; exit 0 }
    foreach ($f in $list) { Process-File -infile $f.FullName }
}

Write-Host "Done."
