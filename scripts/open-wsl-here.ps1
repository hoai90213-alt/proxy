param(
    [string]$Distro = ""
)

$repoPath = Split-Path -Parent $PSScriptRoot
$full = [System.IO.Path]::GetFullPath($repoPath)

function Convert-ToWslPath([string]$winPath) {
    $p = $winPath.Replace('\', '/')
    if ($p -match '^([A-Za-z]):/(.*)$') {
        $drive = $matches[1].ToLower()
        $rest = $matches[2]
        return "/mnt/$drive/$rest"
    }
    throw "Unsupported Windows path: $winPath"
}

$wslRepo = Convert-ToWslPath $full
$cmd = "cd '$wslRepo' && exec bash"

if ([string]::IsNullOrWhiteSpace($Distro)) {
    wsl bash -lc $cmd
} else {
    wsl -d $Distro bash -lc $cmd
}
