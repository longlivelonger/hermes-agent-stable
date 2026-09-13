# hermes-agent-stable

Unofficial community Scoop package for **stable releases** of [Nous Research Hermes Agent](https://github.com/NousResearch/hermes-agent) on native Windows.

It makes Hermes updates visible in Scoop/UniGetUI without allowing the package to follow upstream `main`.

## Update model

```text
NousResearch/hermes-agent GitHub Releases
                 |
                 | latest published stable release
                 | checked every 3 hours
                 v
      GitHub Actions in this bucket
                 |
                 | release tag -> exact commit SHA
                 | install.ps1 downloaded from exact commit
                 | SHA-256 pinned in Scoop manifest
                 | clean install + real update/rollback tests
                 v
          hermes-agent-stable manifest
                 |
                 v
          Scoop / UniGetUI shows update
                 |
                 v
          user chooses when to install
```

There is **no publication delay**. A new stable upstream release is eligible at the next three-hour check. Installation remains the user's decision.

## Why both tag and commit are stored

The release tag is used as the human-readable package version. The actual installation is pinned to the exact commit that the tag resolved to when the manifest was generated.

Runtime install uses:

```powershell
install.ps1 -Commit <exact-sha> -ForceCommit -SkipSetup -NonInteractive
```

It does **not** install by `main` or resolve a tag again at user-install time. This protects reproducibility if an upstream tag is ever moved.

## Installation

After publishing the repository on GitHub:

```powershell
scoop bucket add hermes https://github.com/YOUR-GITHUB-USER/scoop-hermes-agent
scoop install hermes/hermes-agent-stable
```

UniGetUI can then manage the Scoop package normally. On a fresh machine the package skips interactive setup; run `hermes setup` once after installation.

For public discovery, add the GitHub topic:

```text
scoop-bucket
```

## What happens during an update

For an existing Hermes installation the package:

1. Requires an exact, clean current git commit; otherwise it refuses to update because deterministic rollback would be impossible.
2. Prefetches `install.ps1` from the **old exact commit** for rollback and verifies that it supports exact `-Commit/-ForceCommit` rollback.
3. Detects running gateway profiles.
4. Creates and validates a **full Hermes backup** in `%USERPROFILE%\Hermes Backups`.
5. Stops gateways and checks for remaining Hermes-owned processes.
6. Installs the **exact target commit** using the installer already SHA-256-pinned in the Scoop manifest.
7. Verifies `hermes --version` and exact checkout commit.
8. Runs `hermes config check` and `hermes doctor` as diagnostics.
9. Restarts only gateways that were running before the update.
10. Records transaction receipts under `%LOCALAPPDATA%\HermesAgentStable`.

If critical installation/verification fails, rollback uses the **old commit's prefetched installer**, restores the old exact commit, verifies it, then imports the full pre-update backup.

See [SPEC.md](SPEC.md) for the contract and [docs/OPERATIONS.md](docs/OPERATIONS.md) for maintenance details.

## Backups

Full upstream `hermes backup` archives are stored at:

```text
%USERPROFILE%\Hermes Backups\
```

They intentionally include whatever secrets/credentials Hermes includes in full backup mode.

The package validates that the produced ZIP can be opened and has content before proceeding.

Default retention: **5** package-created pre-update backups.

```powershell
$env:HERMES_STABLE_BACKUP_KEEP = '10'
```

Use `0` to keep all. Invalid/overflowing values abort before update rather than being silently misread.

## Configuration migrations

The package never automatically runs:

```powershell
hermes config migrate
```

That command is interactive and should not be hidden inside Scoop/UniGetUI. Updates run:

```powershell
hermes config check
hermes doctor
```

If migration is recommended, run `hermes config migrate` manually afterward.

## Important Scoop uninstall behavior

The package intentionally defines **no Scoop uninstaller hook**, because Scoop runs the old manifest's uninstall hooks during a normal update.

Therefore:

```powershell
scoop uninstall hermes-agent-stable
```

removes the Scoop wrapper registration but leaves Hermes itself installed.

To remove Hermes while preserving user data:

```powershell
hermes uninstall --yes
```

## Automatic publishing

`.github/workflows/update-stable.yml` runs at:

```cron
17 */3 * * *
```

It also supports manual dispatch and reruns when lifecycle/generator/test code changes.

Before committing a changed manifest it tests:

- PowerShell parsing/contracts on Windows PowerShell 5.1 and PowerShell 7;
- clean Scoop install at the exact target commit;
- a real previous-stable -> target-stable update;
- creation/validation of the pre-update backup;
- an intentional failed update and successful automatic code+data rollback.

`actions/checkout` is pinned to a full commit SHA. The workflow logs the exact Scoop revision used by CI.

## First upload to GitHub

The ZIP intentionally does not contain a generated `bucket/hermes-agent-stable.json`. The first workflow run resolves the then-current stable release, exact commit and installer hash, tests them, and commits the manifest.

The workflow needs permission to push. If GitHub rejects the bot push, enable **Settings → Actions → General → Workflow permissions → Read and write permissions**, subject to organization policy.

Manual generation on Windows/PowerShell:

```powershell
./tools/update-manifest.ps1
./tests/test-repository.ps1
```

## Scope

- Native Windows only.
- Official stable GitHub Releases only.
- Exact commit pinning; no runtime tracking of tags or `main`.
- No automatic interactive configuration migration.
- No destructive removal of Hermes user data.

## License

This bucket's code is MIT licensed. Hermes Agent itself is maintained by Nous Research under its upstream license.
