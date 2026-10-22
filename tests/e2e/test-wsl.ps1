param(
  [Parameter(Mandatory = $true)]
  [string]$Workspace,
  [string]$Rootfs = $env:DOTFILES_WSL_ROOTFS
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Rootfs) -or !(Test-Path -LiteralPath $Rootfs -PathType Leaf)) {
  throw "Set WSL_E2E_ROOTFS / DOTFILES_WSL_ROOTFS to a local Ubuntu 24.04 rootfs tar for a disposable distro"
}
$Rootfs = (Resolve-Path -LiteralPath $Rootfs).Path
$Workspace = (Resolve-Path -LiteralPath $Workspace).Path
$artifactDir = Join-Path $Workspace "artifacts\wsl"
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

function Invoke-Wsl {
  param([string[]]$Arguments, [string]$Script)

  if ($PSBoundParameters.ContainsKey("Script")) {
    # Native stdin adds a Windows newline; a final comment absorbs its CR.
    ($Script.Replace("`r", "") + "`n#") | & wsl.exe @Arguments
  } else {
    & wsl.exe @Arguments
  }
  if ($LASTEXITCODE -ne 0) {
    throw "wsl.exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

$distro = "dotfiles-e2e-$([guid]::NewGuid().ToString('N'))"
$installDir = Join-Path ([System.IO.Path]::GetTempPath()) $distro
$existing = @(Invoke-Wsl -Arguments @("--list", "--quiet") |
  ForEach-Object { ($_ -replace "`0", "").Trim() })
if ($existing -contains $distro) {
  throw "Refusing to reuse existing WSL distro $distro"
}
New-Item -ItemType Directory -Path $installDir | Out-Null
$importAttempted = $false

try {
  $importAttempted = $true
  Invoke-Wsl -Arguments @("--import", $distro, $installDir, $Rootfs, "--version", "2")
  $wslWorkspace = (Invoke-Wsl -Arguments @(
    "--distribution", $distro, "--user", "root", "--exec", "wslpath", "-a", "-u", $Workspace
  )).Trim()
  $wslArtifacts = (Invoke-Wsl -Arguments @(
    "--distribution", $distro, "--user", "root", "--exec", "wslpath", "-a", "-u", $artifactDir
  )).Trim()

  $setup = @'
set -Eeuo pipefail
grep -qi 'microsoft.*wsl2' /proc/sys/kernel/osrelease
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]]
[[ ! -e /home/dotfiles-e2e && ! -L /home/dotfiles-e2e ]]
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sudo ca-certificates curl git
useradd --create-home --shell /bin/bash dotfiles-e2e
printf 'dotfiles-e2e ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/dotfiles-e2e
chmod 0440 /etc/sudoers.d/dotfiles-e2e
'@
  Invoke-Wsl -Arguments @("--distribution", $distro, "--user", "root", "--exec", "bash", "-s") -Script $setup

  # Pass paths as arguments, not shell source, including spaces and apostrophes.
  $bootstrap = @'
set -Eeuo pipefail
[[ "${WSL_DISTRO_NAME:-}" == dotfiles-e2e-* ]]
[[ "$(id -un)" == dotfiles-e2e && "$HOME" == /home/dotfiles-e2e ]]
cd "$HOME"
sudo -n true
export PATH="$HOME/.local/bin:$PATH"
export DOTFILES_WSL=true DOTFILES_CI=true DOTFILES_COLOR=always
export DOTFILES_GIT_NAME='WSL E2E' DOTFILES_GIT_EMAIL='wsl-e2e@example.invalid'
for pass in 1 2; do
  DOTFILES_LOG_FILE="$2/pass-$pass.log" \
    "$1/scripts/install.sh" --source "$1" --profile base --conflict-policy backup --yes
done
"$1/scripts/doctor.sh" --acceptance --sections detect,core,zsh,terminal --json \
  >"$2/doctor.json"
'@
  Invoke-Wsl -Arguments @(
    "--distribution", $distro, "--user", "dotfiles-e2e", "--exec", "bash", "-s", "--", $wslWorkspace, $wslArtifacts
  ) -Script $bootstrap
} finally {
  # Import can fail after registration; clean up only our previously absent name.
  if ($importAttempted) {
    $registered = @(Invoke-Wsl -Arguments @("--list", "--quiet") |
      ForEach-Object { ($_ -replace "`0", "").Trim() })
    if ($registered -contains $distro) {
      Invoke-Wsl -Arguments @("--unregister", $distro)
    }
  }
  if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
  }
}
