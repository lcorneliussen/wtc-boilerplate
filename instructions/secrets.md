# Secrets and local config — control root

Machine-local secrets and per-repo local config live in a single **control
root** outside every repo and collection:

```text
~/.config/wtc/                 # $WTC_CONFIG_ROOT (this is the default)
  wtc.env                            # machine-wide tool defaults (not secrets)
  <repo-name>/<repo-relative-path>   # e.g. api/.env,
                                     #      console/.env.local
  certificates/                      # signing material not owned by any repo
```

`wtc.env` is the one place a **changed default** belongs, so that a bare
`tools/wtc-xyz.sh` keeps doing what this machine wants without flags repeated
in every command line. It is read by `wtc-open.sh` and `wtc-status.sh` on
every run, and by every tool that generates a collection's `.env.collection`;
CLI flags still win.

| Variable | Default | Effect |
|---|---|---|
| `WTC_AGENT_KIND` | `claude` | agent kind `wtc-open.sh` starts |
| `WTC_AGENT_ARGS` | — | args passed to the agent, replacing the built-in defaults |
| `WTC_LAYOUT` | `auto` | `wide` / `narrow` / `auto` — herdr workspace layout at create time |
| `WTC_LAYOUT_NARROW_AT` | `140` | session width (cols) below which `auto` picks narrow |
| `WTC_STATUS_REPOS` | `no` | `yes` → status shows only the collection table |
| `WTC_STATUS_WATCH` | `60` | redraw interval in seconds; `0` prints once |
| `WTC_STATUS_NO_CLICK` | `no` | `yes` → no mouse capture, no constant redraw |
| `WTC_TWG_SITE` | — | Atlassian site emitted as `TWG_SITE` into `.env.collection` (→ Tool identity) |

It holds defaults, not credentials — but it lives in the control root because
that is the machine-scoped, never-committed place that already exists.

A **shared control root**, not per-collection copies. Collections multiply
checkouts, and copies-per-collection means a rotated credential is stale in
every collection you did not think to update. One canonical copy per file,
**symlinked** into worktrees, is immediately current everywhere.

That holds for anything that rotates, and it leaves nowhere to put a
credential scoped to **one collection's work** — a throwaway sandbox key made
for a single investigation, say. Putting that in the control root hands it to
every collection on the machine. So there is a second, narrower tier
alongside it (see "Collection-scoped secrets"). The rule of thumb: **rotates
for the machine → control root; belongs to this piece of work →
collection-scoped.**

`WTC_CONFIG_ROOT` is exported in every collection's `.env.collection`
(default `~/.config/wtc`). Files are stored at their repo-relative
path, so linking is mechanical.

## Wiring a worktree

`tools/link-secrets.sh` does it, for every checked-out repo in a collection:

```sh
tools/link-secrets.sh                 # this harness worktree's collection
tools/link-secrets.sh --collection ../billing --dry-run
tools/link-secrets.sh --repo api     # what init hooks pass
```

Because files are stored at their repo-relative path, the tool needs no
manifest — it walks `<control-root>/<repo>/` and mirrors each file into the
matching worktree. It is idempotent, and re-running is the point: it is what
init hooks call at creation time (`hooks-and-env.md`) and what catch-up calls
to pick up files added since (`AGENTS.md` → Catch-up rules).

What it will not do:

- **Link a target that is not gitignored.** It refuses and exits nonzero. Add
  the ignore rule in the repo first — never after the fact, when the secret
  has already been one `git add -A` away from a commit.
- **Link prod-capable paths** (rule 3 below) without `--include-prod`.
- **Destroy a hand-made copy.** An existing regular file is moved to the
  collection's `.harness-backups/` first — outside every worktree, since a
  backup beside the original would not match the ignore rule covering it.

Doing it by hand is `ln -sfn <control-root>/<repo>/<path> <worktree>/<path>`
(`-sfn`, not `-sf`: if the target is ever a directory, `-sf` drops the link
*inside* it). Verify with `git status` afterwards either way — a linked
secret that shows up as untracked means the ignore rule is missing.

## Collection-scoped secrets

```text
<collection>/.env.collection.local     # 600, seeded empty once, then hand-authored
```

Created empty by `write_collection_env` and **never rewritten**, unlike its
neighbour `.env.collection`, which is regenerated wholesale on every
`branch-off` — anything hand-added *there* is lost (and that file is not
chmod'd; its mode follows the caller's umask). The collection root is not a
git repo, so `.env.collection.local` cannot be committed by accident.
`retire.sh` deletes it with the collection — secrets scoped to this wtc die
with it.

`mise.toml` lists it second, so it composes with (and wins over) the generated
env:

```toml
[env]
_.file = [".env.collection", ".env.collection.local"]
```

Without mise (including `tools/wtc-open.sh`, which injects both into herdr):
`set -a; . ./.env.collection; . ./.env.collection.local; set +a`.

Two limits worth knowing before reaching for it:

- **It is collection-scoped, not repo-scoped.** Every repo in the collection
  inherits the variables, unlike the control root, which is stored per repo.
- **It holds variables, not files.** A per-collection secret *file* — a
  certificate, or a config the app reads directly — has no tier yet; the shape
  would be a `collections/<name>/<repo>/<path>` overlay that
  `link-secrets.sh` walks after the shared tier. Deliberately unbuilt until
  something needs it, because a whole-file override forces the collection copy
  to duplicate everything else in that file — the rotation problem the shared
  tier exists to avoid.

Rotating a collection-scoped secret is by hand, in that one file. That is the
trade: no shared copy to keep current, and no shared blast radius either.
## Tool identity — scoping a globally-resolved CLI (optional)

Rule 4 below says a credential the tool resolves globally belongs in that
tool's global config. That is right about *not per worktree*, and it stops one
step short of the whole story.

`gh` resolves auth from one store (`~/.config/gh/hosts.yml` plus the keychain)
and `jira-cli` from `~/.config/.jira/.config.yml`. Both are machine-wide, so
**every project on this machine shares whichever account is logged in** — a
collection here can reach repositories and issues belonging to unrelated work,
and that unrelated project can reach this workspace's.

**Whether that matters is a judgement about your machine, not a defect to
fix.** If this workspace is the only thing you use those CLIs for — one
employer, one org, one Atlassian account — the machine-global store is the
right answer and this whole section is skippable. It earns its cost the moment
a second, unrelated project shares the machine.

Where it does matter, both CLIs can be pointed at a different config
location, so the fix is to give this workspace its own store. `twg` needs a
different lever:

```sh
GH_CONFIG_DIR=$WTC_CONFIG_ROOT/gh
JIRA_CONFIG_FILE=$WTC_CONFIG_ROOT/jira/.config.yml
TWG_SITE=<your-site>.atlassian.net
```

| Tool | Lever | Credential at rest |
|---|---|---|
| `gh` | `GH_CONFIG_DIR` — whole config dir | **keychain**; `hosts.yml` names the accounts |
| `twg` | `TWG_SITE` pins the site; `TWG_TOKEN` for a different *account* | OAuth tokens in `~/.config/twg/auth.conf`, 600 |
| `jira-cli` | `JIRA_CONFIG_FILE` — the config file | **plaintext `api_token:`** in that file, 600 |

`twg`'s config dir does move with `XDG_CONFIG_HOME` (relocating it makes `twg
auth refresh` answer "No TWG credentials are configured"). Do not use that as
the lever — it relocates config for every XDG-respecting tool in the
collection, `git` and `nvim` among them. `TWG_SITE` is narrow and is what twg
documents for the purpose.

### Opt-in by presence

`write_collection_env` emits each variable **only when the store it names
already exists**, so a workspace that never opts in keeps the machine default
and nothing changes:

| Variable | Emitted when |
|---|---|
| `GH_CONFIG_DIR` | `$WTC_CONFIG_ROOT/gh/` is a directory |
| `JIRA_CONFIG_FILE` | `$WTC_CONFIG_ROOT/jira/` is a directory |
| `TWG_SITE` | `WTC_TWG_SITE` is set — in `wtc.env`, or in the generating environment |

That condition is deliberate. Emitting `GH_CONFIG_DIR` unconditionally would
point `gh` at an empty directory and log you out inside every collection
before you had asked for anything; making the directory *be* the opt-in cannot
do that. Turning it on:

```sh
cd <collection>                        # collection root, where .env.collection lives
mkdir -p "$WTC_CONFIG_ROOT"/gh         # creating the store IS the opt-in
harness/tools/refresh-env.sh           # regenerate — GH_CONFIG_DIR now appears
```

Then re-enter the collection (or reopen the herdr workspace) so the new
variable is actually exported — see the table below for why that step is not
optional:

```sh
echo "$GH_CONFIG_DIR"                  # non-empty = it reached this shell
gh auth login                          # populates the scoped store
gh auth status                         # confirm the identity
```

Turning it back off is `rm -rf "$WTC_CONFIG_ROOT"/gh` (the keychain entry
survives) followed by `refresh-env.sh`.

`twg` has no store to create — its lever is a site name rather than a config
location, so setting it once in the control root is the opt-in:

```sh
echo 'WTC_TWG_SITE=<your-site>.atlassian.net' >> "$WTC_CONFIG_ROOT"/wtc.env
harness/tools/refresh-env.sh --all     # TWG_SITE now appears in every collection
```

### Where the variables actually reach

Not "everywhere", and the difference bites:

| Context | Gets it? | How |
|---|---|---|
| herdr panes | yes | `wtc-open.sh` injects every line as `--env` **at workspace creation** |
| `mise run` / `mise exec` | yes | `mise.toml` lists `.env.collection` in `[env] _.file` |
| A plain shell in a collection | **only with `mise activate`** in your shell rc | otherwise `cd` alone exports nothing |
| A collection created before the variable existed | **no, until refreshed** | `tools/refresh-env.sh` |

- **An already-open herdr pane keeps the environment it started with.**
  `wtc-open.sh` skips the env block when it reuses an existing workspace, so
  re-running it refreshes nothing. Close and reopen the workspace.
- **Existing collections stay stale until refreshed.** Only `branch-off` (new
  collection) and `add-repo` (when the file is missing) generate this file, so
  `tools/refresh-env.sh` is what carries a generator change to collections that
  already exist. Catch-up runs it.

Check where you actually stand with `echo "$GH_CONFIG_DIR"` — empty means
either you have not opted in or one of the rows above is not satisfied, and
`gh` is still on the machine-global store.

### Two properties worth being explicit about

- **No token is added by this mechanism.** These variables name a config
  *directory, file or site* — never a credential. Each tool keeps its own store
  and is only told which one, which is why this is not a secrets tier and does
  not live in `.env.collection.local`.

  That is a statement about the *variables*, not about the stores they point
  at, and the two are easy to conflate. `gh` keeps its token in the keychain
  and `twg` holds OAuth tokens under 600; **`jira-cli` writes `api_token:` in
  cleartext** into the file `JIRA_CONFIG_FILE` names. Scoping it stops that
  token being shared with unrelated projects; it does not stop it being
  plaintext on disk. So create that one restricted and keep it that way —
  `mkdir -m 700 -p "$WTC_CONFIG_ROOT"/jira`. Nothing in the tools enforces
  the mode; the directory is the opt-in, and how you create it is the only
  moment you get to set it.
- **It is opt-out by absence, not by default.** A shell outside any collection
  has neither variable set and falls back to the machine-global store — which
  is the correct behaviour for a project that is not this one.

Other projects with other accounts point their own env elsewhere, or set
nothing and keep the machine default.

MCP servers want the same treatment through a different mechanism — a server
registry naming variables that the collection env supplies, so a server's
identity is per collection too.

## Rules

1. **Nothing from the control root is ever committed** — to any repo,
   including this one. The control root itself is not a git repo.
2. Secrets originate in a password manager (or the issuing service); the control
   root is the machine-local materialization. When rotating: update
   the password manager, then the control-root file.
3. Prod-capable material (e.g. deploy env files, signing certificates)
   stays out of worktrees entirely unless the task explicitly needs it —
   link it manually for that task and remove the link afterwards.
4. Per-user credentials that tools resolve globally belong in the tool's
   own global config, not per worktree — a package-registry token in the
   build tool's user-level config, a tracker token in that CLI's own config.
   Linking those per worktree multiplies the copies without making any of
   them easier to rotate. Where the tool can be pointed at a different config
   location and the machine carries unrelated projects, scope that global
   config to this workspace rather than sharing the machine's — see "Tool
   identity" above.

## Inventory

Keep a table here of what actually exists in your control root, so the set is
reviewable without listing a directory full of credentials. The shape:

| Path under control root | Used by |
|---|---|
| `api/.env` | Local-dev auth + database connection |
| `console/.env.local` | Identity provider client + API URL selection |
| `web/.env` | App auth token + API base |
| `worker/.env.prod` | Deploy env — **prod-capable, rule 3 applies** |
| `certificates/<year>/` | Signing certs + provisioning profiles |

Two things earn their place in that table beyond the path: who consumes the
file, and whether it is prod-capable. The second is what rule 3 keys off, and
what `tools/link-secrets.sh` refuses to link without an explicit flag.
