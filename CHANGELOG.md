# Changelog

## Unreleased / reviewed v2

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
