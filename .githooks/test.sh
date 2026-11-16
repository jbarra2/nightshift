#!/bin/sh
# Tests for the git hooks in this folder.
#
#   sh .githooks/test.sh              every section
#   sh .githooks/test.sh pre-commit   only the named sections: commit-msg,
#                                     pre-commit, wired, pre-push (or one part
#                                     of it: pre-push-main, pre-push-outgoing,
#                                     pre-push-release)
#
# Each case runs in a throwaway repository under a temporary directory, with the
# user's and the system's git config shut out. Nothing touches this repository
# or a remote: pre-push is called directly, with the input git would give it.
# gitleaks is replaced by a stand-in, so every case runs where it isn't installed.

set -u

sections=$*
# want <section>: true when that section was asked for, or when none were.
want() {
  [ -z "$sections" ] && return 0
  for s in $sections; do
    case $1 in
      "$s" | "$s"-*) return 0 ;;
    esac
  done
  return 1
}

hooks=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || exit 1
work=$(mktemp -d) || exit 1
trap 'cd / && rm -rf "$work"' EXIT
trap 'exit 130' HUP INT TERM

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX GIT_CONFIG \
  GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$work/gitconfig"
export HOME="$work/home"
mkdir -p "$HOME" "$work/bin" || exit 1
cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = Test User
	email = test@example.com
[init]
	defaultBranch = main
[commit]
	gpgsign = false
[advice]
	detachedHead = false
EOF

zero=0000000000000000000000000000000000000000
base_path=$PATH

# A stand-in for gitleaks: it records its arguments and exits with $STUB_EXIT.
cat >"$work/bin/gitleaks" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$STUB_LOG"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$work/bin/gitleaks"
stub_path="$work/bin:$base_path"
STUB_LOG="$work/gitleaks.log"
STUB_EXIT=0
export STUB_LOG STUB_EXIT

# A PATH without gitleaks, for the "not installed" cases.
nogl_path=$base_path
hide_ok=yes
real=$(command -v gitleaks 2>/dev/null) || real=
if [ -n "$real" ]; then
  nogl_path=$(printf '%s\n' "$base_path" | tr ':' '\n' |
    grep -vxF -- "$(dirname -- "$real")" | paste -s -d : -)
  if env PATH="$nogl_path" sh -c 'command -v gitleaks' >/dev/null 2>&1 ||
    ! env PATH="$nogl_path" sh -c 'command -v git' >/dev/null 2>&1; then
    hide_ok=no
  fi
fi

# Throwaway SSH keys: one allowed signer, and one stranger.
ssh-keygen -q -t ed25519 -N '' -C signer -f "$work/key" </dev/null || exit 1
ssh-keygen -q -t ed25519 -N '' -C stranger -f "$work/otherkey" </dev/null || exit 1
printf 'test@example.com %s\n' "$(cut -d ' ' -f 1,2 "$work/key.pub")" >"$work/allowed_signers"

passed=0
failed=0
skipped=0
ok() {
  passed=$((passed + 1))
  printf 'ok    %s\n' "$1"
}
not_ok() {
  failed=$((failed + 1))
  printf 'FAIL  %s\n' "$1"
  if [ -s "$work/out" ]; then sed 's/^/      | /' "$work/out"; fi
}
skip() {
  skipped=$((skipped + 1))
  printf 'skip  %s\n' "$1"
}

# run <command...>: runs it, keeps its output in $work/out and its status in $rc.
run() {
  "$@" >"$work/out" 2>&1
  rc=$?
}
refused() {
  name=$1
  shift
  run "$@"
  if [ "$rc" -ne 0 ]; then ok "$name"; else not_ok "$name (expected a refusal, got exit 0)"; fi
}
accepted() {
  name=$1
  shift
  run "$@"
  if [ "$rc" -eq 0 ]; then ok "$name"; else not_ok "$name (expected exit 0, got $rc)"; fi
}
# said <name> <text>: the last command run printed this text.
said() {
  if grep -qF -- "$2" "$work/out"; then ok "$1"; else not_ok "$1 (the output lacks: $2)"; fi
}

n=0
# new_repo: creates an empty repository and moves into it.
new_repo() {
  n=$((n + 1))
  git init -q "$work/repo$n" && cd "$work/repo$n" || exit 1
}
# stage <path>: creates the file, with its folders, and force-adds it.
stage() {
  mkdir -p "$(dirname -- "$1")" && printf 'x\n' >"$1" && git add -f -- "$1" ||
    { echo "setup failed: stage $1" >&2; exit 1; }
}
# fixture_commit <message> [git commit options...]: a setup commit, hooks off.
fixture_commit() {
  m=$1
  shift
  git commit -q --no-verify --allow-empty -m "$m" "$@" </dev/null ||
    { echo "setup failed: commit $m" >&2; exit 1; }
}

cm() { sh "$hooks/commit-msg" "$1"; }
pc() { env PATH="$nogl_path" sh "$hooks/pre-commit"; }
pp() {
  printf '%s\n' "$@" |
    env PATH="$nogl_path" sh "$hooks/pre-push" origin https://example.invalid/nightshift.git
}
pp_stub() {
  printf '%s\n' "$@" |
    env PATH="$stub_path" sh "$hooks/pre-push" origin https://example.invalid/nightshift.git
}

# Attribution samples. The longer forms are split so that this file never holds
# them whole.
trailer="Co-Authored-By: Claude <noreply@anthropic.com>"
gen1="Generated with"
gen2="[Claude Code](https://claude.com/claude-code)"
session_url="https://claude.ai/code/""session_0123456789"

if want commit-msg; then
echo "commit-msg"
printf '%s\n' "Add the hooks" "" "$trailer" >"$work/m1"
refused "refuses a Co-Authored-By Claude trailer" cm "$work/m1"
printf '%s\n' "Add the hooks" "" "co-authored-by: claude opus <noreply@example.com>" >"$work/m2"
refused "refuses the trailer in lower case" cm "$work/m2"
printf '%s\n' "Add the hooks" "" "Co-authored-by: Helper <helper@anthropic.com>" >"$work/m3"
refused "refuses a co-author at anthropic.com" cm "$work/m3"
printf '%s\n' "Add the hooks" "" "Claude-Session: https://example.invalid/s/1" >"$work/m4"
refused "refuses a Claude-Session trailer" cm "$work/m4"
printf '%s\n' "Add the hooks" "" "$gen1 $gen2" >"$work/m5"
refused "refuses a generated-with line" cm "$work/m5"
printf '%s\n' "Add the hooks" "" "$gen1 claude code" >"$work/m6"
refused "refuses a generated-with line without the link" cm "$work/m6"
printf '%s\n' "Add the hooks" "" "Details: $session_url" >"$work/m7"
refused "refuses a session link anywhere in the message" cm "$work/m7"
printf 'Add the hooks\r\n\r\n%s\r\n' "$trailer" >"$work/m8"
refused "refuses the trailer with CRLF line endings" cm "$work/m8"
printf '%s\n' "Fix the Claude API timeout in the on-call agent" "" "Retries now back off." >"$work/m9"
accepted "accepts a message that only mentions Claude" cm "$work/m9"
printf '%s\n' "Pair on the deploy CLI" "" "Co-authored-by: Alice Example <alice@example.com>" >"$work/m10"
accepted "accepts a human co-author" cm "$work/m10"
refused "refuses when the message file is missing" cm "$work/does-not-exist"
refused "refuses when no message file is given" sh "$hooks/commit-msg"
fi

if want pre-commit; then
echo "pre-commit"
for path in "private/notes.md" "Private/notes.md" "PRIVATE/notes.md" "docs/private/notes.md" \
  "private/café.md" "private/my notes.md" "secrets/token.txt" "stacks/edge/secrets/creds.json" \
  ".env" "deploy/.env" "prod.env" ".ENV" ".env.local" ".env.production" "notes.local.md" \
  ".claude/settings.local.json" "private/.env.example" "secrets/.env.example" \
  "deploy/server.key" "certs/site.pem" "id_ed25519" "keys/id_rsa.pub" "home/.ssh/id_ecdsa"; do
  new_repo
  stage "$path"
  refused "refuses $path" pc
done
for path in ".env.example" "deploy/.env.example" "x.env.example" "docs/private-notes.md" \
  "docs/secrets.md" "config/environment.ts" "stacks/edge/private" "docs/keys.md" \
  "host/setup/keyring-notes.md"; do
  new_repo
  stage "$path"
  accepted "accepts $path" pc
done

new_repo
stage "README.md"
stage "private/a.md"
stage "docs/b.md"
refused "refuses when one of several staged paths is private" pc
said "names the private path" "private/a.md"

new_repo
stage "private/old.md"
fixture_commit "a private file committed by mistake"
git rm -q --cached -- private/old.md
accepted "accepts removing a committed private file" pc

new_repo
stage "README.md"
if [ "$hide_ok" = yes ]; then
  accepted "with gitleaks missing, a clean commit goes through" pc
  said "... with a warning that nothing was scanned" "gitleaks is not installed"
else
  skip "gitleaks missing: it can't be hidden from PATH here"
fi
: >"$STUB_LOG"
accepted "with a clean gitleaks scan, the commit goes through" \
  env PATH="$stub_path" STUB_EXIT=0 sh "$hooks/pre-commit"
if grep -qx -- "--pre-commit" "$STUB_LOG" && grep -qx -- "--staged" "$STUB_LOG"; then
  ok "gitleaks scans the staged changes"
else
  not_ok "gitleaks scans the staged changes (arguments: $(tr '\n' ' ' <"$STUB_LOG"))"
fi
refused "a gitleaks finding stops the commit" env PATH="$stub_path" STUB_EXIT=1 sh "$hooks/pre-commit"
refused "a gitleaks error stops the commit" env PATH="$stub_path" STUB_EXIT=2 sh "$hooks/pre-commit"

new_repo
stage "private/a.md"
: >"$STUB_LOG"
refused "with gitleaks installed, a private path is still refused" \
  env PATH="$stub_path" STUB_EXIT=0 sh "$hooks/pre-commit"
if [ -s "$STUB_LOG" ]; then not_ok "... before gitleaks runs"; else ok "... before gitleaks runs"; fi
if [ "$hide_ok" = yes ]; then
  refused "with gitleaks missing, a private path is still refused" pc
fi
fi

if want wired; then
echo "hooks wired through core.hooksPath"
new_repo
git config core.hooksPath "$hooks"
stage "private/a.md"
refused "git commit runs pre-commit and refuses a private path" \
  env PATH="$nogl_path" git commit -q -m "Add notes"
if git rev-parse -q --verify HEAD >/dev/null; then
  not_ok "... and nothing was committed"
else
  ok "... and nothing was committed"
fi
new_repo
git config core.hooksPath "$hooks"
stage "a.txt"
refused "git commit runs commit-msg and refuses an attribution trailer" \
  env PATH="$nogl_path" git commit -q -m "Add a" -m "$trailer"
if git rev-parse -q --verify HEAD >/dev/null; then
  not_ok "... and nothing was committed"
else
  ok "... and nothing was committed"
fi
accepted "a clean git commit goes through both hooks" env PATH="$nogl_path" git commit -q -m "Add a"
fi

if want pre-push-main; then
echo "pre-push: signatures on main"
new_repo
git config gpg.format ssh
git config user.signingkey "$work/key"
git config gpg.ssh.allowedSignersFile "$work/allowed_signers"
mkdir -p .githooks
fixture_commit "first"
first=$(git rev-parse HEAD)
fixture_commit "the baseline"
base=$(git rev-parse HEAD)
git update-ref refs/remotes/origin/main "$base"
fixture_commit "unsigned work on main"
tip=$(git rev-parse HEAD)

: >.githooks/signed-baseline
accepted "an empty baseline lets main through" pp "refs/heads/main $tip refs/heads/main $base"
said "... with a warning" "signed-baseline is empty"
printf '# the baseline goes here once signing works\n' >.githooks/signed-baseline
accepted "a baseline with only a comment counts as empty" pp "refs/heads/main $tip refs/heads/main $base"
rm -f .githooks/signed-baseline
refused "a missing baseline file stops a push to main" pp "refs/heads/main $tip refs/heads/main $base"
printf 'not-a-commit\n' >.githooks/signed-baseline
refused "a malformed baseline stops a push to main" pp "refs/heads/main $tip refs/heads/main $base"
printf '0123456789abcdef0123456789abcdef01234567\n' >.githooks/signed-baseline
refused "a baseline naming an unknown commit stops a push to main" pp "refs/heads/main $tip refs/heads/main $base"
said "... and says to fetch it" "not in this repository"
printf '%s\n' "$(git rev-parse --short "$base")" >.githooks/signed-baseline
refused "a short hash in the baseline is refused" pp "refs/heads/main $base refs/heads/main $first"
printf '%s\n%s\n' "$base" "$first" >.githooks/signed-baseline
refused "two hashes in the baseline stop a push to main" pp "refs/heads/main $tip refs/heads/main $base"

printf '%s\n' "$base" >.githooks/signed-baseline
refused "an unsigned commit on main after the baseline is refused" pp "refs/heads/main $tip refs/heads/main $base"
said "... and listed" "$(git rev-parse --short "$tip")"

git reset -q --hard "$base"
git -c user.signingkey="$work/otherkey" commit -q --no-verify --allow-empty -S \
  -m "signed with a key that isn't allowed" </dev/null || { echo "setup failed" >&2; exit 1; }
refused "a commit signed with a key that isn't allowed is refused" \
  pp "refs/heads/main $(git rev-parse HEAD) refs/heads/main $base"

git reset -q --hard "$base"
fixture_commit "a signed commit" -S
good=$(git rev-parse HEAD)
accepted "a commit with a good signature after the baseline goes through" \
  pp "refs/heads/main $good refs/heads/main $base"
git config --unset gpg.ssh.allowedSignersFile
refused "without gpg.ssh.allowedSignersFile the signature can't be checked, so it's refused" \
  pp "refs/heads/main $good refs/heads/main $base"
said "... with a hint" "allowedSignersFile is not set"
git config gpg.ssh.allowedSignersFile "$work/allowed_signers"

upper=$(printf '%s' "$base" | tr 'a-f' 'A-F')
printf '  %s  \r\n' "$upper" >.githooks/signed-baseline
accepted "the baseline may have upper case, spaces and CRLF" pp "refs/heads/main $good refs/heads/main $base"
printf '%s\n' "$base" >.githooks/signed-baseline

git reset -q --hard "$base"
git switch -q -c develop
fixture_commit "feature work, unsigned"
dev=$(git rev-parse HEAD)
git switch -q main
git merge -q --no-ff -S -m "Merge branch 'develop'" develop </dev/null ||
  { echo "setup failed: signed merge" >&2; exit 1; }
accepted "a signed merge covers the unsigned commits it brings in" \
  pp "refs/heads/main $(git rev-parse HEAD) refs/heads/main $base"
git reset -q --hard "$base"
git merge -q --ff-only develop </dev/null || { echo "setup failed: fast-forward" >&2; exit 1; }
refused "fast-forwarding main to unsigned commits is refused" \
  pp "refs/heads/main $(git rev-parse HEAD) refs/heads/main $base"

accepted "pushing main at the baseline itself goes through" pp "refs/heads/main $base refs/heads/main $first"
refused "a main that doesn't contain the baseline is refused" pp "refs/heads/main $first refs/heads/main $base"
refused "pushing develop to main (develop:main) gets the main checks" pp "refs/heads/develop $dev refs/heads/main $base"
refused "the main checks ignore letter case in the ref name" pp "refs/heads/develop $dev refs/heads/MAIN $base"
accepted "unsigned commits on develop go through" pp "refs/heads/develop $dev refs/heads/develop $base"
refused "one bad ref stops the whole push" \
  pp "refs/heads/develop $dev refs/heads/develop $base" "refs/heads/develop $dev refs/heads/main $base"
refused "deleting main is refused" pp "(delete) $zero refs/heads/main $base"
accepted "deleting another branch is allowed" pp "(delete) $zero refs/heads/feature/old $base"
refused "input that isn't a commit hash is refused" pp "refs/heads/main not-a-sha refs/heads/main $base"
refused "a ref name in place of a hash is refused" pp "refs/heads/develop HEAD refs/heads/develop $base"
fi

if want pre-push-outgoing; then
echo "pre-push: every outgoing commit"
new_repo
fixture_commit "first"
git update-ref refs/remotes/origin/develop HEAD
git switch -q -c feature/notes
stage "private/notes.md"
fixture_commit "add my notes"
refused "an outgoing commit that adds private/ is refused" \
  pp "refs/heads/feature/notes $(git rev-parse HEAD) refs/heads/feature/notes $zero"
said "... and the path is named" "private/notes.md"
git rm -q -- private/notes.md
fixture_commit "remove my notes again"
refused "a private file added and removed again is still refused" \
  pp "refs/heads/feature/notes $(git rev-parse HEAD) refs/heads/feature/notes $zero"

new_repo
stage "private/first-notes.md"
fixture_commit "a first commit that adds private notes"
refused "a first commit (no parent) that adds private/ is refused" \
  pp "refs/heads/develop $(git rev-parse HEAD) refs/heads/develop $zero"

new_repo
fixture_commit "first"
start=$(git rev-parse HEAD)
git switch -q -c feature/z
stage "docs/z.md"
fixture_commit "feature work"
git switch -q main
git merge -q --no-ff --no-commit feature/z </dev/null >/dev/null 2>&1
stage "private/merge-notes.md"
fixture_commit "Merge feature/z"
refused "a private file added in a merge commit itself is refused" \
  pp "refs/heads/develop $(git rev-parse HEAD) refs/heads/develop $start"

new_repo
fixture_commit "first"
git update-ref refs/remotes/origin/develop HEAD
fixture_commit "Add the hooks" -m "$trailer"
refused "an outgoing commit with AI attribution in its message is refused" \
  pp "refs/heads/develop $(git rev-parse HEAD) refs/heads/develop $(git rev-parse HEAD~1)"

new_repo
stage "private/old.md"
fixture_commit "an old mistake the remote already has"
git update-ref refs/remotes/origin/develop HEAD
stage "docs/new.md"
fixture_commit "new work"
old=$(git rev-parse HEAD~1)
new=$(git rev-parse HEAD)
accepted "commits the remote already has are not checked again" pp "refs/heads/develop $new refs/heads/develop $old"
accepted "... also for a new branch on top of them" pp "refs/heads/feature/y $new refs/heads/feature/y $zero"
accepted "... also when the remote's commit isn't known here" \
  pp "refs/heads/develop $new refs/heads/develop 1111111111111111111111111111111111111111"

: >"$STUB_LOG"
STUB_EXIT=0
accepted "with a clean gitleaks scan, the push goes through" pp_stub "refs/heads/develop $new refs/heads/develop $old"
if grep -qxF -- "--log-opts=$old..$new" "$STUB_LOG"; then
  ok "gitleaks scans exactly the outgoing commits"
else
  not_ok "gitleaks scans exactly the outgoing commits (arguments: $(tr '\n' ' ' <"$STUB_LOG"))"
fi
: >"$STUB_LOG"
accepted "a new branch is scanned against what the remotes already have" \
  pp_stub "refs/heads/feature/y $new refs/heads/feature/y $zero"
if grep -qxF -- "--log-opts=$new --not --remotes" "$STUB_LOG"; then
  ok "... which is what gitleaks is given"
else
  not_ok "... which is what gitleaks is given (arguments: $(tr '\n' ' ' <"$STUB_LOG"))"
fi
STUB_EXIT=1
refused "a gitleaks finding stops the push" pp_stub "refs/heads/develop $new refs/heads/develop $old"
STUB_EXIT=2
refused "a gitleaks error stops the push" pp_stub "refs/heads/develop $new refs/heads/develop $old"
STUB_EXIT=0
if [ "$hide_ok" = yes ]; then
  accepted "with gitleaks missing, a clean push goes through" pp "refs/heads/develop $new refs/heads/develop $old"
  said "... with a warning that nothing was scanned" "gitleaks is not installed"
else
  skip "gitleaks missing: it can't be hidden from PATH here"
fi
fi

if want pre-push-release; then
echo "pre-push: the first release"
new_repo
printf '# nightshift\n' >README.md
git add README.md
fixture_commit "Initial commit"
init=$(git rev-parse HEAD)
git update-ref refs/remotes/origin/main "$init"
git update-ref refs/remotes/origin/develop "$init"
git switch -q -c develop
mkdir -p .githooks docs
: >.githooks/signed-baseline
printf '# Variable NAMES only\n' >.env.example
printf 'plan\n' >docs/PLAN.md
git add .githooks .env.example docs
fixture_commit "Add the scaffold"
git switch -q main
git merge -q --no-ff -m "Merge branch 'develop'" develop </dev/null ||
  { echo "setup failed: release merge" >&2; exit 1; }
accepted "scaffold on develop, unsigned merge to main, empty baseline: the push goes through" \
  pp "refs/heads/main $(git rev-parse main) refs/heads/main $init" \
  "refs/heads/develop $(git rev-parse develop) refs/heads/develop $init"
said "... with a warning that the baseline is empty" "signed-baseline is empty"
if [ "$hide_ok" = yes ]; then
  said "... and one that gitleaks is missing" "gitleaks is not installed"
fi
fi

echo
echo "$passed passed, $failed failed, $skipped skipped"
if [ $((passed + failed)) -eq 0 ]; then
  echo "no tests ran: check the section names" >&2
  exit 1
fi
[ "$failed" -eq 0 ]
