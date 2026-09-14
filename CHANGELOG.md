# Changelog

## Desktop packaging

- Revision 3 accepts native installer diagnostics on stderr in Windows PowerShell 5.1 while still rejecting nonzero process exit codes.

- Revision 2 keeps the working Desktop in place until a cross-volume payload transfer completes. Regression coverage injects a partial transfer failure.

- Build a Windows x64 Desktop ZIP from the exact stable Agent commit and publish it after Scoop installation, packaged UI launch, and lifecycle checks.
- Add the Hermes Stable Start menu launcher and restore the previous Desktop payload if installation fails.
- Preserve the upstream manual updater; Scoop and UniGetUI remain the supported update path for the paired package.
- Add immutable release assets, SHA-256 checksums, build provenance, and a packaging revision suffix.

## Unreleased / reviewed v2

- Refuse a fresh install over existing Hermes files when the managed CLI is missing.
- Abort updates when process inspection or gateway state discovery fails, and report every gateway stop failure.
- Match process ownership at directory and command argument boundaries.
- Test rollback after a real revision change and mutation of backed-up user data.
- Run clean install and lifecycle integration checks on code pushes and manual workflow runs even when the generated manifest is unchanged.

- Pin every upstream stable release to its exact git commit SHA, not a mutable tag lookup at install time.
- Download and SHA-256 pin the target `install.ps1` from the exact release commit.
- Prefetch rollback `install.ps1` from the exact old commit and require `-Commit/-ForceCommit` support before updating.
- Refuse existing-install updates when exact revision/status or deterministic rollback capability is unavailable.
- Validate full pre-update backup ZIP before changing code.
- Prefer Hermes-local CLI/Git paths over unrelated global PATH commands.
- Run upstream installers in an isolated child Windows PowerShell process and verify process exit code.
- Verify exact target/rollback commit after installer execution.
- Keep gateways stopped when rollback is incomplete.
- Add real previous-stable -> latest integration update testing plus intentional-failure rollback testing.
- Add PowerShell parser checks under Windows PowerShell 5.1 and PowerShell 7.
- Isolate and fixture-test gateway-list parsing.
- Pin `actions/checkout` by full commit SHA and log the exact Scoop revision used by CI.
- Use GitHub `releases/latest` for normal publication lookup.
- Parse backup retention with `Int32.TryParse` and mark `last-attempt.json` with final transaction status.
