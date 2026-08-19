# Lemmy Migrator

A shell script for migrating subscribed communities between [Lemmy](https://join-lemmy.org) instances — no Python, no Node.js, no dependencies beyond `curl` and `jq`.

See [CHANGELOG.md](CHANGELOG.md) for release notes.

This script was initially created for my own purpose and is in no way officially connected to [Lemmy](https://join-lemmy.org), the Lemmy developers or the operators of any instance. Use this script at your own risk!

## Features

- Exports all subscribed communities with their canonical ActivityPub IDs
- Resolves remote communities on the target instance and subscribes to them
- Supports Lemmy 0.19 (API v3) and Lemmy 1.x (API v4), including migrations between versions
- Resume support: interrupted imports pick up where they left off
- Dry-run mode to verify community availability without changing subscriptions
- Works with password login or an existing Bearer token
- Retries rate-limited and transient requests with exponential backoff
- Asks for confirmation before making changes on the target instance

## Requirements

- `curl` (available on virtually all Unix systems)
- `jq` (JSON processor)

```bash
# Debian / Ubuntu
sudo apt install curl jq

# macOS
brew install jq
```

## Quick Start

```bash
chmod +x lemmy-migrator.sh

# 1. Export from source instance
./lemmy-migrator.sh export \
  --source https://source-instance.example \
  --user myuser \
  --password 'SOURCE_PASSWORD'

# 2. Check what can be resolved on the target instance
./lemmy-migrator.sh import \
  --target https://new-instance.example \
  --user myuser \
  --password 'TARGET_PASSWORD' \
  --dry-run

# 3. Import subscriptions
./lemmy-migrator.sh import \
  --target https://new-instance.example \
  --user myuser \
  --password 'TARGET_PASSWORD'
```

## Authentication

The script supports username/password login and existing Lemmy JWT/Bearer tokens. Environment variables are recommended because command-line arguments may be stored in your shell history or briefly appear in the process list:

```bash
SOURCE_PASSWORD='...' ./lemmy-migrator.sh export \
  --source https://source-instance.example --user myuser

TARGET_TOKEN='eyJ...' ./lemmy-migrator.sh import \
  --target https://new-instance.example --yes
```

Supported variables are `SOURCE_PASSWORD`, `SOURCE_TOKEN`, `TARGET_PASSWORD` and `TARGET_TOKEN`.

If two-factor authentication is enabled, use a token from an already authenticated Lemmy session. The script never writes passwords or tokens to the export.

## Subcommands

### `export`

Exports all subscribed communities from the source account:

```bash
./lemmy-migrator.sh export \
  --source https://source-instance.example \
  --user USERNAME \
  --token 'eyJ...'
```

| Option | Description |
|---|---|
| `--source URL` | Source instance URL |
| `--user NAME` | Username or email on the source instance |
| `--token TOKEN` | Existing Bearer token |
| `--password PASS` | Account password |
| `--export-dir PATH` | Custom export directory |
| `--debug` | Verbose curl output |

The export is saved to `./lemmy_export/communities.json`. Each entry contains the community name, title, canonical ActivityPub ID and basic metadata. Credentials are never included.

### `import`

Resolves every exported community on the target instance and subscribes to it:

```bash
./lemmy-migrator.sh import \
  --target https://new-instance.example \
  --user USERNAME \
  --token 'eyJ...'
```

| Option | Description |
|---|---|
| `--target URL` | Target instance URL |
| `--user NAME` | Username or email on the target instance |
| `--token TOKEN` | Existing Bearer token |
| `--password PASS` | Account password |
| `--dry-run` | Resolve communities without subscribing |
| `--yes` | Skip the interactive confirmation |
| `--export-dir PATH` | Custom export directory |
| `--debug` | Verbose curl output |

Use `--dry-run` first if you want to see which communities are reachable from the target instance. A community may fail to resolve if its home instance is offline or blocked by the target instance.

### `full`

Runs export and import in a single step:

```bash
./lemmy-migrator.sh full \
  --source https://source-instance.example \
  --source-user SOURCE_USER \
  --source-password 'SOURCE_PASSWORD' \
  --target https://new-instance.example \
  --target-user TARGET_USER \
  --target-password 'TARGET_PASSWORD'
```

Token variants are available as `--source-token` and `--target-token`; usernames are not required when tokens are used for both instances.

## Resume After Interruption

Every successfully subscribed community is tracked in a target-specific file below `lemmy_export/.imported_communities/`. If the import is interrupted, simply re-run the same command against the same target. Already imported communities are automatically skipped, while an import to a different target starts with its own state.

```text
[1/42] Resolving !technology@lemmy.world ... ✓ subscribed
[2/42] ↩ Skipped (already imported): !linux@lemmy.ml
[3/42] Resolving !example@offline.example ... ✗ not found
```

To deliberately start over, remove the resume file for that target. Following a community more than once does not create duplicate subscriptions, but the additional requests may trigger rate limits. Resume files from versions before v0.1 are intentionally ignored because they were not associated with a target instance.

## Customisation

Use a custom export directory, increase the delay between API calls, or tune transient-request retries:

```bash
EXPORT_DIR=/path/to/lemmy_export REQUEST_DELAY=1 \
  ./lemmy-migrator.sh import --target https://new-instance.example --token 'eyJ...'

MAX_RETRIES=5 RETRY_BASE_DELAY=2 \
  ./lemmy-migrator.sh import --target https://new-instance.example --token 'eyJ...'
```

`MAX_RETRIES` is the number of retries after the initial request (default: `3`). `RETRY_BASE_DELAY` controls the initial exponential-backoff delay in seconds (default: `1`). A numeric `Retry-After` header takes precedence for HTTP 429 responses.

## Known Limitations

- The target instance must be able and allowed to federate with each community's home instance.
- A remote instance that is offline can prevent a community from being resolved during import. Re-running the import later will retry failed entries.
- Pending subscriptions to private or manually approving communities may still require approval by their moderators.
- Two-factor login is not performed by the script; use an existing token instead.

## Tests

Run the dependency-free regression suite with:

```bash
./tests/test.sh
```

## License

MIT — see [LICENSE](LICENSE).

## Star History

<a href="https://www.star-history.com/?repos=netherwraith%2Flemmy-migrator&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=netherwraith/lemmy-migrator&type=date&theme=dark&legend=top-left&sealed_token=T2mPhaoZX87JWLjInLqqe2X45TIu3sqMx-SsycBNgUoFMz_KzRwIyBh7jbVqNWefpD2Pat2FkDchpYOuBQuOfPVaFF912KGrWyRfn7o4mdQTgH7dEwrcJgqef1gMUJ3Gu_kZG2xIIxkkBigkxtMETfgFELg446H65BO4LyD8g8WVEygrXFGYXgBlcGfp" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=netherwraith/lemmy-migrator&type=date&legend=top-left&sealed_token=T2mPhaoZX87JWLjInLqqe2X45TIu3sqMx-SsycBNgUoFMz_KzRwIyBh7jbVqNWefpD2Pat2FkDchpYOuBQuOfPVaFF912KGrWyRfn7o4mdQTgH7dEwrcJgqef1gMUJ3Gu_kZG2xIIxkkBigkxtMETfgFELg446H65BO4LyD8g8WVEygrXFGYXgBlcGfp" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=netherwraith/lemmy-migrator&type=date&legend=top-left&sealed_token=T2mPhaoZX87JWLjInLqqe2X45TIu3sqMx-SsycBNgUoFMz_KzRwIyBh7jbVqNWefpD2Pat2FkDchpYOuBQuOfPVaFF912KGrWyRfn7o4mdQTgH7dEwrcJgqef1gMUJ3Gu_kZG2xIIxkkBigkxtMETfgFELg446H65BO4LyD8g8WVEygrXFGYXgBlcGfp" />
 </picture>
</a>
