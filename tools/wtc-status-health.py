#!/usr/bin/env python3
"""Check forge access independently of cached PR facts; never emit raw errors."""
import json
import subprocess
import sys


def check(forge, slug):
    if forge == 'github':
        command = ['gh', 'api', 'repos/' + slug]
        label = 'GitHub (gh)'
    elif forge == 'bitbucket':
        owner, repo = slug.split('/', 1)
        command = ['bb', 'repo', 'view', '--workspace', owner, '--repo', repo, '--json']
        label = 'Bitbucket (bb)'
    else:
        return None
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
    except FileNotFoundError:
        reason = 'CLI missing'
    except subprocess.TimeoutExpired:
        reason = 'connection timed out'
    else:
        try:
            data = json.loads(result.stdout)
        except ValueError:
            data = None
        if (result.returncode == 0 and isinstance(data, dict)
                and not data.get('error') and not data.get('errors')
                and (data.get('full_name') or data.get('uuid') or data.get('id'))):
            return None
        # Only inspect failed responses: repository descriptions may discuss
        # authentication without indicating a failed request.
        output = (result.stdout + result.stderr).lower()
        if any(t in output for t in ['401', 'not authenticated', 'requires authentication',
                                     'bad credentials', 'authentication failed', 'auth login']):
            reason = 'authentication failed'
        elif any(t in output for t in ['403', 'forbidden', 'permission denied', '404', 'not found']):
            reason = 'access unavailable'
        elif result.returncode:
            reason = 'API unavailable'
        else:
            reason = 'invalid API response'
    return f'{label}: {reason}; PR/check data may be stale or unavailable'


def collect(targets):
    warnings = []
    seen = set()
    for forge, slug in targets:
        if forge in seen or '/' not in slug:
            continue
        seen.add(forge)
        warning = check(forge, slug)
        if warning:
            warnings.append(warning)
    return warnings


if __name__ == '__main__':
    targets = [line.rstrip('\n').split('\t', 1) for line in sys.stdin if '\t' in line]
    print(json.dumps(collect(targets)))
