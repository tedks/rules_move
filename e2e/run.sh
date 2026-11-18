#!/usr/bin/env bash
# End-to-end check: consume rules_move from an archive of the committed
# tree in a separate Bazel workspace.
#
# The consumer root depends on rules_move only through archive_override
# (a file:// URL and its integrity), exactly as it would on a release
# archive. It declares its own Sui release and dependency repositories, has
# a Move package in its main repository and another in an external
# repository (@fixture_child, a local_repository), and checks that:
#
#   - both packages build bytecode and pass their tests (2 Move tests each);
#   - rules_move appears exactly once on the module graph;
#   - a broken assertion fails each package's move_test, and a compile error
#     fails the external package's build;
#   - a target whose srcs come from another repository is refused, in both
#     directions, and a package path that leaves the repository is refused.
#
# usage: e2e/run.sh   (from the repository root, inside `nix develop`)
# Needs network for the first fetch of the Sui release and the Move stdlib.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
head=$(git -C "$root" rev-parse HEAD)
[[ -z "$(git -C "$root" status --porcelain)" ]] || echo "note: uncommitted changes are NOT tested; testing HEAD $head" >&2

scratch=$(mktemp -d "${TMPDIR:-/tmp}/rules_move_e2e.XXXXXX")
ws=$scratch/consumer
child=$scratch/child
output_base=$scratch/output_base
bazel_cmd() { (cd "$ws" && bazel --output_base="$output_base" "$@" </dev/null); }
cleanup() {
  bazel_cmd shutdown >/dev/null 2>&1 || true
  chmod -R u+w "$scratch" 2>/dev/null || true
  # $scratch was created above by mktemp in this script; nothing else lives there.
  rm -rf -- "$scratch"
}
trap cleanup EXIT

failures=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1" >&2; failures=$((failures + 1)); }

# The archive Bazel consumes: the committed tree, as a release would be.
archive=$scratch/rules_move.tar.gz
git -C "$root" archive --format=tar.gz --prefix=rules_move/ -o "$archive" "$head"
hex=$(sha256sum "$archive" | cut -d' ' -f1)
# shellcheck disable=SC2059 # the format is the digest as \x escapes
integrity="sha256-$(printf "$(sed 's/../\\x&/g' <<<"$hex")" | base64 -w0)"

# One Move package, laid out under DIR (a package directory).
write_package() {
  local dir=$1
  mkdir -p "$dir/sources" "$dir/tests"
  cp "$root/tests/move_fixture/Move.toml" "$root/tests/move_fixture/Move.lock" "$dir/"
  cp "$root/tests/move_fixture/sources/counter.move" "$dir/sources/"
  cp "$root/tests/move_fixture/tests/counter_tests.move" "$dir/tests/"
  cat >"$dir/BUILD.bazel" <<'EOF'
load("@rules_move//sui_move:defs.bzl", "move_package", "move_test")

filegroup(
    name = "srcs",
    srcs = ["Move.lock", "Move.toml"] + glob(["sources/*.move", "tests/*.move"]),
    visibility = ["//visibility:public"],
)

move_package(
    name = "pkg",
    srcs = [":srcs"],
    git = "@move_host_git//:git",
    sui = "@sui_cli//:sui",
    deps = ["@move_std//:cache.tar"],
)

move_test(
    name = "move_test",
    size = "medium",
    srcs = [":srcs"],
    git = "@move_host_git//:git",
    sui = "@sui_cli//:sui",
    deps = ["@move_std//:cache.tar"],
)
EOF
}

mkdir -p "$ws" "$child"
write_package "$ws/app"
write_package "$child/pkg"
: >"$child/REPO.bazel"
cp "$root/.bazelversion" "$ws/"
printf 'build --incompatible_strict_action_env\ntest --test_output=errors\n' >"$ws/.bazelrc"
cat >"$ws/MODULE.bazel" <<EOF
module(name = "e2e_consumer")

bazel_dep(name = "rules_move", version = "0.1.0")
archive_override(
    module_name = "rules_move",
    integrity = "$integrity",
    strip_prefix = "rules_move",
    urls = ["file://$archive"],
)

sui_release = use_repo_rule("@rules_move//sui_move:repositories.bzl", "sui_release")
move_git_dependency = use_repo_rule("@rules_move//sui_move:repositories.bzl", "move_git_dependency")
move_host_git = use_repo_rule("@rules_move//sui_move:repositories.bzl", "move_host_git")
local_repository = use_repo_rule("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")

move_host_git(name = "move_host_git")

sui_release(
    name = "sui_cli",
    archives = {
        "linux-x86_64": [
            "https://github.com/MystenLabs/sui/releases/download/mainnet-v1.80.1/sui-mainnet-v1.80.1-ubuntu-x86_64.tgz",
            "sha256-l/mu0Q4ML+MgTORjmsmS4USbF8FPIvMOn5A+rVSsczY=",
        ],
    },
    version = "1.80.1",
)

move_git_dependency(
    name = "move_std",
    commit = "782577ca40c9ef0b3f400ade8bc2cc2dcd0e2b23",
    paths = ["crates/sui-framework/packages/move-stdlib"],
    remote = "https://github.com/MystenLabs/sui.git",
)

local_repository(name = "fixture_child", path = "$child")
EOF

echo "rules_move e2e: HEAD $head, archive $integrity"

# 1. Both packages build and test, from the main and the external repository.
if bazel_cmd test //... @fixture_child//... >"$scratch/test.log" 2>&1; then
  ok "test //... @fixture_child//..."
else
  bad "test //... @fixture_child//..."
  tail -40 "$scratch/test.log" >&2
fi
testlogs=$(bazel_cmd info bazel-testlogs 2>/dev/null)
for log in "$testlogs/app/move_test/test.log" "$testlogs"/external/*fixture_child*/pkg/move_test/test.log; do
  if grep -q "^Test result: OK. Total tests: 2; passed: 2; failed: 0$" "$log" 2>/dev/null; then
    ok "2/2 Move tests in ${log#"$testlogs"/}"
  else
    bad "no 2/2 test summary in ${log#"$testlogs"/}"
  fi
done
if bazel_cmd build //app:pkg @fixture_child//pkg:pkg >"$scratch/build.log" 2>&1; then
  execroot=$(bazel_cmd info execution_root 2>/dev/null)
  for target in //app:pkg @fixture_child//pkg:pkg; do
    out=$(bazel_cmd cquery --output=files "$target" 2>/dev/null)
    if [[ -f "$execroot/$out/move_fixture/bytecode_modules/counter.mv" ]]; then
      ok "bytecode for $target ($(sha256sum <"$execroot/$out/move_fixture/bytecode_modules/counter.mv" | cut -c1-16))"
    else
      bad "no bytecode for $target"
    fi
  done
else
  bad "build //app:pkg @fixture_child//pkg:pkg"
fi

# 2. Exactly one rules_move on the module graph.
count=$(bazel_cmd mod graph 2>/dev/null | grep -c 'rules_move@' || true)
if [[ "$count" -eq 1 ]]; then ok "one rules_move on the module graph"; else bad "rules_move appears $count times on the module graph"; fi

# 3. Failure propagation in both repositories.
expect_fail() { # NAME NEEDLE -- bazel args...
  local name=$1 needle=$2
  shift 3
  if bazel_cmd "$@" >"$scratch/fail.log" 2>&1; then
    bad "$name: succeeded"
  elif grep -qF -- "$needle" "$scratch/fail.log" || grep -rqF -- "$needle" "$testlogs" 2>/dev/null; then
    ok "$name"
  else
    bad "$name: no '$needle'"
    tail -20 "$scratch/fail.log" >&2
  fi
}
break_file() { cp "$1" "$1.orig"; local t; t=$(<"$1"); printf '%s\n' "${t/"$2"/"$3"}" >"$1"; }
restore_file() { mv "$1.orig" "$1"; }

break_file "$ws/app/tests/counter_tests.move" "== 42" "== 41"
expect_fail "broken assertion fails //app:move_test" "Total tests: 2; passed: 1; failed: 1" -- test //app:move_test
restore_file "$ws/app/tests/counter_tests.move"

break_file "$child/pkg/tests/counter_tests.move" "== 42" "== 41"
expect_fail "broken assertion fails @fixture_child//pkg:move_test" "Total tests: 2; passed: 1; failed: 1" -- test @fixture_child//pkg:move_test
restore_file "$child/pkg/tests/counter_tests.move"

break_file "$child/pkg/sources/counter.move" "x * 2" "x * true"
expect_fail "compile error fails @fixture_child//pkg:pkg" "sui move build failed" -- build @fixture_child//pkg:pkg
restore_file "$child/pkg/sources/counter.move"

# 4. Sources from another repository, and package paths that leave the
#    repository, are refused at analysis.
mkdir -p "$ws/cross"
cat >"$ws/cross/BUILD.bazel" <<'EOF'
load("@rules_move//sui_move:defs.bzl", "move_test")

move_test(
    name = "from_child",
    srcs = ["@fixture_child//pkg:srcs"],
    git = "@move_host_git//:git",
    package = "pkg",
    sui = "@sui_cli//:sui",
    deps = ["@move_std//:cache.tar"],
)
EOF
expect_fail "main-repo target with external srcs is refused" "must come from its own repository" -- build //cross:from_child
rm -r "$ws/cross"

mkdir -p "$child/cross"
cat >"$child/cross/BUILD.bazel" <<'EOF'
load("@rules_move//sui_move:defs.bzl", "move_package")

move_package(
    name = "from_main",
    srcs = ["@@//app:srcs"],
    git = "@move_host_git//:git",
    package = "app",
    sui = "@sui_cli//:sui",
    deps = ["@move_std//:cache.tar"],
)

move_package(
    name = "escape",
    srcs = ["//pkg:srcs"],
    git = "@move_host_git//:git",
    package = "../pkg",
    sui = "@sui_cli//:sui",
    deps = ["@move_std//:cache.tar"],
)
EOF
expect_fail "external target with main-repo srcs is refused" "must come from its own repository" -- build @fixture_child//cross:from_main
expect_fail "package path leaving the repository is refused" "package must be a workspace-relative directory" -- build @fixture_child//cross:escape
rm -r "$child/cross"

# 5. Restored tree passes again.
if bazel_cmd test //... @fixture_child//... >"$scratch/test2.log" 2>&1; then ok "restored tree passes"; else bad "restored tree fails"; fi

if [[ $failures -ne 0 ]]; then
  echo "e2e: $failures check(s) failed" >&2
  exit 1
fi
echo "e2e: all checks passed"
