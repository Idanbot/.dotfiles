param(
  [Parameter(Mandatory = $true)]
  [string]$Workspace
)

$ErrorActionPreference = "Stop"
$artifactDir = Join-Path $Workspace "artifacts\wsl"
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

$wslWorkspace = (wsl.exe wslpath -a ($Workspace -replace '\\', '/')).Trim()
$wslArtifacts = (wsl.exe wslpath -a ($artifactDir -replace '\\', '/')).Trim()

$script = @"
set -Eeuo pipefail
grep -qi microsoft /proc/sys/kernel/osrelease
. /etc/os-release
[[ "`$ID" == ubuntu && "`$VERSION_ID" == 24.04 ]]
sudo -n true
export DOTFILES_WSL=true DOTFILES_CI=true DOTFILES_COLOR=always
export DOTFILES_GIT_NAME='WSL E2E' DOTFILES_GIT_EMAIL='wsl-e2e@example.invalid'
for pass in 1 2; do
  DOTFILES_LOG_FILE='$wslArtifacts/pass-'"`$pass"'.log' \
    '$wslWorkspace/scripts/install.sh' --source '$wslWorkspace' --profile base --yes
done
'$wslWorkspace/scripts/doctor.sh' --acceptance --sections detect,core,zsh,terminal --json \
  > '$wslArtifacts/doctor.json'
"@

wsl.exe --distribution Ubuntu-24.04 -- bash -lc $script
if ($LASTEXITCODE -ne 0) {
  throw "Real WSL bootstrap failed with exit code $LASTEXITCODE"
}
