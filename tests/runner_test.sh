#!/usr/bin/env bash
# Behavior of the Move runner (sui_move/runner.sh).
#
# Each case stages a private copy of tests/move_fixture, optionally breaks it,
# and runs the runner exactly as the move_package and move_test actions do.
# The cases pin the failure paths the Bazel targets rely on: a failing or
# missing test, a compile error, a missing or stale dependency pin, and
# staging outside the package root must all fail, while a good package builds
# deterministic bytecode and runs its tests without writing to its sources.
#
# usage: runner_test.sh RUNNER SUI GIT STD_TAR FIXTURE_FILE...
set -uo pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
RUNNER=$(abs "$1") SUI=$(abs "$2") GIT=$(abs "$3") STD_TAR=$(abs "$4")
shift 4
FIXTURE=()
for f in "$@"; do FIXTURE+=("$(abs "$f")"); done
PACKAGE=tests/move_fixture
if [[ -n "${TEST_TMPDIR:-}" ]]; then
  SCRATCH=$TEST_TMPDIR
else
  SCRATCH=$(mktemp -d)
  # Created just above by mktemp for this run only.
  trap 'rm -rf -- "$SCRATCH"' EXIT
fi

failures=0
case_root=""
log=""

# Fresh staged copy of the fixture under a new directory for each case.
setup() {
  case_root=$(mktemp -d "$SCRATCH/case.XXXXXX")
  log=$case_root/runner.log
  local f rel
  for f in "${FIXTURE[@]}"; do
    rel=$PACKAGE/${f##*/"$PACKAGE"/}
    mkdir -p "$case_root/$(dirname "$rel")"
    cp "$f" "$case_root/$rel"
  done
}

# Replaces one exact string in a fixture file; the string must be present.
edit() {
  local file=$case_root/$PACKAGE/$1 old=$2 new=$3
  local text
  text=$(<"$file")
  [[ "$text" == *"$old"* ]] || { echo "fixture edit: '$old' not in $1" >&2; return 1; }
  printf '%s\n' "${text/"$old"/"$new"}" >"$file"
}

# run MODE OUT [EXTRA_MANIFEST_LINE] -- [DEP...]; output goes to $log.
run_runner() {
  local mode=$1 out=$2 extra=$3
  shift 4
  local manifest=$case_root/stage.manifest
  (cd "$case_root" && find "$PACKAGE" -type f -printf '%p\t%p\n') >"$manifest"
  [[ -z "$extra" ]] || printf '%s\n' "$extra" >>"$manifest"
  (cd "$case_root" && timeout 120 "$RUNNER" "$mode" "$SUI" "$GIT" "$PACKAGE" mainnet "$manifest" "$out" "$@") \
    </dev/null >"$log" 2>&1
}

tree_digest() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum); }

pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1: $2" >&2
  [[ -f "$log" ]] && sed 's/^/     | /' "$log" >&2
  failures=$((failures + 1))
}
# expect_failure NAME NEEDLE... : the last run failed and printed every needle.
expect_failure() {
  local name=$1 rc=$2 needle
  shift 2
  [[ $rc -ne 0 ]] || { fail "$name" "runner succeeded"; return; }
  for needle in "$@"; do
    grep -qF -- "$needle" "$log" || { fail "$name" "output lacks '$needle'"; return; }
  done
  pass "$name"
}

# A good package passes its tests and leaves its sources untouched.
setup
before=$(tree_digest "$case_root/$PACKAGE")
run_runner test - "" -- "$STD_TAR"
rc=$?
if [[ $rc -ne 0 ]]; then
  fail runs_tests "runner failed ($rc)"
elif ! grep -qF "passed 2 Move unit tests" "$log"; then
  fail runs_tests "no 'passed 2 Move unit tests'"
elif [[ "$before" != "$(tree_digest "$case_root/$PACKAGE")" ]]; then
  fail runs_tests "sources changed"
else
  pass runs_tests_without_touching_sources
fi

# Two builds produce the same bytecode tree, without debug info.
setup
ok=1
for out in out1 out2; do
  run_runner build "$case_root/$out" "" -- "$STD_TAR" || { fail deterministic_bytecode "build $out failed"; ok=0; }
done
if [[ $ok -eq 1 ]]; then
  modules=$case_root/out1/move_fixture/bytecode_modules
  if [[ ! -f $modules/counter.mv ]]; then
    fail deterministic_bytecode "no counter.mv"
  elif [[ ! -d $modules/dependencies ]]; then
    fail deterministic_bytecode "no compiled dependencies"
  elif [[ -e $case_root/out1/move_fixture/debug_info ]]; then
    fail deterministic_bytecode "debug_info was copied"
  elif [[ "$(tree_digest "$case_root/out1")" != "$(tree_digest "$case_root/out2")" ]]; then
    fail deterministic_bytecode "outputs differ"
  else
    pass build_outputs_deterministic_bytecode
  fi
fi

setup
edit tests/counter_tests.move "== 42" "== 41"
run_runner test - "" -- "$STD_TAR"
expect_failure failing_assertion_fails $? "FAIL" "sui move test failed"

setup
rm "$case_root/$PACKAGE/tests/counter_tests.move"
run_runner test - "" -- "$STD_TAR"
expect_failure zero_tests_fail $? "zero tests"

setup
edit sources/counter.move "x * 2" "x * true"
run_runner build "$case_root/out" "" -- "$STD_TAR"
expect_failure compile_error_fails_build $? "sui move build failed"

# No dependency archive: the CLI must not fetch it.
setup
run_runner test - "" --
expect_failure missing_dependency_never_fetches $? "not allowed"

# A dependency edit changes the manifest digest the lock records; the CLI can
# re-resolve it offline from the cache, which must still fail.
setup
edit Move.toml '23" }' '23", override = true }'
run_runner test - "" -- "$STD_TAR"
expect_failure stale_lock_fails $? "stale"

setup
rm "$case_root/$PACKAGE/Move.lock"
run_runner test - "" -- "$STD_TAR"
expect_failure missing_lock_fails $? "no Move.lock staged"

setup
run_runner test - "$PACKAGE/Move.toml"$'\t'"../escape" -- "$STD_TAR"
expect_failure refuses_staging_outside_root $? "refusing to stage"

# A package at the staging root, as for a Move package at a repository root:
# the files are staged without a directory and the package path is ".".
setup
manifest=$case_root/stage.manifest
(cd "$case_root" && find "$PACKAGE" -type f -printf '%p\t%P\n') >"$manifest"
(cd "$case_root" && timeout 120 "$RUNNER" test "$SUI" "$GIT" . mainnet "$manifest" - "$STD_TAR") </dev/null >"$log" 2>&1
rc=$?
if [[ $rc -eq 0 ]] && grep -qF "passed 2 Move unit tests" "$log"; then
  pass package_at_root
else
  fail package_at_root "runner failed ($rc) or did not pass 2 tests"
fi

if [[ $failures -ne 0 ]]; then
  echo "$failures runner case(s) failed" >&2
  exit 1
fi
echo "all runner cases passed"
