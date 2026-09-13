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
5. intentional invalid target test that must rollback code and import backup successfully.

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

If upstream changes the output format, automatic restart may degrade to a warning rather than guessing profile names.

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
