# Jira

Where a team runs Jira, it is the **company-facing state layer** above the
in-repo issue record and the PR (`development-workflows.md` → "Linking an
external tracker"). This document is the concrete worked example of that
section: substitute your own site and project key, or ignore the file
wholesale if your tracker is GitHub Issues, Linear, or nothing at all.

Site: **https://\<your-site\>.atlassian.net/**. Access is via the CLI so both
humans and agents use the same path.

## The path: Teamwork Graph CLI (`twg`)

`twg` is Atlassian's own CLI for the Teamwork Graph — Jira, Confluence,
Bitbucket, JSM, Assets, goals and people. It is the documented path here, for
three reasons worth keeping written down:

- **Browser OAuth, no plaintext token.** `twg login` opens a browser;
  credentials land in `~/.config/twg/auth.conf` at 600. `jira-cli` by contrast
  writes `api_token:` in cleartext (`secrets.md` → Tool identity).
- **It is a CLI *and* agent skills.** Something a human and a script can both
  run, not a server only an agent can reach. It installs skills for Claude,
  Codex, Cursor and others.
- **First-party.** No third-party process holds one of your credentials.

```bash
twg login                     # browser OAuth; select the site
twg auth refresh              # silent success = credentials are good
```

`TWG_SITE` can be emitted into every generated `.env.collection`, so a
collection targets your site rather than whichever one `auth.conf` happens to
list first — set `WTC_TWG_SITE` in `$WTC_CONFIG_ROOT/wtc.env`, then
`wtc env setup` (`secrets.md` → Tool identity). If you hold two
Atlassian **accounts** (not merely two sites), that is what `TWG_TOKEN` in
`.env.collection.local` is for; `TWG_USER` disambiguates the account and is
deliberately not generated, since a default would put a person's address in a
tracked file.

Skills are installed machine-globally by `twg skills install`. `twg skills
uninstall --agent <agent>` narrows that if the breadth is unwanted.

## Legacy: `jira-cli`

Older material still references it, and it still works. Prefer `twg` for new
work. If you do use it, run `jira init` **from inside a collection** so
`JIRA_CONFIG_FILE` is exported and the config lands in this workspace's own
store rather than the machine-global one — and note that it stores the API
token in cleartext, which is why that directory is 700.

## Usage

```bash
twg jira workitem get PROJ-123
twg jira workitem search "login failures" --limit 20
twg jira workitem query --jql "project = PROJ ORDER BY updated DESC"
twg jira workitem update --id PROJ-123 --status "In Progress"
twg jira workitem comment          # → twg help jira workitem comment
twg jira space get PROJ            # project/space metadata
```

`twg help jira workitem` (and the same for `sprint`, `board`, `space`) is the
authoritative surface — prefer reading it over guessing a flag. `--output json`
plus `--select` keeps a large result from filling an agent's context.

The jira-cli equivalents, for older material that still references them:

```bash
jira issue view PROJ-123 --comments 5
jira issue move PROJ-123 "In Progress"
jira issue comment add PROJ-123 "Shipped in api PR #41 (issue api-foh7)."
```

## Rules for agents

1. Jira is for **communication with the rest of the company** — update at
   meaningful transitions (started / blocked / shipped), never as a running
   log. Working detail stays in the in-repo issue record and the PR.
2. Keep the chain navigable: issue frontmatter carries `tracker: <KEY>`, PR
   titles/bodies mention the key, Jira comments reference the issue id and
   PR. Link, don't copy content between layers.
3. A wtc for Jira-tracked work starts with
   `wtc new --tracker <KEY> <slug> [repos…]`; create the linking
   in-repo issue when consuming the launch note.
4. Read freely; **write conservatively** — transitions and comments on
   issues you are actually working, nothing else, and no bulk operations.
   This governs every path equally: a `twg jira workitem update --status`, an
   MCP tool call and a `jira issue move` are the same act. `twg` additionally
   exposes bulk surfaces (`bulk-transition`, `create-bulk`, `archive --jql`)
   that jira-cli never had — those are exactly what "no bulk operations"
   means, and they need a human's say-so.
