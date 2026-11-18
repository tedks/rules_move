# rules_move

Bazel rules that compile a [Sui](https://github.com/MystenLabs/sui) Move
package and run its Move unit tests without network access, using the Sui
CLI release a project already pins.

- `move_package` compiles a package with `sui move build` and outputs its
  bytecode (`<name>/bytecode_modules/*.mv`, plus compiled dependencies under
  `bytecode_modules/dependencies/`).
- `move_test` runs the package's unit tests with `sui move test` and fails
  when the CLI fails or reports zero tests.
- `sui_pin_test` checks that the pinned release also appears in another pin
  source, such as a Nix flake.
- Repository rules: `sui_release` (one official release archive per host
  platform, by integrity), `move_git_dependency` (one pinned commit of a Move
  git dependency, in the Sui CLI's cache layout) and `move_host_git` (the
  host git the CLI drives).

Linux x86_64 is the exercised platform; Linux aarch64 archives can be
declared. Bazel 7.6 and 8 are supported. MIT licensed.

## Add the module

The module is not in the Bazel Central Registry. Declare it and point it at
a fixed revision, for example a git submodule:

```starlark
bazel_dep(name = "rules_move", version = "0.1.0")
local_path_override(
    module_name = "rules_move",
    path = "third_party/rules_move",  # a submodule pinned to a commit
)
```

or a fetched commit:

```starlark
git_override(
    module_name = "rules_move",
    commit = "<full commit>",
    remote = "https://github.com/tedks/rules_move.git",
)
```

A submodule inside the workspace must be hidden from the root module's own
packages: list it in `.bazelignore` (or `ignore_directories` in
`REPO.bazel`), so its tests and BUILD files are not part of `//...`.

## Use

In `MODULE.bazel`:

```starlark
sui_release = use_repo_rule("@rules_move//sui_move:repositories.bzl", "sui_release")
move_git_dependency = use_repo_rule("@rules_move//sui_move:repositories.bzl", "move_git_dependency")
move_host_git = use_repo_rule("@rules_move//sui_move:repositories.bzl", "move_host_git")

move_host_git(name = "move_host_git")

sui_release(
    name = "sui_cli",
    archives = {"linux-x86_64": ["<release .tgz URL>", "sha256-<SRI>"]},
    version = "1.80.1",
)

# One per git source (remote + rev) in Move.lock, with the subdirectories used.
move_git_dependency(
    name = "move_sui_<rev>",
    commit = "<full rev from Move.lock>",
    paths = ["crates/sui-framework/packages/move-stdlib", "crates/sui-framework/packages/sui-framework"],
    remote = "https://github.com/MystenLabs/sui.git",
)
```

In the package's `BUILD.bazel`:

```starlark
load("@rules_move//sui_move:defs.bzl", "move_package", "move_test", "sui_pin_test")

move_package(  # outputs <name>/bytecode_modules/*.mv (+ dependencies/)
    name = "pkg",
    srcs = ["Move.toml", "Move.lock"] + glob(["sources/**", "tests/**"]),
    git = "@move_host_git//:git",
    sui = "@sui_cli//:sui",
    deps = ["@move_sui_<rev>//:cache.tar"],
)

move_test(name = "move_test", ...same attributes...)

sui_pin_test(  # the release pins must also appear in, e.g., flake.nix
    name = "sui_pin_test",
    files = ["//:flake.nix"],
    pins = "@sui_cli//:pins.txt",
)
```

`srcs` must contain every file the package reads, including `local`
dependency packages. A package at a repository root (a BUILD file there, or
`package = "."`) is supported.

## Behavior and limits

- Actions copy `srcs` into a private directory, set a fresh `MOVE_HOME` from
  the `deps` archives and a keyless client configuration, point the CLI's RPC
  endpoints at a closed loopback port, and refuse every git transport. A
  missing dependency fails; nothing is fetched by git.
- Those measures stop git and chain RPC from reaching the network. Blocking
  every other connection relies on Bazel's sandbox: `move_package` actions
  request `block-network` and `move_test` always carries that tag, which the
  Linux sandbox enforces. Both also request `no-remote-exec`: the tools are
  an absolute host git path and a binary chosen for the host, so the actions
  always run locally. With
  `--spawn_strategy=local` (or another unsandboxed strategy) that tag does
  nothing, and "offline" means only the guarantees above.
- `srcs` must include `Move.lock`, and a lock that is stale for the pinned CLI
  fails, even when the CLI could re-resolve it from cached sources: the
  committed lock is the pin. In test mode staleness is detected from the CLI's
  "Updating dependencies" notice, which the rules' own tests pin for the CLI
  they run; consumers on another CLI version should confirm it once.
- `move_test` fails when the CLI fails or reports zero tests.
- The build output contains bytecode only; the CLI's `BuildInfo.yaml`, debug
  info and source maps embed an absolute scratch path and are omitted.
- `sui_pin_test` is a presence check: each pinned value must appear somewhere
  in the listed files. A stale copy of a value left elsewhere in those files
  would still satisfy it.
- `cache.tar` holds a git checkout. Its content is fixed by the commit, but
  its bytes (git index stat data, pack layout) can differ between fetches, so
  action cache entries are not shared across hosts or refetches.
- Sources must come from the target's own repository (the main repository
  or an external one, such as a vendored child); each is staged at its path
  relative to that repository's root. Sources from another repository, and
  `package` paths that leave the repository, are refused at analysis.
- Actions use Bazel's default shell environment for `PATH` (bash, coreutils,
  tar). Set `--incompatible_strict_action_env` to keep host `PATH` changes out
  of action keys.
- The official Sui release is an unpatched glibc binary that names the FHS
  loader (`/lib64/ld-linux-x86-64.so.2`). When `MOVE_SUI_LOADER` (a dynamic
  loader) and `MOVE_SUI_LIBRARY_PATH` (directories holding glibc,
  libstdc++ and libgcc_s) are set, `sui_release` runs the fetch-time probe
  through that loader and `:sui` becomes a wrapper that runs the release the
  same way in every build and test, so no FHS loader, nix-ld or other host
  configuration is needed. A Nix dev shell exports both from its pinned
  nixpkgs:

  ```nix
  MOVE_SUI_LOADER = pkgs.stdenv.cc.bintools.dynamicLinker;
  MOVE_SUI_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.libc pkgs.stdenv.cc.cc.lib ];
  ```

  Changing either refetches `sui_release` (the archive comes from the
  repository cache). Without them the release runs directly and the host
  needs the FHS loader and libstdc++; a failing probe says so.
- Host requirements: Linux; git, tar and env on the PATH Bazel sees; and bash,
  coreutils and tar on the action PATH. Under
  `--incompatible_strict_action_env` that PATH is
  `/bin:/usr/bin:/usr/local/bin` for upstream Bazel; the nixpkgs Bazel
  substitutes its own bash and coreutils.
- `sui_release` fetches the archive for the host platform only. A host with no
  listed archive downloads no Sui binary, and the targets that need it are
  skipped as incompatible. On a platform the rules do not support (anything
  but Linux x86_64 or aarch64) the dependency and git repositories are
  incompatible stubs too and nothing is fetched; on a supported platform
  whose release has no listed archive, the small git dependency fetches still
  run when those targets are loaded. A supported host missing git or tar
  fails instead of skipping, so a misconfigured machine cannot hide the
  tests. `move_test` takes its tools in the target configuration, so it is
  also skipped when `--platforms` names an unsupported target. Remote
  execution is not supported: actions are pinned to local execution, and the
  `sui` binary is compatible only with the host's platform, so with an exec
  platform of different constraints registered first `move_package` is
  skipped as incompatible rather than failing.
- Dependency fetches run git with every inherited `GIT_*` variable removed
  except `GIT_SSL_CAINFO` and `GIT_SSL_CAPATH` (trust anchors only),
  without system or global configuration, with a private HOME, an empty
  template and no hooks. Non-`GIT_*` variables (proxy settings,
  `SSL_CERT_FILE`, ...) are inherited, never copied into arguments. Changing them does not refetch a
  git dependency; `move_host_git` deliberately re-runs when PATH changes, to
  pick up a different git.

## Development

```bash
nix develop --command bazel test //...
nix develop --command ./e2e/run.sh            # Bazel 8, after committing
E2E_BAZEL=$(nix build --no-link --print-out-paths .#bazel_7)/bin/bazel \
  nix develop --command ./e2e/run.sh          # the same check on Bazel 7.6
```

`//...` builds and tests the neutral fixture in `tests/move_fixture` and runs
`tests/runner_test.sh`, which drives the runner through its failure paths.
`e2e/run.sh` consumes an archive of the committed tree from a separate
workspace through `archive_override`, with Move packages in that
workspace's main repository, in an external repository and at the root of
another external repository, and checks builds, identical bytecode, tests,
failure propagation and the cross-repository refusals. The
first run downloads the Sui release (about 1.1 GB) into Bazel's repository
cache.
