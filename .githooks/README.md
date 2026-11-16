# Git hooks

Turn them on once per clone: `git config core.hooksPath .githooks`

- `commit-msg` refuses AI attribution in a commit message.
- `pre-commit` refuses staged paths that must never be committed (the rules are in `never-commit.awk`), then scans the staged changes with gitleaks.
- `pre-push` runs the same path and message checks on every outgoing commit, on any branch, and scans those commits with gitleaks. A push to `main` also needs a good signature on every first-parent commit after the commit named in `signed-baseline`. Until signing is set up, `signed-baseline` is empty and that check only warns.
- Without gitleaks installed, both scans print a warning instead of running.
- `sh .githooks/test.sh` tests all of them in throwaway repositories.
