#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
export DOTFILES_SOURCE_DIR="$ROOT"
unset CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN DOTFILES_VERSION_PLAN DOTFILES_STATE_DIR

cat >"$temporary/rustup-init" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$HOME/.rustup"
case "${0##*/}" in
  rustup-init)
    printf 'init\n' >>"$HOME/calls"
    while [[ "$1" != --default-toolchain ]]; do shift; done
    mkdir -p "$HOME/.cargo/bin" "$root/toolchains/$2"
    printf '%s\n' "$2" >"$root/settings.toml"
    cp "$0" "$HOME/.cargo/bin/rustup"
    for binary in cargo rustc rustdoc; do ln -s rustup "$HOME/.cargo/bin/$binary"; done
    ;;
  cargo | rustc)
    [[ "${RUSTUP_AUTO_INSTALL:-}" == 0 ]]
    printf 'rustc %s\n' "$(cut -d- -f1 "$root/settings.toml")"
    ;;
  *)
    case "$*" in
      'show active-toolchain')
        [[ "${RUSTUP_AUTO_INSTALL:-}" == 0 ]]
        printf '%s (%s)\n' "$(cat "$root/settings.toml")" "${RUST_TEST_SELECTION:-default}"
        ;;
      'toolchain install '*)
        [[ "$*" == *--no-self-update ]]
        printf 'install %s\n' "$3" >>"$HOME/calls"
        mkdir -p "$root/toolchains/$3"
        ;;
      'default '*)
        [[ -d "$root/toolchains/$2" ]]
        printf 'default %s\n' "$2" >>"$HOME/calls"
        printf '%s\n' "$2" >"$root/settings.toml"
        ;;
      *) exit 2 ;;
    esac
    ;;
esac
EOF
chmod +x "$temporary/rustup-init"
awk '/^RUST_CHANNEL=/ {block=1} /^NODE_VERSION=/ {exit} block' \
  "$ROOT/.chezmoiscripts/run_once_04-install-languages.sh.tmpl" >"$temporary/rust-section.sh"

for scenario in owned legacy manager payload settings override requested newer; do
  (
    export HOME="$temporary/$scenario" DOTFILES_STATE_DIR="$temporary/$scenario/state"
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/bin:/bin"
    mkdir -p "$HOME/.local/bin"
    source "$ROOT/scripts/lib.sh"
    triple="$(rust_host_triple)"
    package_version() { printf '%s\n' "$target"; }
    download_verified() { cp "$temporary/rustup-init" "$2"; }
    target=1.90.0
    if [[ "$scenario" == legacy ]]; then
      "$temporary/rustup-init" --default-toolchain "$target-$triple"
      managed_link "$HOME/.cargo/bin/rustc" "$HOME/.local/bin/rustc" rust "$target"
      record_install rustup "$target" rustup "$HOME/.cargo"
    else
      source "$temporary/rust-section.sh"
      [[ "$(cat "$HOME/calls")" == init ]]
    fi

    target=1.91.0
    expected=""
    case "$scenario" in
      owned)
        rm "$HOME/.local/bin/rustdoc"
        printf 'local rustdoc\n' >"$HOME/.local/bin/rustdoc"
        export DOTFILES_REPLACE_BINARIES=rust
        ;;
      legacy)
        expected='unowned or unverifiable Rust manager'
        export DOTFILES_REPLACE_BINARIES=rustc
        ;;
      manager)
        expected='unowned or unverifiable Rust manager'
        printf '\n# locally edited\n' >>"$HOME/.cargo/bin/rustup"
        ;;
      payload)
        expected='active Rust toolchain is unowned or modified'
        touch "$HOME/.rustup/toolchains/1.90.0-$triple/modified"
        ;;
      settings)
        expected='Rust default or settings are unowned, changed, or overridden'
        printf '1.89.0-%s\n' "$triple" >"$HOME/.rustup/settings.toml"
        ;;
      override)
        expected='Rust default or settings are unowned, changed, or overridden'
        export RUST_TEST_SELECTION=override
        ;;
      requested)
        expected='requested Rust toolchain is unowned or modified'
        mkdir "$HOME/.rustup/toolchains/$target-$triple"
        ;;
      newer) target=1.89.0 ;;
    esac
    ledger_before="$(sha256sum "$DOTFILES_STATE_DIR/installed.tsv")"
    settings_before="$(sha256sum "$HOME/.rustup/settings.toml")"
    if [[ -n "$expected" ]]; then
      /usr/bin/python3 - "$ROOT" "$target" "$expected" <<'PY'
from pathlib import Path
import runpy
import shutil
import sys

root, target, reason = sys.argv[1:]
sys.path.insert(0, str(Path(root) / "scripts"))
policy = runpy.run_path(str(Path(root) / "scripts/install-policy.py"))
action, ownership = policy["planned_action"]({
    "id": "languages.rust", "current": "1.90.0", "target": target,
    "path": shutil.which("rustc"),
})
assert ownership == "unsupported-replacement" and reason in action, (action, ownership)
PY
    fi
    source "$temporary/rust-section.sh" >"$HOME/result"
    if [[ "$scenario" == owned ]]; then
      [[ "$(cat "$HOME/calls")" == "$(printf 'init\ninstall %s\ndefault %s' "$target-$triple" "$target-$triple")" ]]
      [[ "$(rust_active_default)" == "$target-$triple" ]]
      [[ ! -L "$HOME/.local/bin/rustdoc" && "$(cat "$HOME/.local/bin/rustdoc")" == 'local rustdoc' ]]
      if "$ROOT/scripts/uninstall-tool.sh" rustup; then
        printf 'Generic uninstall accepted the standalone Rust manager receipt\n' >&2
        exit 1
      fi
      source "$temporary/rust-section.sh"
      [[ "$(wc -l <"$HOME/calls")" == 3 ]]
    else
      [[ "$(cat "$HOME/calls")" == init ]]
      [[ "$(sha256sum "$DOTFILES_STATE_DIR/installed.tsv")" == "$ledger_before" ]]
      [[ "$(sha256sum "$HOME/.rustup/settings.toml")" == "$settings_before" ]]
      [[ -z "$expected" ]] || grep -Fq "$expected" "$HOME/result"
    fi
  )
done
printf 'Rust manager, toolchain and default ownership checks passed\n'
