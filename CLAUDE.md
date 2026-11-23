# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`db-snap` is a single-file Bash CLI for managing Drupal MariaDB snapshots on a local Wodby docker stack (single-site or multisite). It wraps `docker compose exec mariadb mysqldump|mysql` and `drush` to: save labeled dumps, restore them, and rebuild a site DB from the newest project dump (with `drush cim`).

It is a personal tool, not a packaged project — there is no test suite, lockfile, or CI.

Git repo: `~/.local/share/db-snap/` → `https://github.com/LiquidMonkey/db-snap`. The installed paths are **symlinks** into the repo, so edits in the repo are live immediately — edit the repo files, not the symlinks' targets elsewhere.

## File map

| File | Purpose |
|------|---------|
| `~/.local/share/db-snap/db-snap` | The script. The only source of truth for behavior. Symlinked from `~/.local/bin/db-snap`. |
| `~/.local/share/db-snap/_db-snap` | Zsh completion. Mirrors the dispatcher; must be updated when the command surface changes. Symlinked from `~/.oh-my-zsh/custom/completions/_db-snap`. |
| `~/.local/share/db-snapshots/<project>/[<site>/]<label>.sql.gz` | Snapshot store (not in the repo). Layout differs single-site vs multisite (see Invariants). |
| `~/.local/share/db-snap/CLAUDE.md` | This file. |
| `~/.local/share/db-snap/README.md` | User-facing install guide and config reference. |

## Command surface

```
db-snap save|snap   <label> [site]              Dump current DB to a snapshot
db-snap restore     <label> [site]              Restore a saved snapshot
db-snap refresh                [site|all]       Replace live DB with newest project dump + drush deploy (all = every subsite)
db-snap list|ls                [site|all]       List snapshots; `all` = every project
db-snap info                                    Show install + snapshot paths
db-snap delete|rm   <project> [site] [label]    Delete a project, site, or snapshot
db-snap clear       [site|all] [--rm]            Move project dump files (docker/database/) to ~/dumps/bin/; --rm to delete
```

Aliases live in the dispatcher (`case "${1:-}" in save|snap) ...`). When adding a new alias, also add it to `_db-snap` and the help header.

Hidden commands (not in help): `__sites` and `__labels` — plain one-per-line output for the zsh completion. Empty output + exit 0 when not applicable (e.g. outside a project).

## File layout

`db-snap` is one file, split by banner comments: **Bootstrap** (project root, `.env`, config layers) → **Helpers** (validators, site/DB resolution, `dump_db`, autosave, `import_gz`) → **Commands** (`cmd_*` + per-site workers) → **Completion helpers** → **Dispatcher**. Put new code in the matching section. Staying single-file is deliberate (simple install); revisit only past ~1500 lines or if structured data (metadata, JSON) appears — then Python stdlib, not split bash.

## Invariants — do not break

These cut across the script and are easy to violate during edits:

- **Project-root detection runs at script load** (`find_project_root` walks up looking for `.env` + `docker-compose.yml`/`compose.yml`). If absent, `PROJECT_ROOT` stays empty and `.env` is **not** sourced. Only `info` and `list`/`ls` (with no site arg, or with `all`) work in that state — every other subcommand goes through `require_project`.
- **Multisite detection** is "anything in `web/sites/` that isn't `default`/`simpletest`/`all`/`files`". The literal name `all` is therefore reserved as the magic keyword for `list all`, `refresh all`, and `clear all` — keep it in the exclusion list in `list_subsites` if you ever change the filter.
- **Two-layer config** — global (`~/.config/db-snap/config`, respects `$XDG_CONFIG_HOME`) parsed unconditionally at startup; project (`<project-root>/.db-snap`) parsed inside the `PROJECT_ROOT` block. Both populate separate arrays (`GLOBAL_IGNORE_ARR`, `PROJECT_IGNORE_ARR`) that are merged into `IGNORE_SITES_ARR` after both blocks run. Neither file is sourced — only the `IGNORE_SITES=` line is extracted with `grep`+`cut`. `cmd_info` shows each layer separately so the user can see what came from where. `list_subsites` only reads `IGNORE_SITES_ARR` (the merged result).
- **`clear` targets project dump files**, not snapshots. It looks in `docker/database/databases/<db_name>/` and `docker/database/` (the same candidates as `refresh`, minus `~/dumps/` which is shared/fallback and not project-owned). By default moves to `~/dumps/bin/<project>[/<site>]/`; `--rm` deletes immediately. `~/dumps/bin/` is safe as a holding area because `refresh` uses `maxdepth 1` on `~/dumps/` and won't look inside `bin/`. `cmd_info` shows the bin path. No purge-bin subcommand — user does `rm -rf ~/dumps/bin` manually.
- **DB name resolution differs by site mode**: single-site reads `DB_NAME` from `.env`; multisite calls `drush -l <site> status --format=json` and greps `db-name`. Don't unify these — multisite projects don't expose a single DB_NAME.
- **Two validators, both required at every external-input boundary**:
  - `validate_db_name` — only `[A-Za-z0-9_]` — defends `DROP/CREATE/GRANT` SQL interpolation (db name lands in backticks).
  - `validate_label` — `[A-Za-z0-9._-]`, no leading dot or dash, no `..` — defends path-traversal into the snapshot dir and option injection into `ls`/`rm`. Used for snapshot labels, project names, and site names in `delete`.
- **`set -euo pipefail` is on**. `local foo; foo="$(...)"` is the idiom for capturing command output without losing the failure signal — don't collapse to `local foo="$(...)"` (that masks the exit code).
- **Fresh-dump search order** in `cmd_refresh` is: `docker/database/databases/<db_name>/`, then `docker/database/`, then `~/dumps/`. The first directory with any `*.sql.gz` wins (newest mtime within it). Don't reorder without updating the help block at the top of the script.
- **`refresh` runs `drush deploy`** (updb + cim + cr + deploy hooks), not bare `cim` — prod dumps are usually behind the code's update hooks.
- **`deploy` failure on `refresh` is exit code 2**, not 1. The DB was already replaced — the non-zero exit is to flag "config drift" specifically. Preserve this distinction if you touch the error path. The per-site work lives in `refresh_one` (returns 0/1/2); `cmd_refresh` is a thin dispatcher and `cmd_refresh_all` loops it. `refresh all` runs each site as a **separate process** (`bash "$0" refresh "$site"`), then exits with the worst code (1 beats 2). Never go back to `if ( refresh_one ); then` — bash disables `set -e` inside an `if` condition (subshells included), so mid-import failures would be silently ignored.
- **Fallback dumps need confirmation**: `~/dumps/` (any project) and, on multisite, `docker/database/` (any site) prompt before import. Only the site's own dir is trusted silently.
- **Autosave before every drop**: `import_gz` dumps the live DB to `_autosave-<YYYYmmdd-HHMMSS>.sql.gz` (via `dump_db`) before `DROP DATABASE`, skipping empty/missing DBs. `prune_autosaves` keeps the newest `$AUTOSAVE_KEEP` (default 3) and runs **after** a successful import — the file being restored may itself be an old autosave. Env: `DB_SNAP_NO_AUTOSAVE=1`, `DB_SNAP_AUTOSAVE_KEEP=N`.
- **Completion asks the script**: `_db-snap` gets sites/labels from `db-snap __sites` / `__labels`. Never reimplement project-root or site detection in zsh — the old copy drifted and ignored `IGNORE_SITES`.
- **Multisite site-resolution guard**: `resolve_db_name` checks drush's `"site"` field equals `sites/<site>`. drush silently falls back to `sites/default` for unresolvable `-l` values — without the guard, a typo would drop the default site's DB.
- **Snapshot store layout depends on whether a `site` was passed at save time**, not on whether the project is multisite. A snapshot saved without a site lands at `<base>/<project>/<label>.sql.gz`; with a site at `<base>/<project>/<site>/<label>.sql.gz`. `cmd_list_all` and `cmd_delete` both walk the two cases — keep them in sync.

## Adding a subcommand

Five places to touch, in order:

1. **`cmd_<name>` function** — the implementation. Use existing helpers (`require_site`, `resolve_db_name`, `snapshot_path`, `validate_label`, `print_snapshots`).
2. **Dispatcher** at the bottom — add `name|alias) require_project; shift; cmd_name "$@" ;;`. Drop `require_project` only if the command genuinely works outside a project (currently only `info` and `list`/`ls`).
3. **Header usage block** at the top of the script — keep alignment consistent with the existing rows. The fallback case prints every `#` line from line 2 until the first non-comment line, so the header can grow freely — just keep it one contiguous comment block.
4. **Zsh completion** in `~/.oh-my-zsh/custom/completions/_db-snap` — add to the `subcommands` array (with a description) and add a per-command branch in the `case $words[1]` block. Reuse the existing helpers (`_db_snap_sites`, `_db_snap_labels`, `_db_snap_projects`, etc.) where possible. Verify with `zsh -n` after editing.
5. **bats test(s)** in `test/db-snap.bats` covering the new command's happy path and its guard/error paths. Extend `test/fixtures/bin/docker` if the command makes a new kind of docker call (unknown calls exit 99 on purpose).
6. **Reload completion** (only when testing): `rm -f ~/.zcompdump* && exec zsh`.

## Style preferences (user-specific)

- **CAVEMAN mode**: this user runs Claude Code in caveman mode. Keep Bash output messages terse — fragments OK, drop articles ("Dumping 'foo' → bar" not "Now dumping the database 'foo' to bar"). Code blocks themselves stay normal Bash.
- **Guard-first** (per `~/.claude/CLAUDE.md`): early-return / continue / exit at the top, happy path unindented. The recent simplification of `cmd_delete` hoisted all `validate_label` calls to the top for this reason — don't push them back into nested branches.
- **No drive-by refactors**. Existing code reflects deliberate balance (e.g., `cmd_list` and `cmd_list_all` share `print_snapshots` but otherwise stay separate because they have different headers/indents). Resist "unifying" them.

## Verifying changes

After any edit, from the repo root:

1. `test/bats/bin/bats test/` — full suite. Runs against a fake `docker` (`test/fixtures/bin/docker`) with an isolated `$HOME` per test, so it never touches real DBs or snapshots.
2. `shellcheck -S warning db-snap test/fixtures/bin/docker`
3. `zsh -n _db-snap`
4. Only for changes to real docker/mysql interaction: `db-snap save test_$$` + `db-snap restore test_$$` in a real project with a recoverable DB.

Test gotcha: in bats, a bare `! cmd` line does **not** fail the test (unless it's the last line). Use `refute_log` from `test/test_helper.bash`, or `[ -z "$(...)" ]`.

bats-core is a git submodule pinned at `v1.11.1` (`test/bats`). Fresh clone: `git clone --recurse-submodules`, or `git submodule update --init`.
