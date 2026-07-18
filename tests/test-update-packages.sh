#!/usr/bin/env bash
# Verify non-mutating upgrade reports and explicit transactional acceptance.

set -euo pipefail

DOTFILES_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf '  [FAIL] %s\n' "$*" >&2
  exit 1
}

pass() { printf '  [PASS] %s\n' "$*"; }

copy_repo() {
  local target="$1"
  mkdir -p "$target"
  cp -a "$DOTFILES_DIR/." "$target/"
  rm -rf "$target/.git"
}

old_herdr_amd64=bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059
old_herdr_arm64=544e0002de42806d1ab64ccdef3a7e7414f24717b0b6b022bc9e57d2eefd26a2
new_herdr_amd64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
new_herdr_arm64=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
old_codex_sha=1154e9daf713aacd1534efca8042bfd6665ad24bc1d1dfd86b8f439fe60a7a5d
new_codex_sha=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
old_fzf_sha=55ab5f2256edd8890f81d407b63d3a3e81cffe10e318cd196031dc85efdeb079
new_fzf_sha=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd

fixture="$TMP_ROOT/upgrades.tsv"
cat >"$fixture" <<EOF
terminal.herdr	0.7.5	amd64:$old_herdr_amd64;arm64:$old_herdr_arm64	amd64:$new_herdr_amd64;arm64:$new_herdr_arm64
ai_tools.claude_cli	2.1.207	npm:sha512-old	npm:sha512-new
ai_tools.codex_cli	standalone	sha256:$old_codex_sha	sha256:$new_codex_sha	true
core.fzf	0.75.0	sha256:$old_fzf_sha	sha256:$new_fzf_sha
EOF

printf '\n== Package Upgrade Interface ==\n'

check_repo="$TMP_ROOT/check"
copy_repo "$check_repo"
before_packages="$(sha256sum "$check_repo/packages.yaml")"
before_metadata="$(sha256sum "$check_repo/packages.meta.yaml")"
DOTFILES_SOURCE_DIR="$check_repo" DOTFILES_UPGRADE_FIXTURE="$fixture" \
  "$check_repo/scripts/update-packages.sh" --check \
  --report "$check_repo/upgrade-report.md" >/dev/null

grep -Fq '`terminal.herdr`' "$check_repo/upgrade-report.md" || fail "report omits Herdr"
grep -Fq '`0.7.4` -> `0.7.5`' "$check_repo/upgrade-report.md" || fail "report omits version delta"
grep -Fq "$old_herdr_amd64 -> $new_herdr_amd64" "$check_repo/upgrade-report.md" ||
  fail "report omits amd64 checksum delta"
grep -Fq './scripts/update-packages.sh --apply-all' "$check_repo/upgrade-report.md" ||
  fail "report omits apply-all guidance"
grep -Fq './scripts/update-packages.sh --apply terminal.herdr@0.7.5' "$check_repo/upgrade-report.md" ||
  fail "report omits selective guidance"
[[ "$(sha256sum "$check_repo/packages.yaml")" == "$before_packages" ]] || fail "check mode changed versions"
[[ "$(sha256sum "$check_repo/packages.meta.yaml")" == "$before_metadata" ]] || fail "check mode changed checksums"
pass "check mode reports version/checksum deltas without mutation"

set +e
DOTFILES_SOURCE_DIR="$check_repo" DOTFILES_UPGRADE_FIXTURE="$fixture" \
  "$check_repo/scripts/update-packages.sh" --check --fail-on-updates \
  --report "$check_repo/failing-report.md" >/dev/null
fail_status=$?
set -e
[[ "$fail_status" -eq 3 ]] || fail "--fail-on-updates did not return status 3"
pass "check mode can explicitly fail when updates exist"

selective_repo="$TMP_ROOT/selective"
copy_repo "$selective_repo"
DOTFILES_SOURCE_DIR="$selective_repo" DOTFILES_UPGRADE_FIXTURE="$fixture" \
  "$selective_repo/scripts/update-packages.sh" --apply terminal.herdr@0.7.5 \
  --report "$selective_repo/upgrade-report.md" >/dev/null
grep -Fq '  herdr: "0.7.5"' "$selective_repo/packages.yaml" || fail "selective apply did not update Herdr"
grep -Fq "    sha256_amd64: $new_herdr_amd64" "$selective_repo/packages.meta.yaml" ||
  fail "selective apply did not update amd64 checksum"
grep -Fq "    sha256_arm64: $new_herdr_arm64" "$selective_repo/packages.meta.yaml" ||
  fail "selective apply did not update arm64 checksum"
grep -Fq '  claude_cli: "2.1.206"' "$selective_repo/packages.yaml" ||
  fail "selective apply changed an unselected tool"
if (
  export DOTFILES_SOURCE_DIR="$selective_repo"
  # shellcheck source=scripts/lib.sh
  source "$selective_repo/scripts/lib.sh"
  [[ "$(package_metadata terminal herdr sha256_amd64)" == "$new_herdr_amd64" ]]
); then
  pass "install helpers read the accepted checksum from package metadata"
else
  fail "install helpers cannot read the accepted checksum"
fi
"$selective_repo/tests/test-package-metadata.sh" "$selective_repo" >/dev/null ||
  fail "selective apply left generated metadata stale"
pass "selective apply updates one version and both architecture checksums"

all_repo="$TMP_ROOT/all"
copy_repo "$all_repo"
DOTFILES_SOURCE_DIR="$all_repo" DOTFILES_UPGRADE_FIXTURE="$fixture" \
  "$all_repo/scripts/update-packages.sh" --apply-all \
  --report "$all_repo/upgrade-report.md" >/dev/null
grep -Fq '  herdr: "0.7.5"' "$all_repo/packages.yaml" || fail "apply-all omitted Herdr"
grep -Fq '  claude_cli: "2.1.207"' "$all_repo/packages.yaml" || fail "apply-all omitted Claude CLI"
grep -Fq "    sha256: $new_codex_sha" "$all_repo/packages.meta.yaml" ||
  fail "apply-all omitted mutable installer checksum"
grep -Fq '  fzf: "0.75.0"' "$all_repo/packages.yaml" || fail "apply-all omitted external version"
grep -Fq 'url: "https://github.com/junegunn/fzf/archive/v0.75.0.tar.gz"' \
  "$all_repo/.chezmoiexternal.yaml" || fail "apply-all omitted external URL"
grep -Fq "sha256: \"$new_fzf_sha\"" "$all_repo/.chezmoiexternal.yaml" ||
  fail "apply-all omitted external checksum"
"$all_repo/tests/test-package-metadata.sh" "$all_repo" >/dev/null ||
  fail "apply-all left generated metadata stale"
pass "apply-all updates every reported candidate"

unknown_repo="$TMP_ROOT/unknown"
copy_repo "$unknown_repo"
if DOTFILES_SOURCE_DIR="$unknown_repo" DOTFILES_UPGRADE_FIXTURE="$fixture" \
  "$unknown_repo/scripts/update-packages.sh" --apply core.missing@1.0.0 >/dev/null 2>&1; then
  fail "unknown selective target succeeded"
fi
grep -Fq '  herdr: "0.7.4"' "$unknown_repo/packages.yaml" || fail "failed apply mutated versions"
pass "unknown target fails before mutation"

printf 'Package upgrade interface test passed\n'
