# Build Log

A running record of what I asked the chat AI for and what changed.

**Chat AI used:** Claude, in Claude Code inside VS Code.

---

## 1. Scaffold (Claude Code, 2026-11-15)

**Asked:**

Read the plan and the design documents and show a plan before writing any file. Then set up the repository:
- the line-ending rules, an example env file, the Claude Code settings, and three git hooks, written as POSIX sh so Git for Windows can run them;
- a short CLAUDE.md;
- the folder skeleton;
- a new README;
- a draft decision record on dropping disk encryption;
- the first log entry, in a build log like the ones in my other projects.

Nothing was to be committed or installed, and the server was not to be touched. Along the way I chose, from the options offered:
- one log instead of two;
- a second decision record, for the deploy model;
- that Claude Code may commit on feature branches and `develop`, while pushes stay mine;
- a stricter permission profile;
- a pre-push check of every outgoing commit, not only of `main`.

**What came back / what changed:**

- The plan was shown and approved before any file was written, and adjusted with the choices above.
- `.gitattributes` stores text with LF endings and keeps the shell scripts and hooks LF. `.gitignore` keeps its `private/` line and now also covers `.env.*`, key and certificate files, dumps and editor folders. `.env.example` sets the rule that secrets are files on the server, never environment values.
- `.claude/settings.json`:
  - turns off AI attribution and the bypass mode;
  - denies every push, anything that touches `main`, skipped hooks, forced adds, `git clean`, `gh auth`, and reading `.env` files or `secrets/`;
  - asks before `ssh`, `gh`, installing packages, discarding work, reading `private/`, and editing the guard files;
  - writes every shell rule for both Bash and PowerShell.
- The git hooks, turned on with `git config core.hooksPath .githooks`:
  - `commit-msg` refuses AI attribution.
  - `pre-commit` refuses paths that must never be committed, in any letter case and under any folder, even when force-added, then scans the staged changes with gitleaks.
  - `pre-push` checks every outgoing commit on every branch the same way. A push to `main` also needs a good signature on every first-parent commit after a baseline, which stays empty until signing is set up.
- `.githooks/test.sh` tests the hooks in throwaway repositories, with real signed and unsigned commits and a stand-in for gitleaks.
- `CLAUDE.md` holds the context, the stack, the structure, the branch rules, the public repo hygiene rules and what is enforced, and points to `docs/PLAN.md` and `docs/design/`.
- Every folder from the plan's tree exists, each with a one-line README.
- `README.md` has the goal and the architecture diagram.
- `docs/decisions/` holds `0001-deploy-model.md` and `0002-disk-encryption.md`, drafted from the design documents.
- The plan, the reinstall runbook and the deploy design now point to `LOG.md` and the decision records, and the plan's list of what is enforced matches the new files.
- The hooks pass 109 tests. Each of 48 protections was broken on purpose, one at a time, and the tests caught every one.
- Reviews of the tests and the code led to more tests, to key and certificate files being refused as well, and to corrected wording in CLAUDE.md and the deploy decision record.

**Next:**

- Turn the hooks on, commit, release to `main`, and submit the portfolio card (Nov 15).
- Phase 0 continues: signing, then the accounts and their lead times.
