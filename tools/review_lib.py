#!/usr/bin/env python3
"""review_lib.py — small helpers for the review-* tools (stdlib only).

Subcommands (all print to stdout; non-zero exit = failure):
  frontmatter <file> <key>                one frontmatter value (comment stripped)
  concerns <outdir> <changed-files> <layer-dir>...
                                          resolve layers (later wins by id),
                                          filter by `applies`, copy to outdir,
                                          print "<id>\\t<tier>\\t<needs>" per kept concern
  pr-info <pr.json> <body-out>            shell assignments from a bb/gh PR JSON
  comments <comments.json> [--after-review]
                                          PR comments as markdown (only those after
                                          the newest review comment with the flag)
  merge-comments <conversation.json> <inline-pages.json> <out.json>
                                          combine GitHub conversation and inline comments
  inline-keys <comments.json>             all previously posted inline finding keys
  latest-status <comments.json>           newest status line: "<head> <verdict> <blockers> <round> <url> <id>"
  status-line <summary.md>                one review status line's head and verdict
  validate-findings <file> <concern-id>   exit 0 when the findings JSON is valid
  blockers <findings-dir>                 count open blocker findings (prior != addressed)
  verdict <file>                          print the verdict word, or exit 1
  render <template> KEY=VALUE...          substitute {{KEY}} placeholders
  stub-json <concern-id> <status> <notes> print a findings JSON with no findings
  run-stats <stats-file> <out-file> <text-out> <agent> <model> <seconds> <status> <custom 0|1>
                                          turn one agent run's raw output into stats + human text
  stats-table <bundle> <wall-seconds>     "### Run stats" markdown from <bundle>/stats/*.json
  progress-md <bundle> <strong> <standard> <fast> <lead> [only-ids]
                                          the "in progress" comment (with pending status line)
  failure-md <bundle> <lead> [reason]     the "failed" comment (with verdict=error status line)
  present <bundle>                        color summary.md, link file:line, fold secondary sections
  json-field <field>                      print a top-level field of JSON on stdin
  json-pair <id-field> <url-field>        print "<id>\\t<url>" from JSON on stdin
  inline-plan <bundle>                    JSON lines of inline comments still to post
  inline-shell                            one plan object on stdin → shell assignments
  inline-record <bundle> <obj.json> <id> <url> <error>
                                          upsert one row of <bundle>/inline-comments.json
  inline-open <bundle> [concern] [file] [line] [key]
                                          JSON lines of unresolved inline comments that have an id
  inline-resolved <bundle> <key>          mark that row resolved
  gh-thread-id <comment-id>               GraphQL JSON on stdin → review-thread node id
  bb-comment <slug> <pr> <file> [id]      Bitbucket REST: create (or update id) a PR comment;
                                          prints "<id>\t<url>"; credentials in env BB_API_USER/PASS
  bb-inline <slug> <pr> <file> <path> <line>
                                          Bitbucket REST: inline comment on the new-file line
  bb-reply <slug> <pr> <parent-id> <file> Bitbucket REST: reply to a comment
  bb-resolve <slug> <pr> <comment-id>     Bitbucket REST: resolve a comment thread
"""
import hashlib
import json
import os
import re
import shlex
import sys
import time

STATUS_RE = re.compile(
    r"wtc-review v1 head=(?P<head>[0-9a-f]{12,40}) verdict=(?P<verdict>[a-z-]+) "
    r"blockers=(?P<blockers>\d+) round=(?P<round>\d+)"
)
# The status line also carries `pending` (run in flight) and `error` (run
# failed) — never a verdict a lead may write, never opens the gate.
VERDICTS = ("pass", "pass-with-notes", "changes-requested")
SEVERITIES = ("blocker", "major", "minor", "nit")
STATUSES = ("ok", "issues", "skipped", "error")


def parse_frontmatter(path):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return {}, ""
    if not text.startswith("---"):
        return {}, text
    lines = text.split("\n")
    fm = {}
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", lines[i])
        if not m:
            continue
        v = re.sub(r"\s+#.*$", "", m.group(2)).strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        fm[m.group(1)] = v
    body = "\n".join(lines[end + 1:]) if end is not None else text
    return fm, body


def glob_to_re(pat):
    out, i = "", 0
    while i < len(pat):
        c = pat[i]
        if pat.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif pat.startswith("**", i):
            out += ".*"
            i += 2
        elif c == "*":
            out += "[^/]*"
            i += 1
        elif c == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(c)
            i += 1
    return re.compile("^" + out + "$")


def applies_to(spec, files):
    spec = (spec or "always").strip()
    if spec in ("", "always"):
        return True
    if spec == "never":
        return False
    for pat in spec.split():
        rx = glob_to_re(pat.lstrip("/"))
        for f in files:
            # A pattern without "/" matches the basename anywhere (gitignore-like).
            if rx.match(f) or ("/" not in pat and rx.match(os.path.basename(f))):
                return True
    return False


def cmd_concerns(outdir, changed, layers):
    files = [l.strip() for l in open(changed, encoding="utf-8") if l.strip()]
    chosen = {}
    for layer in layers:
        if not os.path.isdir(layer):
            continue
        for name in sorted(os.listdir(layer)):
            if not name.endswith(".md"):
                continue
            path = os.path.join(layer, name)
            fm, _ = parse_frontmatter(path)
            cid = fm.get("id") or name[:-3]
            if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", cid):
                print("warn: skipping %s (bad id %r)" % (path, cid), file=sys.stderr)
                continue
            chosen[cid] = (path, fm)
    os.makedirs(outdir, exist_ok=True)
    for cid in sorted(chosen):
        path, fm = chosen[cid]
        if not applies_to(fm.get("applies"), files):
            continue
        tier = fm.get("tier", "standard")
        if tier not in ("strong", "standard", "fast"):
            print("warn: %s: unknown tier %r, using standard" % (path, tier), file=sys.stderr)
            tier = "standard"
        with open(path, encoding="utf-8") as src, open(
            os.path.join(outdir, cid + ".md"), "w", encoding="utf-8"
        ) as dst:
            dst.write(src.read())
        print("%s\t%s\t%s" % (cid, tier, fm.get("needs", "")))


def _get(d, *path):
    for p in path:
        if not isinstance(d, dict):
            return None
        d = d.get(p)
    return d


def cmd_pr_info(jpath, body_out):
    d = json.load(open(jpath, encoding="utf-8"))
    title = d.get("title") or ""
    body = d.get("description")
    if body is None:
        body = d.get("body") or ""
    dest = _get(d, "destination", "branch", "name") or d.get("baseRefName") or ""
    head = _get(d, "source", "commit", "hash") or d.get("headRefOid") or ""
    hbranch = _get(d, "source", "branch", "name") or d.get("headRefName") or ""
    url = _get(d, "links", "html", "href") or d.get("url") or ""
    state = d.get("state") or ""
    draft = d.get("draft")
    if draft is None:
        draft = d.get("isDraft")
    with open(body_out, "w", encoding="utf-8") as f:
        f.write("# %s\n\n%s\n" % (title, body))
    for k, v in (
        ("PRI_TITLE", title), ("PRI_DEST", dest), ("PRI_HEAD", head),
        ("PRI_HEAD_BRANCH", hbranch), ("PRI_URL", url), ("PRI_STATE", state),
        ("PRI_DRAFT", "" if draft is None else str(bool(draft)).lower()),
    ):
        print("%s=%s" % (k, shlex.quote(str(v))))


def _comment_list(d):
    if isinstance(d, dict):
        d = d.get("comments") or d.get("values") or []
    return d if isinstance(d, list) else []


def cmd_merge_comments(conversation, inline_pages, output):
    issue = _comment_list(json.load(open(conversation, encoding="utf-8")))
    pages = json.load(open(inline_pages, encoding="utf-8"))
    if not isinstance(pages, list):
        raise ValueError("inline comments response is not a list")
    inline = []
    for page in pages:
        if not isinstance(page, list):
            raise ValueError("inline comments page is not a list")
        inline.extend(page)
    with open(output, "w", encoding="utf-8") as f:
        json.dump({"comments": issue + inline}, f)
        f.write("\n")


def _norm(c):
    body = _get(c, "content", "raw") or c.get("body") or c.get("raw") or ""
    who = (
        _get(c, "user", "display_name") or _get(c, "author", "login")
        or _get(c, "author", "display_name") or _get(c, "user", "nickname") or "?"
    )
    when = c.get("created_on") or c.get("createdAt") or c.get("created_at") or ""
    url = _get(c, "links", "html", "href") or c.get("url") or c.get("html_url") or ""
    return {"id": c.get("id"), "body": body, "who": who, "when": when, "url": url}


def _sorted_comments(path):
    items = [_norm(c) for c in _comment_list(json.load(open(path, encoding="utf-8")))]
    return sorted(items, key=lambda c: c["when"])


def cmd_comments(path, after_review):
    items = _sorted_comments(path)
    if after_review:
        last = -1
        for i, c in enumerate(items):
            if STATUS_RE.search(c["body"]):
                last = i
        items = items[last + 1:]
    for c in items:
        if STATUS_RE.search(c["body"]):
            continue
        print("### %s, %s\n\n%s\n" % (c["who"], c["when"], c["body"].strip()))


def cmd_inline_keys(path):
    keys = set()
    for comment in _sorted_comments(path):
        keys.update(re.findall(r"wtc-review-inline v1 key=([0-9a-f]{10})", comment["body"]))
    for key in sorted(keys):
        print(key)


def cmd_latest_status(path):
    latest = None
    for c in _sorted_comments(path):
        m = None
        for m in STATUS_RE.finditer(c["body"]):
            pass  # last match in the comment
        if m:
            latest = (m, c)
    if not latest:
        sys.exit(1)
    m, c = latest
    gh_id = re.search(r"issuecomment-(\d+)", c["url"])
    cid = gh_id.group(1) if gh_id else str(c["id"] or "-")
    print("%s %s %s %s %s %s" % (m["head"], m["verdict"], m["blockers"], m["round"], c["url"] or "-", cid))


def cmd_status_line(path):
    body = open(path, encoding="utf-8").read()
    matches = list(STATUS_RE.finditer(body))
    if len(matches) != 1:
        raise ValueError("summary must have exactly one review status line")
    print("%s %s" % (matches[0]["head"], matches[0]["verdict"]))


def cmd_validate(path, cid):
    try:
        d = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        print("invalid JSON: %s" % e, file=sys.stderr)
        sys.exit(1)
    errs = []
    if not isinstance(d, dict):
        errs.append("top level is not an object")
    else:
        if d.get("concern") != cid:
            errs.append("concern != %s" % cid)
        if d.get("status") not in STATUSES:
            errs.append("bad status %r" % d.get("status"))
        if not isinstance(d.get("findings"), list):
            errs.append("findings is not a list")
        else:
            for i, f in enumerate(d["findings"]):
                if not isinstance(f, dict) or f.get("severity") not in SEVERITIES:
                    errs.append("findings[%d]: bad severity" % i)
                elif not f.get("title"):
                    errs.append("findings[%d]: no title" % i)
    if errs:
        print("; ".join(errs), file=sys.stderr)
        sys.exit(1)


def cmd_blockers(fdir):
    n = 0
    for name in sorted(os.listdir(fdir)) if os.path.isdir(fdir) else []:
        if not name.endswith(".json"):
            continue
        try:
            d = json.load(open(os.path.join(fdir, name), encoding="utf-8"))
            n += sum(1 for f in d.get("findings", []) if f.get("severity") == "blocker" and f.get("prior") != "addressed")
        except Exception:
            pass
    print(n)


def cmd_verdict(path):
    try:
        w = open(path, encoding="utf-8").read().strip()
    except OSError:
        sys.exit(1)
    if w not in VERDICTS:
        sys.exit(1)
    print(w)


def cmd_render(tpl, pairs):
    text = open(tpl, encoding="utf-8").read()
    for p in pairs:
        k, _, v = p.partition("=")
        text = text.replace("{{%s}}" % k, v)
    sys.stdout.write(text)


def cmd_stub(cid, status, notes):
    json.dump({"concern": cid, "status": status, "notes": notes, "findings": []},
              sys.stdout, indent=2)
    print()


# --- stats ------------------------------------------------------------------

def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _json_lines(text):
    """(objects, other-lines) for text that mixes JSON lines with plain output."""
    objs, other = [], []
    for line in text.splitlines():
        t = line.strip()
        if t.startswith("{"):
            try:
                o = json.loads(t)
                if isinstance(o, dict):
                    objs.append(o)
                    continue
            except ValueError:
                pass
        other.append(line)
    return objs, other


def _parse_claude(text):
    """`claude -p --output-format json`: one result object; final text in .result."""
    objs, other = _json_lines(text)
    if not objs:
        try:  # pretty-printed / multi-line JSON
            o = json.loads(text)
            objs, other = ([o] if isinstance(o, dict) else []), []
        except ValueError:
            pass
    res = [o for o in objs if o.get("type") == "result" or "usage" in o]
    if not res:
        return text, {}
    r = res[-1]
    u = r.get("usage") or {}
    model = ""
    mu = r.get("modelUsage")
    if isinstance(mu, dict) and mu:
        model = sorted(mu, key=lambda k: -((mu[k] or {}).get("outputTokens") or 0)
                       if isinstance(mu[k], dict) else 0)[0]
    human = "\n".join(other + [str(r.get("result") or "")]).strip("\n") + "\n"
    return human, {
        "input_tokens": _int(u.get("input_tokens")),
        "output_tokens": _int(u.get("output_tokens")),
        "cache_read_tokens": _int(u.get("cache_read_input_tokens")),
        "cache_write_tokens": _int(u.get("cache_creation_input_tokens")),
        "cost_usd": r.get("total_cost_usd"),
        "turns": _int(r.get("num_turns")),
        "model": model,
        "error": bool(r.get("is_error")),
    }


def _parse_grok(text):
    """`grok --prompt-file --output-format json`: one object, often pretty-printed.
    Final text is .text. The thought field is not part of the review."""
    o = None
    try:
        o = json.loads(text)
    except ValueError:
        start = text.find("{")
        if start >= 0:
            try:
                o, _ = json.JSONDecoder().raw_decode(text[start:])
            except ValueError:
                o = None
    if not isinstance(o, dict) or ("text" not in o and "usage" not in o):
        return text, {}
    u = o.get("usage") or {}
    model = ""
    mu = o.get("modelUsage")
    if isinstance(mu, dict) and mu:
        model = sorted(mu, key=lambda k: -((mu[k] or {}).get("outputTokens") or 0)
                       if isinstance(mu[k], dict) else 0)[0]
    human = str(o.get("text") or "").strip("\n") + "\n"
    reason = str(o.get("stopReason") or "")
    return human, {
        "input_tokens": _int(u.get("input_tokens")),
        "output_tokens": _int(u.get("output_tokens")),
        "cache_read_tokens": _int(u.get("cache_read_input_tokens")),
        "cache_write_tokens": _int(u.get("cache_creation_input_tokens")),
        "cost_usd": o.get("total_cost_usd"),
        "turns": _int(o.get("num_turns")),
        "model": model,
        "error": bool(re.search(r"error|fail", reason, re.I)),
    }


def _parse_codex(text):
    """`codex exec --json` JSONL; usage summed over turn.completed. Field names
    as observed on codex-cli: input_tokens (includes cached), cached_input_tokens,
    cache_write_input_tokens, output_tokens. Best effort for other versions."""
    objs, other = _json_lines(text)
    if not objs:
        return text, {}
    inp = out = cread = cwrite = turns = 0
    msgs = []
    for o in objs:
        t = o.get("type")
        if t == "turn.completed":
            u = o.get("usage") or {}
            turns += 1
            i, c = _int(u.get("input_tokens")) or 0, _int(u.get("cached_input_tokens")) or 0
            inp += max(0, i - c)
            cread += c
            cwrite += _int(u.get("cache_write_input_tokens")) or 0
            out += _int(u.get("output_tokens")) or 0
        elif t == "item.completed":
            it = o.get("item") or {}
            if it.get("type") == "agent_message" and it.get("text"):
                msgs.append(str(it["text"]))
    human = "\n".join(other + msgs).strip("\n") + "\n"
    if not turns:
        return human, {}
    return human, {"input_tokens": inp, "output_tokens": out, "cache_read_tokens": cread,
                   "cache_write_tokens": cwrite, "cost_usd": None, "turns": turns}


def cmd_run_stats(stats_file, out_file, text_out, agent, model, seconds, status, custom):
    try:
        text = open(out_file, encoding="utf-8", errors="replace").read()
    except OSError:
        text = ""
    st = {"agent": agent, "model": model, "seconds": _int(seconds) or 0,
          "input_tokens": None, "output_tokens": None, "cache_read_tokens": None,
          "cache_write_tokens": None, "cost_usd": None, "turns": None, "status": status}
    human, got = text, {}
    if custom == "1":
        # a custom launcher may have written the stats file itself
        try:
            d = json.load(open(stats_file, encoding="utf-8"))
            got = d if isinstance(d, dict) else {}
        except (OSError, ValueError):
            got = {}
    elif agent == "claude":
        human, got = _parse_claude(text)
    elif agent == "codex":
        human, got = _parse_codex(text)
    elif agent == "grok":
        human, got = _parse_grok(text)
    if got.pop("error", False) and status == "ok":
        st["status"] = "error"
    for k in ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "turns"):
        if k in got:
            st[k] = _int(got[k])
    if isinstance(got.get("cost_usd"), (int, float)):
        st["cost_usd"] = float(got["cost_usd"])
    if custom == "1" and _int(got.get("seconds")) is not None:
        st["seconds"] = _int(got["seconds"])
    if not model and got.get("model"):
        st["model"] = str(got["model"])
    with open(stats_file, "w", encoding="utf-8") as f:
        json.dump(st, f, indent=2)
        f.write("\n")
    with open(text_out, "w", encoding="utf-8") as f:
        f.write(human)


def fmt_secs(n):
    n = int(n or 0)
    if n < 60:
        return "%ds" % n
    if n < 3600:
        return "%dm%02ds" % (n // 60, n % 60)
    return "%dh%02dm" % (n // 3600, (n % 3600) // 60)


def fmt_tok(n):
    if n is None:
        return "-"
    if n < 1000:
        return str(n)
    if n < 10000:
        return "%.1fk" % (n / 1000)
    if n < 1000000:
        return "%dk" % round(n / 1000)
    return "%.1fM" % (n / 1000000)


def _cost(c):
    return "-" if c is None else "$%.2f" % c


def cmd_stats_table(bundle, wall):
    sdir = os.path.join(bundle, "stats")
    rows = []
    for name in sorted(os.listdir(sdir)) if os.path.isdir(sdir) else []:
        if not name.endswith(".json"):
            continue
        try:
            d = json.load(open(os.path.join(sdir, name), encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(d, dict):
            rows.append((name[:-5], d))
    rows.sort(key=lambda r: (r[0] == "lead", r[0]))
    if not rows:
        return
    tin = tout = tcr = tsec = 0
    costs = []
    unknown_cost = False
    lines = ["### Run stats", "",
             "| Concern | Agent | Time | Tokens in / out (cache read) | Cost |",
             "|---|---|---|---|---|"]
    for cid, d in rows:
        if d.get("status") == "skipped":
            lines.append("| %s | - | - | - | - |" % cid)
            continue
        spec = "%s:%s" % (d.get("agent") or "?", d.get("model") or "")
        tsec += _int(d.get("seconds")) or 0
        i, o, cr = d.get("input_tokens"), d.get("output_tokens"), d.get("cache_read_tokens")
        tin += i or 0
        tout += o or 0
        tcr += cr or 0
        if isinstance(d.get("cost_usd"), (int, float)):
            costs.append(d["cost_usd"])
        else:
            unknown_cost = True
        toks = "-" if i is None and o is None else "%s / %s (%s)" % (fmt_tok(i), fmt_tok(o), fmt_tok(cr))
        note = "" if d.get("status") in ("ok", None) else " (%s)" % d["status"]
        lines.append("| %s%s | %s | %s | %s | %s |" % (
            cid, note, spec, fmt_secs(d.get("seconds")), toks, _cost(d.get("cost_usd"))))
    total_cost = "-" if not costs else "$%.2f%s" % (sum(costs), "+" if unknown_cost else "")
    lines.append("| **Total** | | %s | %s / %s (%s) | %s |" % (
        fmt_secs(tsec), fmt_tok(tin), fmt_tok(tout), fmt_tok(tcr), total_cost))
    lines += ["", "Wall-clock for the whole run: %s (agent time summed: %s)." % (
        fmt_secs(_int(wall) or 0), fmt_secs(tsec))]
    print("\n".join(lines))


# --- comment bodies -----------------------------------------------------------

def _manifest_value(bundle, key):
    try:
        for line in open(os.path.join(bundle, "manifest.env"), encoding="utf-8"):
            if line.startswith(key + "="):
                parts = shlex.split(line.rstrip("\n").split("=", 1)[1])
                return parts[0] if parts else ""
    except (OSError, ValueError):
        pass
    return ""


def _lead_phrase(lead):
    """codex:,claude:opus → 'codex, then claude:opus'. A trailing colon is an empty model."""
    parts = []
    for part in re.split(r"[,\s]+", lead or ""):
        part = part.strip().strip("`")
        if not part:
            continue
        if part.endswith(":"):
            part = part[:-1]
        parts.append(part)
    if not parts:
        return "lead unset"
    if len(parts) == 1:
        return "lead " + parts[0]
    return parts[0] + ", then " + ", ".join(parts[1:])


def _blockers_phrase(n):
    try:
        n = int(n)
    except (TypeError, ValueError):
        n = 0
    if n == 0:
        return "no blockers"
    if n == 1:
        return "1 blocker"
    return "%d blockers" % n


def format_status(head, verdict, blockers, round_n, lead, forge):
    """A readable footer, plus the machine line the gate parses, folded away."""
    mark = _VERDICT_MARK.get(verdict, "")
    short = (head or "")[:7]
    pretty = "%s **%s** · round %s · `%s` · %s · %s" % (
        mark, verdict, round_n or "1", short or "?",
        _blockers_phrase(blockers), _lead_phrase(lead))
    machine = "`wtc-review v1 head=%s verdict=%s blockers=%s round=%s lead=%s`" % (
        head, verdict, blockers, round_n or "1", lead or "")
    return pretty + "\n\n" + _fold_block("Gate record", machine, forge).rstrip("\n")


def _status_footer(bundle, verdict, blockers, lead):
    return format_status(
        _manifest_value(bundle, "HEAD_SHA"), verdict, blockers,
        _manifest_value(bundle, "ROUND") or "1", lead,
        _manifest_value(bundle, "FORGE"))


def cmd_progress(bundle, strong, standard, fast, lead, only):
    specs = {"strong": strong, "standard": standard, "fast": fast}
    ids = set(x for x in only.split(",") if x)
    cdir = os.path.join(bundle, "concerns")
    rows = []
    for name in sorted(os.listdir(cdir)) if os.path.isdir(cdir) else []:
        if not name.endswith(".md"):
            continue
        cid = name[:-3]
        if ids and cid not in ids:
            continue
        tier = parse_frontmatter(os.path.join(cdir, name))[0].get("tier", "standard")
        if tier not in specs:
            tier = "standard"
        rows.append((cid, tier, specs[tier]))
    head = _manifest_value(bundle, "HEAD_SHA")
    started = time.strftime("%Y-%m-%d %H:%M:%SZ", time.gmtime())
    lines = ["⏳ **Local review: in progress**", "",
             "Round %s, head `%s`. Started %s." % (
                 _manifest_value(bundle, "ROUND") or "1", head[:7], started),
             "",
             "This comment is the pending review. It is updated in place when the run "
             "finishes — there is no second comment. The gate stays closed "
             "(`verdict=pending`) until then.",
             "", "| Concern | Tier | Agent |", "|---|---|---|"]
    for cid, tier, spec in rows:
        lines.append("| %s | %s | %s |" % (cid, tier, spec))
    lines.append("| lead (aggregation) | - | %s |" % lead)
    lines += ["", _status_footer(bundle, "pending", 0, lead)]
    print("\n".join(lines))


_SECRET_RES = [
    re.compile(r"(?i)(token|passw(?:or)?d|secret|authorization|api[_-]?key|bearer|basic)([\"'\s:=]+)(?:(?:basic|bearer)\s+)?\S+"),
    re.compile(r"\b(?:sk|ghp|gho|xox[a-z]|ATATT)[A-Za-z0-9_\-]{8,}\S*"),
    re.compile(r"\b[A-Za-z0-9+/=_\-]{40,}\b"),
]


def redact(text):
    text = _SECRET_RES[0].sub(lambda m: m.group(1) + m.group(2) + "[redacted]", text)
    for rx in _SECRET_RES[1:]:
        text = rx.sub("[redacted]", text)
    return text


def cmd_failure(bundle, lead, reason):
    tail = ""
    try:
        with open(os.path.join(bundle, "run.log"), encoding="utf-8", errors="replace") as f:
            tail = "\n".join(f.read().splitlines()[-12:])
    except OSError:
        pass
    tail = redact(tail).replace("```", "~~~")
    head = _manifest_value(bundle, "HEAD_SHA")
    out = ["❌ **Local review: failed**", "",
           "Round %s, head `%s`. The review run did not finish; there is no verdict and the "
           "gate stays closed until a run completes." % (_manifest_value(bundle, "ROUND") or "1", head[:7])]
    if reason:
        out += ["", "Reason: %s" % redact(reason)]
    if tail:
        out += ["", "End of `run.log`:", "", "```", tail, "```"]
    out += ["", _status_footer(bundle, "error", 0, lead)]
    print("\n".join(out))


def cmd_json_field(field):
    try:
        v = json.load(sys.stdin).get(field)
    except (ValueError, AttributeError):
        sys.exit(1)
    if v is None:
        sys.exit(1)
    print(v)


def cmd_json_pair(id_field, url_field):
    try:
        d = json.load(sys.stdin)
    except ValueError:
        sys.exit(1)
    if not isinstance(d, dict):
        sys.exit(1)
    ident = d.get(id_field)
    if ident is None:
        sys.exit(1)
    print("%s\t%s" % (ident, d.get(url_field) or ""))


def _bb_api(slug, suffix, method, payload):
    import base64
    import urllib.error
    import urllib.request
    auth = base64.b64encode(("%s:%s" % (os.environ["BB_API_USER"], os.environ["BB_API_PASS"])).encode()).decode()
    url = "https://api.bitbucket.org/2.0/repositories/%s/%s" % (slug, suffix.lstrip("/"))
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Authorization": "Basic " + auth, "Content-Type": "application/json",
                 "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        print("review-post: error: %s %s failed: %s %s" % (method, suffix, e, detail), file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print("review-post: error: %s %s failed: %s" % (method, suffix, e), file=sys.stderr)
        sys.exit(1)


def _comment_html(d):
    return ((d.get("links") or {}).get("html") or {}).get("href") or ""


def cmd_bb_comment(slug, num, path, cid):
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    suffix = "pullrequests/%s/comments" % num
    method = "POST"
    if cid:
        suffix += "/%s" % cid
        method = "PUT"
    d = _bb_api(slug, suffix, method, {"content": {"raw": raw}})
    print("%s\t%s" % (d.get("id", cid or ""), _comment_html(d)))


def cmd_bb_inline(slug, num, path, file, line):
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    d = _bb_api(slug, "pullrequests/%s/comments" % num, "POST", {
        "content": {"raw": raw},
        "inline": {"path": file, "to": int(line)},
    })
    print("%s\t%s" % (d.get("id", ""), _comment_html(d)))


def cmd_bb_reply(slug, num, parent, path):
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    d = _bb_api(slug, "pullrequests/%s/comments" % num, "POST", {
        "content": {"raw": raw},
        "parent": {"id": int(parent)},
    })
    print("%s\t%s" % (d.get("id", ""), _comment_html(d)))


def cmd_bb_resolve(slug, num, cid):
    _bb_api(slug, "pullrequests/%s/comments/%s/resolve" % (num, cid), "POST", {})
    print("ok")


# --- inline comments --------------------------------------------------------

def _inline_key(concern, path, line, title):
    raw = "%s\n%s\n%s\n%s" % (concern, path, line, title)
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:10]


def _finding_line(f):
    line = f.get("line")
    if isinstance(line, bool) or line is None:
        return None
    if isinstance(line, str) and line.isdigit():
        line = int(line)
    if isinstance(line, float) and line == int(line):
        line = int(line)
    if isinstance(line, int) and line > 0:
        return line
    return None


def _safe_repo_path(path):
    if not isinstance(path, str):
        return None
    p = path.strip()
    if not p or p.startswith("/") or ".." in p.split("/"):
        return None
    return p


def _inline_rows(bundle):
    path = os.path.join(bundle, "inline-comments.json")
    try:
        rows = json.load(open(path, encoding="utf-8"))
    except Exception:
        return []
    return rows if isinstance(rows, list) else []


def _write_inline_rows(bundle, rows):
    path = os.path.join(bundle, "inline-comments.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=2)
        f.write("\n")


def _prior_inline_keys(bundle):
    keys = set()
    path = os.path.join(bundle, "prior", "inline-keys.txt")
    try:
        for line in open(path, encoding="utf-8"):
            key = line.strip()
            if re.fullmatch(r"[0-9a-f]{10}", key):
                keys.add(key)
    except OSError:
        pass
    # Older bundles recorded markers only in the recent comments transcript.
    path = os.path.join(bundle, "prior", "comments.md")
    try:
        text = open(path, encoding="utf-8").read()
        keys.update(re.findall(r"wtc-review-inline v1 key=([0-9a-f]{10})", text))
    except OSError:
        pass
    return keys


_SEV_MARK = {"blocker": "🔴", "major": "🟠", "minor": "🟡", "nit": "🔵"}
_VERDICT_MARK = {
    "pass": "🟢", "pass-with-notes": "🟡", "changes-requested": "🔴",
    "pending": "⏳", "error": "❌",
}
# Secondary sections stay as headings on Bitbucket. An ```expand fence does
# collapse there, and the text inside is not rendered as Markdown (the
# screenshot of round 7 showed the link syntax literally). GitHub comments
# use <details>, which does render the Markdown inside.
_FOLD_PREFIXES = ("minor", "concerns", "addressed", "run stats", "dropped")


def _sev_mark(sev):
    return _SEV_MARK.get(sev, "⚪")


def _hunk_url(bundle, path, line):
    """Link a new-file line. Inline comments already sit on the diff hunk."""
    forge = _manifest_value(bundle, "FORGE")
    sha = _manifest_value(bundle, "HEAD_SHA")
    slug = _manifest_value(bundle, "SLUG")
    url = _manifest_value(bundle, "URL")
    if not sha or not path or not line:
        return ""
    if forge == "bitbucket" and url and "/pull-requests/" in url:
        base = url.split("/pull-requests/", 1)[0]
        return "%s/src/%s/%s#lines-%s" % (base, sha, path, line)
    if forge == "github" and slug:
        return "https://github.com/%s/blob/%s/%s#L%s" % (slug, sha, path, line)
    return ""


def _fold_block(title, body, forge):
    body = body.strip("\n")
    if "```" in body:
        return "### %s\n\n%s\n" % (title, body)
    if forge == "github":
        return "<details>\n<summary>%s</summary>\n\n%s\n\n</details>\n" % (title, body)
    return "### %s\n\n%s\n" % (title, body)


def _should_fold(title):
    t = title.strip().lower()
    return t.startswith(_FOLD_PREFIXES)


def _linkify_hunks(text, bundle):
    def repl(m):
        url = _hunk_url(bundle, m.group(1), m.group(2))
        if not url:
            return m.group(0)
        return "[`%s:%s`](%s)" % (m.group(1), m.group(2), url)
    return re.sub(r"(?<!\[)`([A-Za-z0-9_./+-]+):(\d+)`", repl, text)


def _color_verdict(text, final_verdict=None):
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r"^(?:[🟢🟡🔴⏳❌]\s+)?\*\*Local review: ([a-z-]+)\*\*(.*)$", line)
        if not m:
            continue
        verdict = final_verdict or m.group(1)
        mark = _VERDICT_MARK.get(verdict)
        if verdict != m.group(1):
            lines[i] = "%s **Local review: %s** — The runner adjusted the lead verdict; see the findings and gate record." % (mark or "", verdict)
        elif mark and not line.startswith(mark):
            lines[i] = "%s **Local review: %s**%s" % (mark, verdict, m.group(2))
        break
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def cmd_present(bundle):
    """Color the verdict, link `file:line`, and collapse secondary sections."""
    path = os.path.join(bundle, "summary.md")
    text = open(path, encoding="utf-8").read()
    forge = _manifest_value(bundle, "FORGE")
    status, body = [], []
    in_fence = False
    heading = ""
    for line in text.splitlines():
        if line.startswith("```"):
            in_fence = not in_fence
            body.append(line)
            continue
        hm = re.match(r"^###\s+(.+?)\s*$", line)
        if not in_fence and hm:
            heading = hm.group(1).strip().lower()
        # A raw status line. One already under the Gate record heading stays put.
        if not in_fence and STATUS_RE.search(line) and heading != "gate record":
            status.append(line)
            continue
        body.append(line)
    text = _linkify_hunks("\n".join(body), bundle)
    verdict = open(os.path.join(bundle, "verdict"), encoding="utf-8").read().strip() if os.path.isfile(os.path.join(bundle, "verdict")) else None
    text = _color_verdict(text, verdict)
    preamble, title, buf, sections = [], None, [], []
    for line in text.splitlines():
        m = re.match(r"^###\s+(.+?)\s*$", line)
        if m:
            if title is None:
                preamble = buf
            else:
                sections.append((title, buf))
            title, buf = m.group(1), []
        else:
            buf.append(line)
    if title is None:
        preamble = buf
    else:
        sections.append((title, buf))
    out = ["\n".join(preamble).strip("\n"), ""]
    for title, buf in sections:
        body = "\n".join(buf).strip("\n")
        if _should_fold(title):
            out.append(_fold_block(title, body, forge))
        else:
            out.append("### %s\n\n%s\n" % (title, body))
    rendered = "\n".join(out).strip() + "\n"
    if status:
        blocks = []
        for line in status:
            m = STATUS_RE.search(line)
            lead_m = re.search(r"lead=([^`\s]+)", line)
            lead = lead_m.group(1) if lead_m else ""
            blocks.append(format_status(
                m.group("head"), m.group("verdict"), m.group("blockers"),
                m.group("round"), lead, forge))
        rendered += "\n" + "\n\n".join(blocks) + "\n"
    with open(path, "w", encoding="utf-8") as f:
        f.write(rendered)


def cmd_inline_plan(bundle):
    """JSON lines for open findings that still need an inline comment."""
    posted = set()
    for r in _inline_rows(bundle):
        if isinstance(r, dict) and r.get("key") and r.get("id"):
            posted.add(r["key"])
    prior = _prior_inline_keys(bundle)
    fdir = os.path.join(bundle, "findings")
    if not os.path.isdir(fdir):
        return
    round_n = _manifest_value(bundle, "ROUND") or "1"
    outdir = os.path.join(bundle, ".inline")
    n = 0
    seen = set()
    for name in sorted(os.listdir(fdir)):
        if not name.endswith(".json"):
            continue
        try:
            d = json.load(open(os.path.join(fdir, name), encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(d, dict):
            continue
        concern = d.get("concern") or name[:-5]
        for f in d.get("findings") or []:
            if not isinstance(f, dict) or f.get("prior") == "addressed":
                continue
            path = _safe_repo_path(f.get("file"))
            line = _finding_line(f)
            title = (f.get("title") or "").strip()
            sev = f.get("severity")
            if not path or not line or not title or sev not in SEVERITIES:
                continue
            key = _inline_key(concern, path, line, title)
            if key in seen or key in posted or key in prior:
                continue
            seen.add(key)
            detail = (f.get("detail") or "").strip()
            suggestion = (f.get("suggestion") or "").strip()
            marker = "`wtc-review-inline v1 key=%s concern=%s file=%s line=%s`" % (key, concern, path, line)
            parts = ["%s **%s** · `%s` — %s" % (_sev_mark(sev), sev, concern, title), ""]
            hunk = _hunk_url(bundle, path, line)
            if hunk:
                parts += ["[`%s:%s`](%s)" % (path, line, hunk), ""]
            if detail:
                parts += [detail, ""]
            if suggestion:
                parts += ["Suggestion: %s" % suggestion, ""]
            parts += ["Round %s." % round_n, "", marker]
            n += 1
            if n == 1:
                os.makedirs(outdir, exist_ok=True)
            bpath = os.path.join(outdir, "%02d-%s.md" % (n, key))
            with open(bpath, "w", encoding="utf-8") as fh:
                fh.write("\n".join(parts) + "\n")
            json.dump({
                "key": key, "concern": concern, "file": path, "line": line,
                "severity": sev, "title": title, "body": bpath,
            }, sys.stdout, ensure_ascii=False)
            sys.stdout.write("\n")


def cmd_inline_shell():
    try:
        d = json.load(sys.stdin)
    except ValueError:
        sys.exit(1)
    if not isinstance(d, dict):
        sys.exit(1)
    for var, src in (("IL_KEY", "key"), ("IL_BODY", "body"), ("IL_FILE", "file"),
                     ("IL_ID", "id"), ("IL_CONCERN", "concern")):
        print("%s=%s" % (var, shlex.quote("" if d.get(src) is None else str(d.get(src)))))
    line = d.get("line")
    print("IL_LINE=%s" % shlex.quote("" if line is None else str(line)))


def cmd_inline_record(bundle, jpath, cid, url, error):
    rec = json.load(open(jpath, encoding="utf-8"))
    if not isinstance(rec, dict) or not rec.get("key"):
        sys.exit(1)
    rec.pop("body", None)
    rec["id"] = "" if cid is None else str(cid)
    rec["url"] = url or ""
    rec["error"] = error or ""
    rec["resolved"] = False
    rows = [r for r in _inline_rows(bundle) if not (isinstance(r, dict) and r.get("key") == rec["key"])]
    rows.append(rec)
    _write_inline_rows(bundle, rows)


def cmd_inline_open(bundle, concern, path, line, key):
    for r in _inline_rows(bundle):
        if not isinstance(r, dict) or not r.get("id") or r.get("resolved"):
            continue
        if concern and r.get("concern") != concern:
            continue
        if path and r.get("file") != path:
            continue
        if line and str(r.get("line")) != str(line):
            continue
        if key and r.get("key") != key:
            continue
        json.dump({k: r.get(k) for k in ("key", "concern", "file", "line", "id", "title")}, sys.stdout)
        sys.stdout.write("\n")


def cmd_inline_resolved(bundle, key):
    rows = _inline_rows(bundle)
    hit = False
    for r in rows:
        if isinstance(r, dict) and r.get("key") == key:
            r["resolved"] = True
            r["error"] = ""
            hit = True
    if not hit:
        sys.exit(1)
    _write_inline_rows(bundle, rows)


def cmd_gh_thread_id(comment_id):
    """Print the review-thread node id for a pull-comment database id.

    Prints ``already`` when that thread is resolved. Exit 1 when it is absent.
    """
    try:
        d = json.load(sys.stdin)
    except ValueError:
        sys.exit(1)
    want = str(comment_id)
    threads = (((d.get("data") or {}).get("repository") or {}).get("pullRequest") or {}).get("reviewThreads") or {}
    for t in threads.get("nodes") or []:
        comments = ((t.get("comments") or {}).get("nodes")) or []
        if any(str(c.get("databaseId")) == want for c in comments):
            if t.get("isResolved"):
                print("already")
            else:
                print(t.get("id") or "")
            return
    sys.exit(1)


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    c, a = argv[1], argv[2:]
    if c == "frontmatter":
        print(parse_frontmatter(a[0])[0].get(a[1], ""))
    elif c == "concerns":
        cmd_concerns(a[0], a[1], a[2:])
    elif c == "pr-info":
        cmd_pr_info(a[0], a[1])
    elif c == "comments":
        cmd_comments(a[0], "--after-review" in a[1:])
    elif c == "merge-comments":
        cmd_merge_comments(a[0], a[1], a[2])
    elif c == "inline-keys":
        cmd_inline_keys(a[0])
    elif c == "latest-status":
        cmd_latest_status(a[0])
    elif c == "status-line":
        cmd_status_line(a[0])
    elif c == "validate-findings":
        cmd_validate(a[0], a[1])
    elif c == "blockers":
        cmd_blockers(a[0])
    elif c == "verdict":
        cmd_verdict(a[0])
    elif c == "render":
        cmd_render(a[0], a[1:])
    elif c == "stub-json":
        cmd_stub(a[0], a[1], a[2])
    elif c == "run-stats":
        cmd_run_stats(*a[:8])
    elif c == "stats-table":
        cmd_stats_table(a[0], a[1])
    elif c == "progress-md":
        cmd_progress(a[0], a[1], a[2], a[3], a[4], a[5] if len(a) > 5 else "")
    elif c == "failure-md":
        cmd_failure(a[0], a[1], a[2] if len(a) > 2 else "")
    elif c == "json-field":
        cmd_json_field(a[0])
    elif c == "json-pair":
        cmd_json_pair(a[0], a[1])
    elif c == "present":
        cmd_present(a[0])
    elif c == "inline-plan":
        cmd_inline_plan(a[0])
    elif c == "inline-shell":
        cmd_inline_shell()
    elif c == "inline-record":
        cmd_inline_record(a[0], a[1], a[2] if len(a) > 2 else "", a[3] if len(a) > 3 else "", a[4] if len(a) > 4 else "")
    elif c == "inline-open":
        cmd_inline_open(a[0], a[1] if len(a) > 1 else "", a[2] if len(a) > 2 else "",
                        a[3] if len(a) > 3 else "", a[4] if len(a) > 4 else "")
    elif c == "inline-resolved":
        cmd_inline_resolved(a[0], a[1])
    elif c == "gh-thread-id":
        cmd_gh_thread_id(a[0])
    elif c == "bb-comment":
        cmd_bb_comment(a[0], a[1], a[2], a[3] if len(a) > 3 else "")
    elif c == "bb-inline":
        cmd_bb_inline(a[0], a[1], a[2], a[3], a[4])
    elif c == "bb-reply":
        cmd_bb_reply(a[0], a[1], a[2], a[3])
    elif c == "bb-resolve":
        cmd_bb_resolve(a[0], a[1], a[2])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
