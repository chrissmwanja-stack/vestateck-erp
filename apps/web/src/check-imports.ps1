<#
.SYNOPSIS
  Cross-checks every relative import in src/App.tsx against files actually on disk.
  Catches typo'd folder/file names (e.g. "perfomance" vs "performance") before Vite does.

.USAGE
  From the app root (the folder containing src\), run:
    .\check-imports.ps1

  Or point it at any file/root explicitly:
    .\check-imports.ps1 -EntryFile "apps\web\src\App.tsx" -SrcRoot "apps\web\src"
#>

param(
    [string]$EntryFile = "apps\web\src\App.tsx",
    [string]$SrcRoot   = "apps\web\src",
    [string[]]$Extensions = @(".tsx", ".ts", ".jsx", ".js")
)

if (-not (Test-Path $EntryFile)) {
    Write-Host "Entry file not found: $EntryFile" -ForegroundColor Red
    Write-Host "Run this from the repo root, or pass -EntryFile / -SrcRoot explicitly." -ForegroundColor Yellow
    exit 1
}

$EntryDir = Split-Path -Parent (Resolve-Path $EntryFile)
$lines = Get-Content $EntryFile

# Matches: import X from './something/path';  or  import X from "../something/path";
$pattern = "from\s+['""](\.[^'""]+)['""]"

$results = @()
$lineNum = 0

foreach ($line in $lines) {
    $lineNum++
    $m = [regex]::Match($line, $pattern)
    if (-not $m.Success) { continue }

    $importPath = $m.Groups[1].Value
    $resolvedBase = Join-Path $EntryDir $importPath
    $resolvedBase = [System.IO.Path]::GetFullPath($resolvedBase)

    $found = $false
    $matchedPath = $null

    # Try as a direct file with each known extension
    foreach ($ext in $Extensions) {
        $candidate = "$resolvedBase$ext"
        if (Test-Path $candidate) {
            $found = $true
            $matchedPath = $candidate
            break
        }
    }

    # Try as a directory with an index file
    if (-not $found -and (Test-Path $resolvedBase -PathType Container)) {
        foreach ($ext in $Extensions) {
            $candidate = Join-Path $resolvedBase "index$ext"
            if (Test-Path $candidate) {
                $found = $true
                $matchedPath = $candidate
                break
            }
        }
    }

    # Try exact path as-is (already has extension, e.g. './styles.css')
    if (-not $found -and (Test-Path $resolvedBase)) {
        $found = $true
        $matchedPath = $resolvedBase
    }

    $results += [PSCustomObject]@{
        Line       = $lineNum
        ImportPath = $importPath
        Resolved   = $resolvedBase
        Found      = $found
        MatchedAt  = $matchedPath
    }
}

$broken = $results | Where-Object { -not $_.Found }
$ok     = $results | Where-Object { $_.Found }

Write-Host ""
Write-Host "Checked $($results.Count) relative imports in $EntryFile" -ForegroundColor Cyan
Write-Host "  OK:     $($ok.Count)" -ForegroundColor Green
Write-Host "  Broken: $($broken.Count)" -ForegroundColor $(if ($broken.Count -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($broken.Count -gt 0) {
    Write-Host "BROKEN IMPORTS:" -ForegroundColor Red
    foreach ($b in $broken) {
        Write-Host ""
        Write-Host ("  Line {0}: {1}" -f $b.Line, $b.ImportPath) -ForegroundColor Yellow

        # Helpful nudge: does a similarly-named folder/file exist nearby?
        $parentDir = Split-Path -Parent $b.Resolved
        $wantedName = Split-Path -Leaf $b.Resolved
        if (Test-Path $parentDir) {
            $siblings = Get-ChildItem $parentDir -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            $close = $siblings | Where-Object {
                $_ -ne $wantedName -and (
                    $_.ToLower() -like "*$($wantedName.ToLower())*" -or
                    $wantedName.ToLower() -like "*$($_.ToLower())*"
                )
            }
            if ($close) {
                Write-Host "    Did you mean: $($close -join ', ')" -ForegroundColor Magenta
            } else {
                Write-Host "    Nothing similar found in: $parentDir" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "    Parent directory does not exist: $parentDir" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    exit 1
} else {
    Write-Host "All imports resolve correctly." -ForegroundColor Green
    exit 0
}