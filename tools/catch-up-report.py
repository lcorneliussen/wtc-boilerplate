#!/usr/bin/env python3
"""Serialize catch-up outcomes; no forge calls or target-collection writes."""
import datetime
import json
import os
from pathlib import Path
import sys
import tempfile


def atomic_write(path, text):
    path = Path(path)
    fd, tmp = tempfile.mkstemp(prefix='.catch-up-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


mode, rows, *args = sys.argv[1:]
if mode == 'row':
    kind, collection, repo, outcome, reason, source, target, result = args
    row = dict(kind=kind, collection=collection, repo=repo, outcome=outcome,
               reason=reason, source_sha=source or None, target_sha=target or None,
               result_sha=result or None)
    if outcome == 'needs-owner':
        row['next_actor'] = f'owning agent for collection {collection}'
        row['handoff'] = 'needed; no notification sent'
    with open(rows, 'a') as stream:
        stream.write(json.dumps(row) + '\n')
elif mode == 'finish':
    initiator, dry_run, status, report, output = args
    data = dict(schema_version=1, generated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                initiator=initiator, dry_run=dry_run == 'yes', exit_status=int(status),
                outcomes=[json.loads(line) for line in Path(rows).read_text().splitlines()])
    for row in data['outcomes']:
        row['collection_path'] = str(Path(initiator).parent / row['collection'])
        if row['outcome'] == 'needs-owner':
            row['next_action'] = (f"Resume in target collection {row['collection_path']}; "
                                  'read this report and inspect current state before fixing or pushing.')
    readable = ['# Catch-up report', '', f'Initiated from: {initiator}', '',
                '| Collection | Repo / step | Outcome | Reason |', '| --- | --- | --- | --- |']
    for row in data['outcomes']:
        fields = [row['collection'], row['repo'], row['outcome'], row['reason']]
        readable.append('| ' + ' | '.join(x.replace('|', '\\|').replace('\n', ' ') for x in fields) + ' |')
    readable.extend(['', 'needs-owner: hand the named collection its row and source/target SHAs. '
                     'This report does not wake an idle agent or authorize edits in that collection.'])
    encoded = json.dumps(data, indent=2) + '\n'
    markdown = '\n'.join(readable) + '\n'
    persistence_failed = False
    if report:
        try:
            atomic_write(report, encoded)
            atomic_write(report + '.md', markdown)
        except OSError as error:
            # Never lose the collected outcomes merely because the report
            # destination became unavailable after work had already started.
            persistence_failed = True
            data['exit_status'] = 1
            data['report_error'] = str(error)
            encoded = json.dumps(data, indent=2) + '\n'
            markdown += f'\nReport persistence failed: {error}\n'
            print(f'catch-up: report persistence failed: {error}', file=sys.stderr)
    print(encoded if output == 'json' else markdown, end='')
    if persistence_failed:
        sys.exit(1)
