# Next 10 Improvements and Fixes

Reviewed on 2026-09-05 against commit
`1f17c8fda0dd421dd8adc7c72e9c2f5a3aad348c`.

The findings below describe the reviewed baseline; implementation status is
recorded separately below. Rankings favor
preventing data loss and misleading safety signals, then reliable updates and
daily agent workflows. Effort estimates include focused regression tests:
**S** = about one engineering day; **M** = several days.

## Current State and Scope

The project already has an observable bootstrap orchestrator, terminal-based
conflict choices, private logs and state, verified downloads with caching and
locking, an ownership ledger, recovery tests, install-profile matrices, timing
reports, and grouped monthly upgrades. Adding those features again is not the
next priority; making their guarantees hold under failure is.

The latest checked
[Reliable Bootstrap run, 33665617915](https://github.com/Idanbot/.dotfiles/actions/runs/33665617915),
passed at the reviewed commit. That does not prove the edge cases below are
covered, or that every optional heavy test ran.

Review covered installer/recovery code, update routing, agent and cloud helpers,
CI, tests, and the existing architecture and ADRs. Eight synthetic scenarios were
reproduced inside disposable Ubuntu 24.04 Docker containers. The repository was
mounted read-only; no host installation, real credential access, cloud request,
or native WSL test was performed. The remaining findings are explicitly marked
as static review or an integration gap. Code links in the historical findings
refer to the baseline locations and may have shifted during implementation.

## Implementation Status

All ten areas now have code changes and regression coverage in this working
tree. This is not a claim of a deployed fix or a green GitHub run for these
uncommitted changes. Testing used Docker, without touching host configuration,
credentials, or workspaces.

| Rank | Implemented | Verification |
| --- | --- | --- |
| 1 | Whole-plan destination preflight, staged file replacement, empty-directory-only removal | Recovery fixtures preserve unrelated files and reject symlink/type substitutions before mutation. |
| 2 | Fake contexts reject provider credential overrides before state changes; help describes the sandbox limitation | Cloud helper fixtures and real Starship integration with mocked providers pass. |
| 3 | SSH/Git append removed; editor-reviewed candidates validated and confirmed; shell append errors propagated | Conflict tests compare effective SSH/Git settings, reject invalid shell syntax, and inject write failure. |
| 4 | Shared section registry and canonical fingerprints; saved selection respected; targeted installs use orchestrator | Routing tests cover unchanged baselines, database/system/checksum changes, unselected AI, and failed sections. |
| 5 | Workspace cases run in isolated strict-mode subshells with failure diagnostics | Nine baseline/mutation scenarios catch broken assertions and backend errors. |
| 6 | Private immutable run plan, changed-input refusal, persistent backup ID, per-attempt summaries, doctor rerun | Plan tests cover source/options/legacy refusal; lifecycle tests exercise post-apply and post-doctor failure, resume, and backup retention; minimal-install failure/resume passes. |
| 7 | Native MCP absence verified; partial errors aggregated instead of suppressed | Stateful mocks cover failed removal, already-absent state, malformed/read-only config, and unrelated entries. |
| 8 | Staged binary/Go/Node/Java replacement, ownership fingerprints, ledger locks, retained APT rows, UV runtime routing | Ownership tests cover bad probes, local changes, unowned paths, failed ledger/link writes, self-links, stale stamps, and concurrent writers. |
| 9 | Canonical-path suffixes and directory validation before workspace reuse | Mocked tmux/Herdr tests cover basename/sanitization collisions, symlink aliases, and explicit-name mismatch. |
| 10 | One monthly PR explicitly dispatches and tracks a commit-correlated heavy canary | Seventeen mocked GH scenarios cover create/refresh, missing jobs, wrong SHA, supersession, approval, timeout, and publication failure. |

### Deliberate Boundaries

- Resume uses conservative whole-plan refusal on changed inputs, rather than
  automatically replaying a subset of changed stages. Start a new run to review
  conflicts. Old backups and attempt records remain available.
- Profile definitions remain in `profiles/*.conf` with the existing standalone
  bootstrap defaults; the new registry centralizes section implementations and
  input ownership, not a second profile-definition format.
- Unknown or locally changed tool installations are not automatically adopted
  for replacement. Review and move aside a conflicting path manually. System Go
  remains untouched; managed Go uses a versioned user-local directory.
- Restore and tool writes are guarded against observed unsafe state, not an
  adversarial process changing filesystem ancestors concurrently. Separate
  ledger/ownership files are not one crash-atomic transaction; mismatches fail
  closed for review.
- Native WSL, authenticated cloud/agent integrations, a complete heavy profile
  matrix, and the supervised live grouped-upgrade dispatch still require CI or
  explicit environment acceptance. No automatic secret handling was added.

See [Reliability and Operations](reliability.md) and the README for updated
conflict, recovery, ownership, and reconciliation behavior. New Python harness
and canary tests are wired into the Docker workspace CI job; expanded existing
tests remain in their existing gates.

Additional integration findings fixed while validating this work:

- Go shim resolution could create a self-link on repeat installs. Resolve the
  executable first and preserve an existing executable when no link is needed.
- npm updates now stage a runtime copy; an injected package-install failure
  leaves the working runtime and ownership record unchanged.
- The chezmoi fixture now excludes old artifacts instead of trying to copy
  permission-restricted logs from unrelated runs.
- The tmux template syntax check previously executed the config and could launch
  installed TPM plugins. It now uses an isolated empty-config server and
  `source-file -n`, checking the parse exit status separately from cleanup.

## Ranked Summary

| Rank | Next Change | Category | Priority | Effort | Why It Has Value |
| --- | --- | --- | --- | --- | --- |
| 1 | Make restore safe for changed destination trees | Data preservation | High | M | Recovery must not delete unrelated files or write through unexpected symlinks. |
| 2 | Prevent fake cloud contexts from retaining real credential overrides | Cloud safety | High | S | A synthetic prompt must not hide a shell that still has real AWS access. |
| 3 | Replace generic append-merge with format-aware conflict handling | Existing-machine compatibility | High | M | Keeping configuration text is insufficient if the effective settings change. |
| 4 | Unify section routing and reconciliation fingerprints | Idempotency and updates | High | M | Some updates are currently missed while unchanged sections can run again. |
| 5 | Make workspace test assertions fail reliably | CI trustworthiness | High | S | A green gate currently can conceal missing agent launches. |
| 6 | Validate resume checkpoints against their original inputs | Recovery correctness | High | M | Resuming after a source change must not silently mix old and new setup state. |
| 7 | Make MCP disable report verified outcomes | Agent control | High | S | An unsuccessful removal must not be reported as a disabled integration. |
| 8 | Make managed tool replacement and removal ownership-aware | Tool lifecycle | High | M | Failed upgrades and stale ledger entries should not damage working tools. |
| 9 | Identify workspaces by canonical project directory | Agent workflow correctness | High | S | Two repositories with the same basename must not share the wrong agent workspace. |
| 10 | Explicitly run and track the grouped-upgrade canary | Maintenance automation | Medium | S | Creating an upgrade PR is not evidence that its heavy installation tests ran. |

## 1. Make Restore Safe for Changed Destination Trees

**Evidence: reproduced in Docker, two scenarios.**
[scripts/backup.sh](../scripts/backup.sh#L277) restores entries using lexical
`$HOME/$rel` destinations. An `absent` entry invokes `rm -rf`; file restoration
also removes the destination before copying. Snapshot validation checks the
backup payload and its parent paths, but not changed destination ancestors.

An originally absent directory was created after the snapshot and given both a
managed file and unrelated user notes. Restoring the snapshot deleted both.
In a separate fixture, replacing a destination's parent with a symlink caused
restore to overwrite a file outside the fixture home directory.

**Recommended change:** preflight the complete destination plan before mutation.
Validate resolved ancestors against the original/approved destination scope;
reject unexpected symlink or file-type changes. Remove only known-created files,
and remove formerly absent directories only when empty. Preserve or explicitly
ask about later user content. Show this plan before manual restoration and use
the same safety rules during automatic rollback.

**Acceptance:** extend [test-recovery.sh](../tests/test-recovery.sh) with nonempty
new directories, changed ancestor symlinks, and file-to-directory substitutions.
An unsafe plan must fail before touching any destination; unrelated sentinels
must survive. Keep the existing corrupt-snapshot and checksum tests.

## 2. Prevent Fake Cloud Contexts From Retaining Real Credential Overrides

**Evidence: environment retention reproduced in Docker; AWS access consequence
follows documented credential precedence, not a live cloud test.**
[cloud-context](../dot_local/bin/executable_cloud-context#L721) selects fake AWS
files and a synthetic account, but leaves `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, and related credential overrides unchanged.

With harmless placeholder credential variables exported, `--test aws --yes`
succeeded and its generated shell environment retained those values. With valid
credentials, ordinary AWS CLI commands can therefore still address a real
account while the prompt displays the synthetic one. AWS documents environment
credentials taking precedence over profile values in its
[environment variable reference](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html).

**Recommended change:** refuse fake AWS activation when credential overrides
are present, before clearing existing test state or writing fixtures. Explain
which variable names conflict without printing or persisting their values.
Audit the equivalent override paths for the other providers. Describe test mode
as a prompt fixture, not a security sandbox; use a separate credential-free,
network-isolated process for tests that exercise cloud commands.

**Acceptance:** extend [test-cloud-context.sh](../tests/test-cloud-context.sh)
and [the Starship integration test](../tests/test-cloud-context-starship.sh).
Placeholder credential overrides must cause a nonzero exit with no state change
or value leakage. A clean environment must still activate and clear fake
contexts correctly, including the confirmation prompt.

## 3. Replace Generic Append-Merge With Format-Aware Conflict Handling

**Evidence: SSH precedence regression reproduced in Docker.**
[scripts/conflicts.sh](../scripts/conflicts.sh#L47) allows append-merging SSH,
Git, shell, and generic INI/conf files. Its
[merge implementation](../scripts/conflicts.sh#L97) places managed content first
and existing local content afterward. These formats do not share override rules.

For a synthetic SSH host, the original `ServerAliveInterval 5` became effectively
`60` after appending it below managed `Host *` defaults. `ssh -G -F` confirmed the
change without making a connection. OpenSSH generally uses the first obtained
setting, as explained in the
[SSH configuration manual](https://man.openbsd.org/ssh_config).

**Recommended change:** remove append from formats where it cannot preserve
semantics. Reuse the existing early `~/.ssh/config.local` include for intentional
local overrides, with correct `Host`/`Match` scoping. Offer a reviewed merge for
SSH/Git instead of claiming generic concatenation is safe. Validate candidate
syntax and effective settings before atomic replacement; explicitly propagate
copy, permission, and rename errors.

**Acceptance:** extend
[test-conflict-resolution.sh](../tests/test-conflict-resolution.sh) to compare
effective SSH settings before/after merge, Git's full credential-helper chain,
and shell syntax. Test failed writes and repeated merges. Preserve the current
terminal-choice blocking and skip behavior.

## 4. Unify Section Routing and Reconciliation Fingerprints

**Evidence: missed updates reproduced in Docker; divergent fingerprints verified
by static inspection.**
[reconcile-packages.sh](../scripts/reconcile-packages.sh#L38) does not route the
`database` or `system` manifest groups. Changing either group after an initial
reconcile invoked no installer in a fixture with a recording runner.

There is also a second, incompatible
[section map in install.sh](../scripts/install.sh#L1067). Bootstrap records hashes
under install-section names using newline-stripped text; reconciliation records
them under manifest-group names using
[section_manifest_hash](../scripts/lib.sh#L916), which retains newlines. For
example, `terminal` maps differently, while `desktop` hashes a nonexistent
top-level group. Bootstrap and reconcile do not establish the same baseline.

**Recommended change:** define one section registry containing implementation,
manifest dependencies, checksum metadata dependencies, and profile membership.
Use a shared canonical fingerprint and state format for bootstrap and reconcile.
Route targeted updates through the observable orchestrator rather than the
separate direct-template runner. Respect the machine's selected profile; an
update check should not silently opt a base-only machine into extra tools.

**Acceptance:** extend [test-update-routing.sh](../tests/test-update-routing.sh)
with bootstrap-to-reconcile tests: an unchanged setup invokes zero sections;
each changed manifest/checksum key invokes only its owners; database and system
updates are included; failed sections do not advance their fingerprints.

## 5. Make Workspace Test Assertions Fail Reliably

**Evidence: false-positive test result reproduced in Docker.**
The [workspace E2E run_case helper](../tests/e2e/test-agent-workspace.sh#L104)
disables `errexit` while invoking a test function, then uses only its final
status. Earlier `grep` and `[[ ... ]]` assertions can fail and execution can
continue to a successful final command.

Using the actual `run_case` and
[directory-propagation test](../tests/e2e/test-agent-workspace.sh#L327), a fixture
with eight launches of one agent, two of the final agent, and none of three
others was reported as `[PASS]`. The aggregate line count was correct, but the
per-agent assertions were not enforced.

**Recommended change:** make assertions explicitly propagate failures, or run
each case in a correctly isolated strict-mode process and collect its status.
Keep expected-failure checks explicit. Add a deliberate-broken-fixture test so
the harness itself proves it can fail. Preserve diagnostics and accurate failed
case counts when a case aborts. Keep the current mocked contract suite, but do
not treat it as proof of live tmuxp/Herdr or authenticated-agent behavior.

**Acceptance:** deliberately break the first, middle, and last assertion in a
case. Each must produce nonzero suite status and a failed JSON/event entry.
Missing agents, wrong directories, incorrect MCP counts, and backend command
failures must not become passing results because a later assertion succeeds.

## 6. Validate Resume Checkpoints Against Their Original Inputs

**Evidence: static review; no changed-source resume installation executed.**
[run_stage](../scripts/install.sh#L817) skips a stage whenever its `.done` file
exists during resume. The checkpoint contains elapsed seconds, not the source,
manifest, or implementation fingerprint that produced the completed stage.

Consequently, updating the checkout before resuming can leave completed stages
on older settings while remaining stages use newer code. Resume restores the
section list, profile, and source path, but the apply-stage backup identity is
held in a process variable and is not restored for a skipped apply stage. The
current [resume test](../tests/test-failure-resume.sh#L20) injects failure after
the source stage and resumes the same inputs.

**Recommended change:** persist a versioned run plan with source identity,
effective options, stage fingerprints, backup ID, and attempt history. Validate
it on resume; explain which stages require re-planning when inputs changed.
Do not replay a changed apply stage without conflict handling. Revalidate the
final doctor result and retain the original backup link in resumed summaries.

**Acceptance:** inject failures after apply, a language/tool section, and doctor;
then resume both unchanged and changed source states. Completed unchanged work
must be skipped, changed work must not be silently skipped, and recovery links
and timing records must remain valid across attempts.

## 7. Make MCP Disable Report Verified Outcomes

**Evidence: false-success result reproduced in Docker.**
[agent-mcp disable_server](../dot_local/bin/executable_agent-mcp#L184) suppresses
all native Codex and Claude removal errors with `|| true`. The caller then
[prints disabled](../dot_local/bin/executable_agent-mcp#L330) unconditionally.
A mocked native CLI returning exit 37 for every removal still resulted in exit
zero and two success messages from `disable all --agent codex`.

**Recommended change:** distinguish confirmed absence from an operational
failure. Check effective state through supported native interfaces, report
per-agent/server outcomes, and return nonzero if any requested change failed.
Keep already-disabled servers idempotent. Do not overwrite unrelated user MCP
configuration or claim that an already-running agent process has reloaded it.

**Acceptance:** extend [test-agent-mcp.sh](../tests/test-agent-mcp.sh) and the
workspace suite with stateful mocks for failed removals, absent servers,
malformed/read-only config, and partial `--agent all` success. A retained server
must never receive a success message; unrelated entries must survive.

## 8. Make Managed Tool Replacement and Removal Ownership-Aware

**Evidence: static review; no destructive upgrade or uninstall executed.**
Verified downloads protect downloaded bytes, but not the subsequent tool-state
transition. The [language installer](../.chezmoiscripts/run_once_04-install-languages.sh.tmpl#L12)
removes `/usr/local/go` before extracting its replacement.
[install_managed_binary and managed_link](../scripts/lib.sh#L587) replace local
paths without checking whether an existing destination is user-owned.

The removal side also has concrete ownership defects:
[uninstall-tool.sh](../scripts/uninstall-tool.sh#L56) preserves APT/dpkg packages
by default but later drops all their tool rows from the ledger. Python runtimes
are recorded with owner `uv`, which the remover routes to `uv tool uninstall`
rather than the runtime-specific operation. Ledger writers share a fixed
temporary filename, while targeted installs can bypass the bootstrap lock.

**Recommended change:** stage and smoke-test tool replacements before switching
the active path, retaining the previous working version until success. Check
ownership before replacing existing paths. Give runtime installs and UV tools
distinct owner types; remove ledger rows only for successfully removed targets.
Serialize all ledger mutations, including standalone update/uninstall paths,
and detect locally modified destinations before removal.

**Acceptance:** extend [test-ownership-ledger.sh](../tests/test-ownership-ledger.sh)
with extraction/write failures, existing user binaries, preserved APT rows,
Python runtime removal routing, and concurrent writers. The old executable and
correct ledger must survive failure; no unrelated path may be removed.

## 9. Identify Workspaces by Canonical Project Directory

**Evidence: static review; no live Herdr/tmux session changed.**
[dot-workspace](../dot_local/bin/executable_dot-workspace#L101) derives its default
name from the directory basename. Its
[Herdr reuse path](../dot_local/bin/executable_dot-workspace#L368) matches only
that label and focuses the existing workspace without comparing directories.

For example, `/work/api` and `/personal/api` both become `api-agents`. Opening
the second can focus agents in the first repository. Sanitizing punctuation
creates additional collisions. This is more consequential than a cosmetic name
collision because subsequent agent work can happen in the wrong checkout.

**Recommended change:** store and compare the canonical project directory as
workspace identity. Preserve same-directory reuse; use a short path-derived
suffix to disambiguate default names. Explicit `--name` collisions should ask
or fail with the two paths rather than silently focusing another project.
Apply the same identity contract to both supported backends.

**Acceptance:** extend [test-agent-workspace.sh](../tests/test-agent-workspace.sh)
and the Docker workspace suite with equal basenames, sanitized-name collisions,
symlinked paths, and repeated launches. Existing same-project sessions must be
reused without duplication; different projects must remain separate.

## 10. Explicitly Run and Track the Grouped-Upgrade Canary

**Evidence: workflow integration gap verified against current GitHub behavior;
no upgrade PR or workflow was created during this review.**
[grouped-upgrades.yml](../.github/workflows/grouped-upgrades.yml#L70) creates or
updates its branch and PR with the repository `GITHUB_TOKEN`, and tells the
reviewer that PR CI automatically enables heavy installations. It does not
dispatch or wait for that canary itself.

GitHub's current documentation says token-created/updated PRs can generate
approval-required runs, while token-generated pushes do not automatically
trigger another workflow. Therefore unattended canary completion is not
guaranteed. This is not a claim that all such PR runs are impossible. See
[Triggering a workflow](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).

**Recommended change:** keep one monthly branch and PR, but explicitly dispatch
[Reliable Bootstrap](../.github/workflows/ci.yml#L10) on the upgrade branch with
`run_heavy_e2e=true`. Give the dispatching job only the additional permission it
needs, record the resulting run URL, and verify its `headSha` matches the upgrade
commit before treating it as a passed canary. Surface failure or pending approval
in the PR instead of promising automatic coverage. Do not add per-tool PRs or
require a new personal token just to start this workflow.

**Acceptance:** test create-PR and refresh-PR paths, no-update runs, failed
dispatches, failed canaries, and newer commits superseding older runs. A mocked
green run for the wrong SHA must not satisfy the upgrade check. One supervised
live dispatch should confirm the heavy matrix actually runs and is linked from
the grouped PR.

## Recommended Delivery Order

Start with restore safety and fake-context isolation. Fix the workspace test
harness before relying on it to validate further agent changes. Then address
conflict semantics and the shared reconciliation/resume model, followed by MCP
outcomes, managed tool lifecycle, workspace identity, and canary dispatch.

Each change should add its failing regression fixture first, run tests in
Docker, and keep its PR scoped to one behavioral guarantee. Keep manual
credential handling and the existing native/WSL platform policy unchanged.
This review does not propose secret backup automation, new mandatory services,
or a change to the optional worktree policy.
