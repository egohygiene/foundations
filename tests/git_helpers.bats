#!/usr/bin/env bats

# ------------------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------------------

# Resolve project root relative to THIS test file (not cwd)
PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SCRIPT_PATH="${PROJECT_ROOT}/scripts/megalinter.sh"

# ------------------------------------------------------------------------------
# Setup / Teardown
# ------------------------------------------------------------------------------

setup() {
  TEST_WORKDIR="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${TEST_WORKDIR}"
  cd "${TEST_WORKDIR}"

  git init --quiet

  # Source using absolute path
    set +e

    printf "Sourcing script at: %s\n" "${SCRIPT_PATH}"

    # shellcheck disable=SC1090
    source "${SCRIPT_PATH}"
    set -e
}

teardown() {
  cd "${BATS_TEST_TMPDIR}" || true
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

setup_git_remote() {
  local remote_url="$1"
  git remote add origin "${remote_url}"
}

# ------------------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------------------

@test "returns unknown/unknown when no remote origin exists" {
  run get_github_repository
  [ "$status" -eq 0 ]
  [ "$output" = "unknown/unknown" ]
}

@test "parses SSH remote correctly" {
  setup_git_remote "git@github.com:test/example.git"
  run get_github_repository
  [ "$output" = "test/example" ]
}

@test "parses HTTPS remote correctly" {
  setup_git_remote "https://github.com/test/example.git"
  run get_github_repository
  [ "$output" = "test/example" ]
}

@test "parses HTTPS remote without .git suffix" {
  setup_git_remote "https://github.com/test/example"
  run get_github_repository
  [ "$output" = "test/example" ]
}

@test "handles malformed remote gracefully" {
  setup_git_remote "not-a-valid-url"
  run get_github_repository
  [ "$output" = "unknown/unknown" ]
}