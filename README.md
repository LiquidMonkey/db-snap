# db-snap

Save, restore, and refresh labeled MariaDB snapshots for local Wodby-based Drupal stacks (single-site or multisite).

## Requirements

- Bash 4+ (for `[[ ]]`, arrays, `mapfile`-style globs)
- Docker + `docker compose` (the script uses `docker compose exec mariadb …`)
- A Wodby-style Drupal project: `.env` and `docker-compose.yml` (or `compose.yml`) at the project root
- `drush` available inside the `php` container (multisite DB-name resolution and `cim` rely on it)
- Zsh + oh-my-zsh, only if you want tab completion

## Install

The tool is two files. Both live under your home directory.

### 1. The script

```bash
install -m 0755 db-snap ~/.local/bin/db-snap
```

Make sure `~/.local/bin` is on your `$PATH`. If it isn't, add to `~/.zshrc` (or `~/.bashrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Verify:

```bash
db-snap info
```

You should see the script path, snapshot base, and either the current project info (if you're inside one) or `(not in a project — cwd: …)`.

### 2. The zsh completion (optional)

```bash
mkdir -p ~/.oh-my-zsh/custom/completions
install -m 0644 _db-snap ~/.oh-my-zsh/custom/completions/_db-snap
```

That directory is already on oh-my-zsh's `$fpath`, so no `.zshrc` edit is needed. Reload the completion cache:

```bash
rm -f ~/.zcompdump* && exec zsh
```

Verify:

```bash
db-snap <Tab>
```

You should see the subcommand list with descriptions.

#### Plain zsh (no oh-my-zsh)

Pick any directory on `$fpath` (create one if needed):

```bash
mkdir -p ~/.zsh/completions
install -m 0644 _db-snap ~/.zsh/completions/_db-snap
```

Add to `~/.zshrc` before `compinit`:

```zsh
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

Then `rm -f ~/.zcompdump* && exec zsh`.

## First use

Inside a project root:

```bash
db-snap save before-experiment            # single-site
db-snap save before-experiment vw_base    # multisite — pick a site key
db-snap list                              # see what's stored
db-snap restore before-experiment vw_base
```

Cross-project listing (works from anywhere):

```bash
db-snap ls all
```

Run `db-snap` with no arguments for the full usage block.

### Prompts and `--yes`

Destructive commands (restore, refresh, overwrite on save, delete, clear) ask before acting. Add `-y` / `--yes` anywhere on the line, or set `DB_SNAP_YES=1`, to skip those. Two warnings always ask regardless, because they mean the data itself may be wrong:

- **fallback dump** — `refresh` found no dump for this site and would use one from `~/dumps/` (or `docker/database/` on multisite)
- **truncated dump** — the file has no `-- Dump completed` trailer

Without a terminal (piped / closed stdin), every prompt answers "no".

## Snapshot store

```
~/.local/share/db-snapshots/
└── <project-name>/
    ├── <label>.sql.gz                    # single-site dumps
    └── <site>/
        └── <label>.sql.gz                # multisite dumps
```

`<project-name>` is the basename of the project root (the dir that contains `.env`).

### Autosaves

`restore` and `refresh` dump the current DB to `_autosave-<timestamp>.sql.gz` before dropping it (skipped when the DB is empty). The newest 3 per site are kept. Undo a bad restore/refresh with:

```bash
db-snap restore _autosave-20261123-141500 [site]
```

Env: `DB_SNAP_NO_AUTOSAVE=1` skips it (faster), `DB_SNAP_AUTOSAVE_KEEP=N` changes retention.

## Configuration

db-snap reads two optional config files and merges them. Global settings apply everywhere; project settings add to or refine them per project.

### Global config: `~/.config/db-snap/config`

Applies to every project. Follows the XDG Base Directory spec — if `$XDG_CONFIG_HOME` is set, the file is read from there instead.

```bash
mkdir -p ~/.config/db-snap
# ~/.config/db-snap/config
IGNORE_SITES=styleguide assets
```

### Project config: `<project-root>/.db-snap`

Applies only to the current project. Commit it alongside the project or add it to `.gitignore`, depending on whether the setting is team-wide or personal.

```bash
# <project-root>/.db-snap
IGNORE_SITES=shared legacy
```

### `IGNORE_SITES`

Directories under `web/sites/` that aren't actual Drupal websites — styleguides, shared asset dirs, etc. Listed dirs are excluded from all site-aware commands: `list`, `refresh all`, `clear all`, and site validation.

Both config files are merged: global entries plus project entries are all excluded. Run `db-snap info` inside a project to see which entries came from each layer.

## Uninstall

```bash
rm -f ~/.local/bin/db-snap
rm -f ~/.oh-my-zsh/custom/completions/_db-snap
rm -rf ~/.local/share/db-snapshots         # only if you also want the saved dumps gone
rm -f ~/.zcompdump*
```

## Development

The repo lives at `~/.local/share/db-snap/`; the installed script and completion are symlinks into it:

```bash
git clone --recurse-submodules git@github.com:LiquidMonkey/db-snap.git ~/.local/share/db-snap
ln -s ~/.local/share/db-snap/db-snap  ~/.local/bin/db-snap
ln -s ~/.local/share/db-snap/_db-snap ~/.oh-my-zsh/custom/completions/_db-snap
```

Run the tests (bats-core is vendored as a submodule; the suite uses a fake `docker`, so no stack or DB is needed):

```bash
test/bats/bin/bats test/
shellcheck -S warning db-snap test/fixtures/bin/docker
```
