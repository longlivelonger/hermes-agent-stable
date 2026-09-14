# Operations

## Automatic publishing

`Update Hermes stable manifest` runs every three hours at minute 17, plus manual dispatch and relevant code/test changes.

Normal publication uses GitHub `releases/latest`, then resolves that release tag to the exact git commit. There is no cooling-off delay.

The generated manifest points `url` at `raw.githubusercontent.com/.../<exact-commit>/scripts/install.ps1`, stores its SHA-256, and embeds the exact target commit in the lifecycle invocation.

## Publication gate

A changed manifest is committed only after:

1. repository/PowerShell parsing tests on Windows PowerShell 5.1;
2. the same tests on PowerShell 7;
3. clean Scoop install and exact commit verification;
4. real previous-stable -> target-stable lifecycle update test;
5. intentional failure after installing a different real commit and changing a user marker, verifying restoration of both the original commit and marker contents.

Code pushes and manual workflow runs execute the installation checks even when the generated manifest is unchanged. Scheduled checks skip installation tests when there is nothing new to publish.

If any stage fails, the old checked-in manifest remains published.

## What users see

After bucket refresh (`scoop update`, or UniGetUI equivalent), users see the new `hermes-agent-stable` version. Nothing is installed until explicitly requested.

## Backup and rollback

Existing installs are updated only when their exact clean current git commit is known.

Before changing code, the lifecycle:

- downloads the old commit's `scripts/install.ps1` into `%LOCALAPPDATA%\HermesAgentStable\rollback-cache\<commit>\install.ps1`;
- verifies that old installer supports `-Commit` and `-ForceCommit`;
- creates a full backup in `%USERPROFILE%\Hermes Backups\`;
- validates the ZIP before proceeding.

Default retention is 5. Set `HERMES_STABLE_BACKUP_KEEP=0` to keep all, or another non-negative 32-bit integer to change retention.

Critical failure rollback reinstalls the old exact commit using that old-commit installer, verifies `HEAD`, then runs `hermes import <backup> --force`.

Receipts:

```text
%LOCALAPPDATA%\HermesAgentStable\
```

- `last-attempt.json` — current/final transaction state (`installing`, `completed`, `rolled-back`, etc.).
- `last-update.json` — successful exact-commit installation and diagnostics.
- `last-rollback.json` — rollback outcome.

## Migrations

Package updates never run `hermes config migrate` automatically. They run:

```powershell
hermes config check
hermes doctor
```

If Hermes recommends migration, the user runs `hermes config migrate` interactively.

## Local source edits and unknown revisions

A dirty checkout is refused. An existing Hermes installation whose exact git commit/status cannot be verified is also refused. This is intentional: the stable package will not change code when it cannot guarantee a deterministic rollback target.

## Gateway handling

Running profiles are discovered from documented human-readable `hermes gateway list` output. Parsing is isolated and fixture-tested. Multiplex mode restarts only the default gateway.

Failure to query gateway state aborts the update before gateways are stopped. Process inspection and gateway stop failures also abort the update.

## Scoop uninstall behavior

Do not add Scoop `uninstaller`, `pre_uninstall`, or `post_uninstall` hooks. Scoop executes old uninstall hooks during normal upgrade.

Thus:

```powershell
scoop uninstall hermes-agent-stable
```

removes only wrapper registration. Hermes remains installed.

To remove Hermes while preserving data:

```powershell
hermes uninstall --yes
```

## CI dependency reproducibility

GitHub Actions checkout is pinned to a full SHA. Scoop is installed using its official bootstrap in CI, and the exact Scoop git revision is printed to logs so any failure can be reproduced/debugged against the actual package-manager revision used.
# Desktop releases

The `Build and release Hermes Desktop stable` workflow builds on Windows x64 using the upstream npm lockfile. It overrides the upstream build-stamp environment with the selected Agent SHA, installs the resulting archive through Scoop from a temporary localhost server, launches its renderer with isolated user data, and runs the real Agent upgrade/rollback test with Desktop present. Only successful runs publish assets and commit the manifest.

Run the workflow manually or push a packaging change. Stable upstream releases are checked every three hours. Increase `packaging-revision.txt` to release changed packaging for an existing upstream version. Existing published archives are reused, never overwritten. If publication succeeds but the manifest push fails, rerun the workflow to recover without rebuilding the archive.

Use the release's SHA256SUMS.txt and release-plan.json to identify the payload and source commit. Desktop smoke output and screenshot are included in the release. The ZIP contains the whole application under `desktop/`; do not distribute Hermes.exe by itself.

## Dependency and readiness failures

The stable wrapper applies a checked compatibility policy to a temporary copy of the pinned installer. It fixes PowerShell 5.1 process exit codes and refreshes PATH after Computer Use installation. It enables project uv configuration for locked dependency sync and refuses an unlocked fallback. npm, Chromium, Computer Use runtime validation, or locked Python sync failures abort the transaction and use the existing rollback path.

`Unsupported upstream installer` means the upstream function layout changed. Review and adapt `ConvertTo-HermesStableInstaller` before publishing that release. Do not bypass this check. Both target and rollback installers must pass preflight.

The Desktop test must receive a successful, matching-version backend health response and leave the startup/loading screen. A screenshot of the setup UI at 86% is not a passing readiness test. On failure, inspect the workflow's `stable-verification-<run-id>` artifact and the installation log. PR validation runs the same installation gates but cannot publish assets or commit the manifest.

Focused local checks do not install an agent:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/test-installer-policy.ps1 -InstallerPath <pinned-install.ps1>
pwsh -NoProfile -ExecutionPolicy Bypass -File tests/test-installer-policy.ps1 -InstallerPath <pinned-install.ps1>
node tests/test-desktop-readiness.cjs
```
