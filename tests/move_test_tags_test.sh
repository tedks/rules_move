#!/usr/bin/env bash
# The argument is a genquery output that lists the fixture's move_test only
# when its tags include both block-network and no-remote-exec.
set -euo pipefail
labels=$(tr -s '[:space:]' ' ' <"$1" | sed 's/ *$//')
[[ "$labels" == "//tests/move_fixture:move_test" ]] || {
  echo "move_test is missing block-network or no-remote-exec (query: '$labels')" >&2
  exit 1
}
