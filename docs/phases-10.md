# Phase 10: Windows 11 and WSL Entrypoint

## Goal

Implement `install.ps1` as the Windows host entrypoint for provisioning WSL2 Ubuntu 24.04 and launching the Linux bootstrap.

## Target Outcome

A fresh Windows 11 machine can prepare WSL2, install or verify Ubuntu 24.04, configure terminal basics safely, clone the repo inside WSL, and run `install.sh`.

## Required Files

- `install.ps1`
- `scripts/terminal-merge.ps1`
- `docs/BOOTSTRAP.md`
- `docs/TROUBLESHOOTING.md`

## Detailed Tasks

- Check PowerShell version.
- Check admin requirements and explain when elevation is needed.
- Enable WSL2 where possible.
- Enable Virtual Machine Platform where possible.
- Install or verify Ubuntu 24.04.
- Handle first-run WSL initialization carefully.
- Verify the WSL distro starts.
- Install or verify Windows Terminal.
- Install or verify configurable Nerd Font, defaulting to JetBrainsMono Nerd Font.
- Locate Windows Terminal `settings.json`.
- Back up Windows Terminal settings before editing.
- Apply minimal terminal settings patch.
- Preserve existing profiles where possible.
- Set Ubuntu profile default only if requested or configured.
- Clone the public dotfiles repo inside WSL if missing.
- If repo already exists, update with a safe fast-forward path.
- Run `bash install.sh` inside WSL.
- Capture and surface useful failure messages.

## Safety Rules

- Do not blindly overwrite Windows Terminal settings.
- Do not assume WSL is ready immediately after install.
- Do not configure Linux internals in PowerShell.
- Do not use `curl | bash`.
- Do not handle secrets in PowerShell.

## Acceptance Criteria

- `install.ps1` can verify or install WSL2 prerequisites.
- Ubuntu 24.04 is installed or detected by explicit distro name.
- Terminal settings are backed up before mutation.
- WSL handoff runs `install.sh` from a local repo clone.
- Failure modes are documented.

## Tests

- Run PowerShell parser/static checks in CI.
- Test on a Windows 11 machine manually.
- Test rerunning `install.ps1`.
- Confirm existing terminal profiles are preserved.
- Confirm WSL bootstrap can be rerun.

## Risks

- Windows and WSL setup requires manual validation outside Linux CI.
- Windows Terminal schema may change. Patch minimally and keep backups.

