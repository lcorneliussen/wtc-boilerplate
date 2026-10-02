#!/usr/bin/env python3
"""Check forge access independently of cached PR facts; never emit raw errors."""
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor


def check(forge, slug):
    if forge == 'github':
        owner, repo = slug.split('/', 1)
        # Exercise the permissions used by the status PR/check query. Repo
        # metadata may be readable even when pull requests are not.
        command = ['gh', 'api', 'graphql', '-F', 'owner=' + owner,
                   '-F', 'name=' + repo,
                   '-f', 'query=query($owner:String!,$name:String!){repository(owner:$owner,name:$name){pullRequests(first:1){nodes{number reviewThreads(first:1){nodes{isResolved}} commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}}']
        label = 'GitHub (gh)'
    elif forge == 'bitbucket':
        owner, repo = slug.split('/', 1)
        command = ['bb', 'pr', 'list', '-w', owner, '-r', repo,
                   '--state', 'OPEN', '--limit', '50', '--json']
        label = 'Bitbucket (bb)'
    else:
        return None
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
    except FileNotFoundError:
        reason = 'CLI missing'
    except subprocess.TimeoutExpired:
        reason = 'connection timed out'
    except OSError:
        reason = 'CLI unavailable'
    else:
        try:
            data = json.loads(result.stdout)
        except ValueError:
            data = None
        payload = data.get('data') if isinstance(data, dict) else None
        repository = payload.get('repository') if isinstance(payload, dict) else None
        pulls = repository.get('pullRequests') if isinstance(repository, dict) else None
        if (result.returncode == 0 and isinstance(data, dict)
                and not data.get('error') and not data.get('errors')
                and ((forge == 'github' and isinstance(pulls, dict)
                      and isinstance(pulls.get('nodes'), list))
                     or (forge == 'bitbucket' and isinstance(data.get('pullRequests'), list)))):
            if forge == 'bitbucket' and data['pullRequests']:
                first_pr = data['pullRequests'][0]
                if not isinstance(first_pr, dict):
                    return f'{label}: invalid API response; PR/check data may be stale or unavailable'
                pr_id = first_pr.get('id')
                if not isinstance(pr_id, (int, str)) or not str(pr_id).strip():
                    return f'{label}: invalid API response; PR/check data may be stale or unavailable'
                try:
                    checks = subprocess.run(
                        ['bb', '--json', 'pr', 'checks', str(pr_id), '-w', owner, '-r', repo],
                        capture_output=True, text=True, timeout=10)
                except (OSError, subprocess.TimeoutExpired):
                    return f'{label}: check access unavailable; PR/check data may be stale or unavailable'
                try:
                    checks_data = json.loads(checks.stdout)
                except ValueError:
                    checks_data = None
                if (checks.returncode or not isinstance(checks_data, (dict, list))
                        or (isinstance(checks_data, dict) and
                            (checks_data.get('error') or checks_data.get('errors')))):
                    return f'{label}: check access unavailable; PR/check data may be stale or unavailable'
            return None
        # Only inspect failed responses: repository descriptions may discuss
        # authentication without indicating a failed request.
        output = (result.stdout + result.stderr).lower()
        if any(t in output for t in ['401', 'not authenticated', 'requires authentication',
                                     'bad credentials', 'authentication failed', 'auth login']):
            reason = 'authentication failed'
        elif any(t in output for t in ['403', 'forbidden', 'permission denied', 'not accessible', '404', 'not found']):
            reason = 'access unavailable'
        elif result.returncode:
            reason = 'API unavailable'
        else:
            reason = 'invalid API response'
    return f'{label}: {reason}; PR/check data may be stale or unavailable'


def collect(targets):
    probes = []
    seen = set()
    for forge, slug in targets:
        if forge in seen or '/' not in slug:
            continue
        seen.add(forge)
        probes.append((forge, slug))
    with ThreadPoolExecutor(max_workers=max(1, len(probes))) as pool:
        return [warning for warning in pool.map(lambda target: check(*target), probes)
                if warning]


if __name__ == '__main__':
    targets = [line.rstrip('\n').split('\t', 1) for line in sys.stdin if '\t' in line]
    print(json.dumps(collect(targets)))
