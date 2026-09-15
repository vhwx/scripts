<#
.SYNOPSIS
    Reports disk usage for a given directory, sorted by size.

.DESCRIPTION
    Lists immediate subdirectories of the target path along with their total size,
    sorted largest first. Useful as a quick equivalent of `du -h -d 1 | sort -rh`.

.PARAMETER Path
    Directory to report on. Defaults to the current directory.

.EXAMPLE
    ./Get-DiskUsageReport.ps1 -Path "C:\Projects"

.NOTES
    Author: example
    Date:   2026-09-15
    Requirements: PowerShell 7+ (pwsh)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Path = "."
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -Path $Path -PathType Container)) {
    throw "'$Path' is not a directory"
}

Get-ChildItem -Path $Path -Directory | ForEach-Object {
    $size = (Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    [PSCustomObject]@{
        Name    = $_.Name
        SizeMB  = [math]::Round(($size / 1MB), 2)
    }
} | Sort-Object -Property SizeMB -Descending | Format-Table -AutoSize
