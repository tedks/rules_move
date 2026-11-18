# Agent instructions: rules_move

Bazel rules for building and testing Sui Move packages offline. The rules
live in `sui_move/`; `tests/` holds a neutral fixture and the runner's
failure-path tests; `e2e/run.sh` consumes an archive of the committed tree
from a separate workspace.

## Environment and gates

Use the Nix dev shell for every command. Before committing, run:

```bash
nix develop --command bazel test //...
nix develop --command ./e2e/run.sh   # after committing: it tests HEAD
git diff --check
```

GitHub Actions is disabled; run the gates locally on the exact commit to be
merged.

## Rules

- Keep the module free of consumer-specific names, paths or evidence: it is
  public and MIT licensed.
- Never commit binaries; the Sui release is fetched by integrity.
- Changes to rule behavior need a test in `tests/` or a check in `e2e/run.sh`.
- `CLAUDE.md` is a symlink to this file.
