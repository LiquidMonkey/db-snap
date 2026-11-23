#!/usr/bin/env bats
#
# Run: test/bats/bin/bats test/

load test_helper

# ── help / outside a project ────────────────────────────────────────────

@test "no args prints the header block and exits 1" {
  run_snap
  [ "$status" -eq 1 ]
  [[ "$output" == *"db-snap save|snap"* ]]
  [[ "$output" == *"DB_SNAP_NO_AUTOSAVE"* ]]
  [[ "$output" != *"set -euo"* ]]
}

@test "info works outside a project" {
  cd "$BATS_TEST_TMPDIR"
  run_snap info
  [ "$status" -eq 0 ]
  [[ "$output" == *"not in a project"* ]]
}

@test "ls all lists snapshots across projects" {
  cd "$BATS_TEST_TMPDIR"
  make_dump "$HOME/.local/share/db-snapshots/p1/one.sql.gz"
  make_dump "$HOME/.local/share/db-snapshots/p2/site_a/two.sql.gz"
  run_snap ls all
  [ "$status" -eq 0 ]
  [[ "$output" == *"[p1]"*"one.sql.gz"* ]]
  [[ "$output" == *"[p2]"*"(site_a)"*"two.sql.gz"* ]]
}

# ── validators ──────────────────────────────────────────────────────────

@test "delete rejects path traversal, leading dash, leading dot" {
  cd "$BATS_TEST_TMPDIR"
  local bad
  for bad in ../x -lt .hidden; do
    run_snap delete "$bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid label"* ]]
  done
}

@test "save rejects a leading-dash label" {
  make_singlesite
  run_snap save -lt
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid label"* ]]
}

# ── completion helpers ──────────────────────────────────────────────────

@test "__sites lists subsites, honours global + project IGNORE_SITES" {
  make_multisite styleguide shared
  run_snap __sites
  [ "$output" = $'shared\nsite_a\nsite_b\nstyleguide' ]

  mkdir -p "$HOME/.config/db-snap"
  echo "IGNORE_SITES=styleguide" > "$HOME/.config/db-snap/config"
  echo "IGNORE_SITES=shared" > "$PROJ/.db-snap"
  run_snap __sites
  [ "$status" -eq 0 ]
  [ "$output" = $'site_a\nsite_b' ]
}

@test "__sites / __labels print nothing outside a project" {
  cd "$BATS_TEST_TMPDIR"
  run_snap __sites
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_snap __labels
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "__labels returns unique labels from root and site dirs" {
  make_multisite
  make_dump "$SNAPS/root.sql.gz"
  make_dump "$SNAPS/site_a/shared.sql.gz"
  make_dump "$SNAPS/site_b/shared.sql.gz"
  run_snap __labels
  [ "$output" = $'root\nshared' ]
}

# ── site selection ──────────────────────────────────────────────────────

@test "multisite: save without site lists available sites" {
  make_multisite
  run_snap save x
  [ "$status" -eq 1 ]
  [[ "$output" == *"pass the site key"*"site_a"*"site_b"* ]]
}

@test "multisite: unknown site is rejected" {
  make_multisite
  run_snap save x nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown site 'nope'"* ]]
}

@test "multisite: drush falling back to sites/default is refused before any DROP" {
  make_multisite
  make_dump "$SNAPS/site_a/x.sql.gz"
  export FAKE_RESOLVE_DEFAULT=1
  run_snap -y restore x site_a
  [ "$status" -eq 1 ]
  [[ "$output" == *"resolved to 'sites/default'"* ]]
  refute_log "DROP DATABASE"
}

# ── save ────────────────────────────────────────────────────────────────

@test "save writes snapshot atomically (no .partial left)" {
  make_singlesite
  run_snap save mylabel
  [ "$status" -eq 0 ]
  [ -f "$SNAPS/mylabel.sql.gz" ]
  [ ! -e "$SNAPS/mylabel.sql.gz.partial" ]
  gunzip -c "$SNAPS/mylabel.sql.gz" | grep -q "fake dump"
}

@test "multisite save lands in site subdir" {
  make_multisite
  run_snap save x site_b
  [ "$status" -eq 0 ]
  [ -f "$SNAPS/site_b/x.sql.gz" ]
}

# ── restore + autosave ──────────────────────────────────────────────────

@test "restore autosaves the live DB before dropping it" {
  make_singlesite
  make_dump "$SNAPS/base.sql.gz"
  run_snap -y restore base
  [ "$status" -eq 0 ]
  ls "$SNAPS"/_autosave-*.sql.gz
  local dump drop
  dump="$(log_line mysqldump)"
  drop="$(log_line "DROP DATABASE")"
  [ -n "$dump" ] && [ -n "$drop" ]
  [ "$dump" -lt "$drop" ]
}

@test "restore skips autosave for an empty DB" {
  make_singlesite
  make_dump "$SNAPS/base.sql.gz"
  export FAKE_TABLES=0
  run_snap -y restore base
  [ "$status" -eq 0 ]
  [[ "$output" == *"Autosave skipped"* ]]
  [ -z "$(ls "$SNAPS"/_autosave-*.sql.gz 2>/dev/null)" ]
}

@test "DB_SNAP_NO_AUTOSAVE=1 skips autosave" {
  make_singlesite
  make_dump "$SNAPS/base.sql.gz"
  DB_SNAP_NO_AUTOSAVE=1 run_snap -y restore base
  [ "$status" -eq 0 ]
  refute_log mysqldump
}

@test "autosaves are pruned to the newest 3" {
  make_singlesite
  make_dump "$SNAPS/base.sql.gz"
  local i
  for i in 1 2 3 4 5; do make_dump "$SNAPS/_autosave-20200101-00000$i.sql.gz"; done
  run_snap -y restore base
  [ "$status" -eq 0 ]
  [ "$(ls "$SNAPS"/_autosave-*.sql.gz | wc -l)" -eq 3 ]
  [ -f "$SNAPS/_autosave-20200101-000005.sql.gz" ]
  [ -f "$SNAPS/_autosave-20200101-000004.sql.gz" ]
  [ ! -e "$SNAPS/_autosave-20200101-000003.sql.gz" ]
}

@test "restoring the oldest autosave works (prune runs after import)" {
  make_singlesite
  local i
  for i in 1 2 3 4; do make_dump "$SNAPS/_autosave-20200101-00000$i.sql.gz"; done
  run_snap -y restore _autosave-20200101-000001
  [ "$status" -eq 0 ]
  [[ "$output" == *"Done."* ]]
}

@test "corrupt dump aborts before touching the DB" {
  make_singlesite
  mkdir -p "$SNAPS"
  echo "not gzip" > "$SNAPS/bad.sql.gz"
  run_snap -y restore bad
  [ "$status" -eq 1 ]
  [[ "$output" == *"corrupt"* ]]
  refute_log "DROP DATABASE"
}

# ── refresh ─────────────────────────────────────────────────────────────

@test "refresh uses project dump without prompting and runs drush deploy" {
  make_singlesite
  make_dump "$PROJ/docker/database/prod.sql.gz"
  run_snap -y refresh
  [ "$status" -eq 0 ]
  grep -q "drush deploy -y" "$FAKE_LOG"
}

@test "refresh: deploy failure exits 2 (DB replaced, config drift)" {
  make_singlesite
  make_dump "$PROJ/docker/database/prod.sql.gz"
  export FAKE_DEPLOY_RC=1
  run_snap -y refresh
  [ "$status" -eq 2 ]
  [[ "$output" == *"drush deploy failed"* ]]
}

@test "refresh: no dump anywhere exits 1" {
  make_singlesite
  run_snap -y refresh
  [ "$status" -eq 1 ]
  [[ "$output" == *"no *.sql.gz found"* ]]
}

@test "refresh: ~/dumps fallback asks; 'n' leaves DB untouched" {
  make_singlesite
  make_dump "$HOME/dumps/other-project.sql.gz"
  run_snap_input n refresh
  [ "$status" -eq 1 ]
  [[ "$output" == *"fallback dir"* ]]
  [[ "$output" == *"DB untouched"* ]]
  refute_log "DROP DATABASE"
}

@test "refresh: ~/dumps fallback asks; 'y' imports" {
  make_singlesite
  make_dump "$HOME/dumps/other-project.sql.gz"
  run_snap_input y refresh
  [ "$status" -eq 0 ]
  grep -q "DROP DATABASE" "$FAKE_LOG"
}

@test "multisite refresh: docker/database/ is a fallback (may be another site)" {
  make_multisite
  make_dump "$PROJ/docker/database/whatever.sql.gz"
  run_snap_input n refresh site_a
  [ "$status" -eq 1 ]
  [[ "$output" == *"another site or project"* ]]
}

@test "multisite refresh: own databases/<db>/ dir needs no prompt" {
  make_multisite
  make_dump "$PROJ/docker/database/databases/db_site_a/prod.sql.gz"
  run_snap -y refresh site_a
  [ "$status" -eq 0 ]
  grep -q "drush -l site_a deploy -y" "$FAKE_LOG"
}

# Regression: `if ( refresh_one )` disabled set -e, so a failed import
# still ran deploy and was reported OK.
@test "refresh all: failed import stops that site, others continue" {
  make_multisite
  make_dump "$PROJ/docker/database/databases/db_site_a/prod.sql.gz"
  make_dump "$PROJ/docker/database/databases/db_site_b/prod.sql.gz"
  export FAKE_IMPORT_FAIL=db_site_a
  run_snap -y refresh all
  [ "$status" -eq 1 ]
  [[ "$output" == *"OK   (1): site_b"* ]]
  [[ "$output" == *"FAIL (1): site_a"* ]]
  refute_log "drush -l site_a deploy"
  grep -q "drush -l site_b deploy -y" "$FAKE_LOG"
}

@test "refresh all: deploy-only failures exit 2" {
  make_multisite
  make_dump "$PROJ/docker/database/databases/db_site_a/prod.sql.gz"
  make_dump "$PROJ/docker/database/databases/db_site_b/prod.sql.gz"
  export FAKE_DEPLOY_RC=1
  run_snap -y refresh all
  [ "$status" -eq 2 ]
}

# ── clear / delete ──────────────────────────────────────────────────────

@test "clear moves project dumps to ~/dumps/bin" {
  make_singlesite
  make_dump "$PROJ/docker/database/prod.sql.gz"
  run_snap_input y clear
  [ "$status" -eq 0 ]
  [ ! -e "$PROJ/docker/database/prod.sql.gz" ]
  [ -f "$HOME/dumps/bin/proj-x/prod.sql.gz" ]
}

@test "delete removes a single snapshot after confirmation" {
  make_singlesite
  make_dump "$SNAPS/a.sql.gz"
  make_dump "$SNAPS/b.sql.gz"
  run_snap_input y delete proj-x a
  [ "$status" -eq 0 ]
  [ ! -e "$SNAPS/a.sql.gz" ]
  [ -f "$SNAPS/b.sql.gz" ]
}

# ── confirmations (#6) ──────────────────────────────────────────────────

@test "restore asks first; 'n' leaves DB untouched" {
  make_singlesite
  make_dump "$SNAPS/base.sql.gz"
  run_snap_input n restore base
  [ "$status" -eq 1 ]
  [[ "$output" == *"Replace DB 'drupal' with snapshot 'base'?"* ]]
  [[ "$output" == *"DB untouched"* ]]
  refute_log "DROP DATABASE"
}

@test "restore with no stdin aborts cleanly (EOF = no)" {
  make_singlesite
  make_dump "$SNAPS/base.sql.gz"
  run_snap restore base
  [ "$status" -eq 1 ]
  [[ "$output" == *"Aborted"* ]]
  refute_log "DROP DATABASE"
}

@test "--yes works anywhere on the command line" {
  make_singlesite
  make_dump "$SNAPS/base.sql.gz"
  run_snap restore base --yes
  [ "$status" -eq 0 ]
  grep -q "DROP DATABASE" "$FAKE_LOG"
}

@test "--yes does NOT skip the fallback-dump question" {
  make_singlesite
  make_dump "$HOME/dumps/other-project.sql.gz"
  run_snap -y refresh
  [ "$status" -eq 1 ]
  [[ "$output" == *"fallback dir"* ]]
  refute_log "DROP DATABASE"
}

@test "refresh all asks once up front, then runs every site" {
  make_multisite
  make_dump "$PROJ/docker/database/databases/db_site_a/prod.sql.gz"
  make_dump "$PROJ/docker/database/databases/db_site_b/prod.sql.gz"
  run_snap_input y refresh all
  [ "$status" -eq 0 ]
  [ "$(grep -o 'Replace the DBs of all 2 sites' <<< "$output" | wc -l)" -eq 1 ]
  grep -q "drush -l site_a deploy -y" "$FAKE_LOG"
  grep -q "drush -l site_b deploy -y" "$FAKE_LOG"
}

@test "save asks before overwriting; -y overwrites" {
  make_singlesite
  run_snap save x
  run_snap save x
  [ "$status" -eq 1 ]
  [[ "$output" == *"exists. Overwrite?"* ]]
  run_snap -y save x
  [ "$status" -eq 0 ]
}

# ── truncated dumps (#12) ───────────────────────────────────────────────

@test "dump without mysqldump trailer warns and asks, even with -y" {
  make_singlesite
  mkdir -p "$SNAPS"
  echo "CREATE TABLE half" | gzip > "$SNAPS/trunc.sql.gz"
  run_snap -y restore trunc
  [ "$status" -eq 1 ]
  [[ "$output" == *"may be truncated"* ]]
  refute_log "DROP DATABASE"
  run_snap_input y -y restore trunc
  [ "$status" -eq 0 ]
  grep -q "DROP DATABASE" "$FAKE_LOG"
}

# ── site arg on single-site (#7) / no stray dirs (#9) ───────────────────

@test "single-site rejects a site arg (no path escape)" {
  make_singlesite
  run_snap save x ../../evil
  [ "$status" -eq 1 ]
  [[ "$output" == *"single-site project"* ]]
  [ ! -e "$HOME/.local/share/evil" ]
  [ ! -e "$HOME/.local/share/db-snapshots/evil" ]
}

@test "restore of a missing label creates no directories" {
  make_singlesite
  run_snap -y restore nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"snapshot not found"* ]]
  [ ! -d "$SNAPS" ]
}

# ── listing (#11) ───────────────────────────────────────────────────────

@test "list shows name, human size and ISO mtime" {
  make_singlesite
  make_dump "$SNAPS/a.sql.gz"
  touch -d "2026-03-04 05:06" "$SNAPS/a.sql.gz"
  run_snap ls
  [ "$status" -eq 0 ]
  [[ "$output" =~ a\.sql\.gz\ +[0-9.]+[KMG]?\ +2026-03-04\ 05:06 ]]
}

# ── clear (#10) ─────────────────────────────────────────────────────────

@test "clear never overwrites an earlier binned dump" {
  make_singlesite
  mkdir -p "$HOME/dumps/bin/proj-x"
  echo old > "$HOME/dumps/bin/proj-x/prod.sql.gz"
  make_dump "$PROJ/docker/database/prod.sql.gz"
  run_snap -y clear
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/dumps/bin/proj-x/prod.sql.gz")" = old ]
  [ -f "$HOME/dumps/bin/proj-x/prod.1.sql.gz" ]
}

@test "clear all: declining one site skips it, others continue" {
  make_multisite
  make_dump "$PROJ/docker/database/databases/db_site_a/a.sql.gz"
  make_dump "$PROJ/docker/database/databases/db_site_b/b.sql.gz"
  run_snap_input $'n\ny' clear all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped."* ]]
  [ -f "$PROJ/docker/database/databases/db_site_a/a.sql.gz" ]
  [ -f "$HOME/dumps/bin/proj-x/site_b/b.sql.gz" ]
}

@test "delete with no stdin keeps the snapshot" {
  make_singlesite
  make_dump "$SNAPS/a.sql.gz"
  run_snap delete proj-x a
  [ "$status" -eq 1 ]
  [ -f "$SNAPS/a.sql.gz" ]
}
