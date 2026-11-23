# Shared setup for db-snap bats tests. Every test gets an isolated $HOME
# (snapshot store, ~/dumps, ~/.config) and a fake `docker` on PATH.

SCRIPT="$BATS_TEST_DIRNAME/../db-snap"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset XDG_CONFIG_HOME DB_SERVICE PHP_SERVICE DB_SNAP_NO_AUTOSAVE DB_SNAP_AUTOSAVE_KEEP \
    FAKE_RESOLVE_DEFAULT FAKE_TABLES FAKE_IMPORT_FAIL FAKE_DEPLOY_RC
  export PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export FAKE_LOG="$BATS_TEST_TMPDIR/docker.log"
  : > "$FAKE_LOG"
  PROJ="$BATS_TEST_TMPDIR/proj-x"
  # shellcheck disable=SC2034 # used by db-snap.bats
  SNAPS="$HOME/.local/share/db-snapshots/proj-x"
}

# Run db-snap with stdin closed — any unexpected prompt fails the test.
run_snap() {
  run bash "$SCRIPT" "$@" < /dev/null
}

# Run db-snap answering prompts with $1 (one line per prompt).
run_snap_input() {
  local input="$1"; shift
  run bash "$SCRIPT" "$@" <<< "$input"
}

make_singlesite() {
  mkdir -p "$PROJ/web/sites/default"
  cat > "$PROJ/.env" <<'EOF'
DB_USER=drupal
DB_PASSWORD=pw
DB_ROOT_PASSWORD=rootpw
DB_NAME=drupal
EOF
  touch "$PROJ/docker-compose.yml"
  cd "$PROJ" || return
}

# Multisite with site_a + site_b (+ any extra dirs passed as args).
make_multisite() {
  make_singlesite
  local s
  for s in site_a site_b "$@"; do mkdir -p "$PROJ/web/sites/$s"; done
}

# Write a valid gzip dump at $1.
make_dump() {
  mkdir -p "$(dirname "$1")"
  echo "-- dump $1" | gzip > "$1"
}

# Fail if the docker log contains $1. (Bare `! grep` does NOT fail a bats
# test unless it's the last line — set -e ignores negated commands.)
refute_log() {
  if grep -q -- "$1" "$FAKE_LOG"; then
    echo "unexpected docker call matching '$1':" >&2
    grep -- "$1" "$FAKE_LOG" >&2
    return 1
  fi
}

# Line number of first log line matching $1 (empty if none).
log_line() {
  grep -n -m1 -- "$1" "$FAKE_LOG" | cut -d: -f1
}
