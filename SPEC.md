# hermes-agent-stable — Specification

Status: implementation contract for the public Scoop bucket.

## 1. Goal

`hermes-agent-stable` is an unofficial community Scoop package for native Windows installations of Nous Research Hermes Agent.

The package provides a predictable stable-release update channel for Scoop and UniGetUI. It never tracks upstream `main` as an install target.

## 2. Release policy

- Upstream: `NousResearch/hermes-agent`.
- The publishable version is GitHub's latest published release (`draft == false`, `prerelease == false`).
- GitHub Actions checks upstream every **3 hours**.
- There is no intentional publication delay.
- Package version is the release tag with one leading `v` removed.
- The release tag is resolved once, at manifest-generation time, to its **exact git commit SHA**.
- The manifest downloads `scripts/install.ps1` from that exact commit and pins its SHA-256.
- Runtime installation uses `-Commit <exact SHA> -ForceCommit`, not `-Tag` and never `main`.

The tag is human-readable release metadata; the commit is the installation source of truth. This remains deterministic even if an upstream tag is later moved.

## 3. User-controlled installation

Publishing a new manifest does not install anything on user machines. Scoop/UniGetUI only reports an available update. The user decides when to install it.

## 4. Windows layout

The package follows the upstream native-Windows layout rather than relocating Hermes into Scoop's app directory.

- Hermes home: `$env:HERMES_HOME` when explicitly set; otherwise `%LOCALAPPDATA%\hermes`.
- Hermes checkout: `<HERMES_HOME>\hermes-agent`.
- Wrapper state/receipts: `%LOCALAPPDATA%\HermesAgentStable`.
- Full pre-update backups: `%USERPROFILE%\Hermes Backups`.

Scoop is a lifecycle/update controller. It does not own Hermes user data.

## 5. Backup policy

Before changing an existing Hermes installation:

1. Resolve the exact current commit and verify git status can be read.
2. Prefetch the upstream installer from the **old exact commit** for rollback.
3. Create `%USERPROFILE%\Hermes Backups` if necessary.
4. Run a **full** upstream backup with `hermes backup -o <file>`.
5. Validate that the resulting file exists, is non-empty, opens as a ZIP, and contains entries.
6. The backup must succeed and validate before the update proceeds.
7. By default keep the 5 newest package-created backups. Override with `HERMES_STABLE_BACKUP_KEEP`; `0` keeps all.

Backups intentionally include secrets/credentials that upstream includes in full backup mode.

The package never recursively copies a live Hermes home; consistency, including SQLite handling, is delegated to `hermes backup`.

## 6. Strict rollback preflight

An existing Hermes installation is updated only if all of these are true:

- its managed checkout exists at `<HERMES_HOME>\hermes-agent`;
- git is available;
- the exact current commit can be determined;
- git status can be read;
- the checkout has no local source modifications;
- the old-commit installer can be prefetched successfully;
- that old installer exposes `-Commit` and `-ForceCommit`, so exact rollback is actually executable.

If exact rollback state is unavailable, the package aborts before changing code. There is no "update anyway" mode in the stable package.

## 7. Update transaction

For an existing installation:

1. Preflight paths, checkout, git revision, clean status, and backup retention setting.
2. Record old tag when available and exact old commit (required).
3. Prefetch `install.ps1` from the old commit into wrapper state for rollback.
4. Snapshot running gateway profiles.
5. Create and validate the full backup.
6. Stop gateways.
7. Refuse to continue if Hermes-owned processes still hold the checkout/venv after a short grace period.
8. Run the **manifest-pinned installer** with `-Commit <target SHA> -ForceCommit -SkipSetup -NonInteractive` and explicit paths.
9. Verify `hermes --version` works.
10. Verify checkout `HEAD` equals the target commit exactly.
11. Run `hermes config check` and `hermes doctor` as diagnostics.
12. Restart only gateway profiles that were running before the update.
13. Write `last-update.json` and mark `last-attempt.json` as `completed`.

`config check`, `doctor`, and gateway restart failures are warnings after exact code installation has been verified; they do not trigger destructive configuration edits.

## 8. Migration policy

The package does **not** run interactive configuration migration automatically.

- Hermes-owned internal/schema migrations that occur naturally are upstream responsibility.
- Package updates run `hermes config check`.
- If configuration needs attention, the user runs `hermes config migrate` interactively.
- The package never directly edits `config.yaml`, `.env`, databases, skills, sessions, or credentials.
- It never guesses other migration commands.

This prevents Scoop/UniGetUI transactions from hanging on prompts.

## 9. Rollback policy

Critical failure means installer failure, unusable Hermes CLI, or exact target-commit verification failure.

On critical failure of an existing install:

1. Stop gateways again.
2. Execute the **prefetched installer from the old commit**.
3. Reinstall `-Commit <old SHA> -ForceCommit`.
4. Verify checkout `HEAD` equals the old commit before touching backup data.
5. Restore the pre-update full backup with `hermes import <zip> --force`.
6. Restart the gateways that were running before the update.
7. Write `last-rollback.json` and mark `last-attempt.json` as `rolled-back` or `rollback-incomplete`.
8. Return failure to Scoop/UniGetUI.

Rollback therefore does not depend on the target release's installer logic.

## 10. Running process and gateway policy

The updater first uses Hermes gateway lifecycle commands, then inspects Windows processes for executable paths/command lines rooted in the Hermes checkout. It does not broadly kill unrelated Python/Node processes.

Gateway-list parsing is isolated in a dedicated function and fixture-tested. Upstream currently documents human-readable `hermes gateway list`; no undocumented JSON output is assumed.

If Hermes-owned processes remain, the update aborts and asks the user to close Hermes Desktop/remaining runtimes.

## 11. Local source modifications

A dirty checkout aborts before backup/install. The package never stashes, discards, or overwrites local source work.

## 12. Scoop uninstall semantics

**The manifest intentionally has no Scoop uninstaller hook.** Scoop invokes the old package's uninstaller during normal package update before installing the new version. Removing Hermes there would destroy the runtime before our lifecycle could create its backup.

Consequences:

- `scoop uninstall hermes-agent-stable` unregisters/removes only the Scoop wrapper and leaves Hermes installed.
- To remove Hermes while keeping user data, use upstream `hermes uninstall --yes`.
- Destructive data removal remains an explicit upstream action and is never performed by this package.

## 13. Manifest generation

The checked-in manifest is generated, not hand-maintained.

`tools/prepare-desktop-release.ps1` builds or reuses the Desktop archive, verifies it, and invokes the manifest builder with both downloads. `tools/update-manifest.ps1` remains an Agent-only fixture helper and must not overwrite the published Desktop manifest. Both release paths share these upstream selection steps:

1. Uses GitHub `releases/latest` for the normal latest-stable path.
2. Resolves the release tag through GitHub's git-ref API, including annotated tags, to an exact commit.
3. Downloads `scripts/install.ps1` from the exact commit.
4. Calculates SHA-256.
5. Embeds `scripts/hermes-lifecycle.ps1` into `installer.script`.
6. Embeds target tag and target commit in the lifecycle invocation.
7. Writes `bucket/hermes-agent-stable.json`.

The runtime does not download helper code from this bucket's mutable `main` branch.

## 14. CI and publishing

The publish workflow runs:

- every 3 hours (`17 */3 * * *`),
- manually via `workflow_dispatch`,
- when lifecycle/generator/test code changes on `master`.

When a manifest changes, CI must pass before publication:

1. PowerShell syntax/contracts under Windows PowerShell 5.1.
2. The same tests under PowerShell 7.
3. A clean Scoop installation into an isolated Hermes home, verifying exact target commit.
4. A real lifecycle integration test: fresh-install previous stable, upgrade to target stable, verify full backup and preserved user marker.
5. An intentional failure after a real commit change and user-data mutation that must automatically restore the original exact commit and original data contents.

Only then is the new manifest committed.

GitHub Actions third-party actions are pinned to full commit SHA. Scoop bootstrap remains the official bootstrap script but CI logs the exact Scoop revision for reproducibility/debugging.

## 15. Public bucket

Recommended repository: `scoop-hermes-agent`.
Recommended package: `hermes-agent-stable`.
Recommended GitHub topic: `scoop-bucket` for Scoop Directory discovery.

README must clearly state this is an unofficial community package, not an official Nous Research distribution channel.
# Desktop release extension

The package installs a prebuilt Windows x64 Hermes Desktop alongside Agent at the same upstream commit. GitHub Actions must build, test, and publish the complete unpacked Desktop ZIP before committing a manifest that references it. Published assets must not be overwritten. `packaging-revision.txt` supplies a numeric packaging suffix to distinguish this package from the upstream version and must increase when republishing a changed package for the same upstream release.

Scoop verifies both download hashes. Runtime validates the Desktop install stamp before changing Agent, deploys Desktop only after Agent verification, and restores the previous Desktop directory if the deployment transaction fails. An open Desktop blocks updates through the existing process preflight. The Start menu launcher pins the intended Hermes home and backend checkout. Upstream manual self-update is unchanged; the supported update path is Scoop or UniGetUI.

Agent backup does not include Electron's separate user-data directory. Installation does not launch Desktop or migrate that data. Previous Desktop directories remain available for manual recovery. The package is not an offline Python distribution and is not code-signed.
