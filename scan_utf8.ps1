$basePath = "c:\Users\Administrator\Desktop\container idea\experiment\01\new"
$goFiles = Get-ChildItem -Path $basePath -Filter "*.go" -Recurse -File
$totalFiles = $goFiles.Count
$issueFiles = @()

foreach ($f in $goFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $badCount = 0
    $i = 0
    while ($i -lt $bytes.Length) {
        $b = $bytes[$i]
        if ($b -lt 0x80) {
            $i++
            continue
        }
        $seqLen = 0
        if (($b -band 0xE0) -eq 0xC0) { $seqLen = 2 }
        elseif (($b -band 0xF0) -eq 0xE0) { $seqLen = 3 }
        elseif (($b -band 0xF8) -eq 0xF0) { $seqLen = 4 }
        else {
            $badCount++
            $i++
            continue
        }
        $valid = $true
        for ($j = 1; $j -lt $seqLen; $j++) {
            if (($i + $j) -ge $bytes.Length -or (($bytes[$i + $j] -band 0xC0) -ne 0x80)) {
                $valid = $false
                break
            }
        }
        if (-not $valid) {
            $badCount++
            $i++
        } else {
            $i += $seqLen
        }
    }

    # Check for U+FFFD in decoded string
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    $fffdCount = 0
    foreach ($ch in $text.ToCharArray()) {
        if ([int]$ch -eq 0xFFFD) { $fffdCount++ }
    }

    if ($badCount -gt 0 -or $fffdCount -gt 0) {
        $rel = $f.FullName.Substring($basePath.Length)
        $issueFiles += [PSCustomObject]@{
            File = $rel
            BadBytes = $badCount
            FFFD = $fffdCount
        }
    }
}

Write-Host "=== UTF-8 Scan Report ==="
Write-Host "Total .go files scanned: $totalFiles"
if ($issueFiles.Count -eq 0) {
    Write-Host "All files are CLEAN - no invalid UTF-8 or U+FFFD found."
} else {
    Write-Host "Files with issues: $($issueFiles.Count)"
    foreach ($item in $issueFiles) {
        Write-Host ("  {0}  |  BadBytes={1}  FFFD={2}" -f $item.File, $item.BadBytes, $item.FFFD)
    }
}
