#!/usr/bin/env python3
"""Inspect publication data without executing it or printing matched content."""
import base64
import json
import os
import re
import sys
import unicodedata
import urllib.parse
import urllib.request

LIMIT = 10 * 1024 * 1024


def normalized(value):
    return unicodedata.normalize('NFKC', value).casefold()


class Guard:
    def __init__(self, secret):
        self.terms = [normalized(term.strip()) for term in secret.splitlines() if term.strip()]
        if not self.terms:
            raise ValueError('configuration unavailable')
        self.found = False

    def scan(self, value):
        if isinstance(value, str):
            self.found |= any(term in normalized(value) for term in self.terms)
        elif isinstance(value, dict):
            for key, item in value.items():
                self.scan(key)
                self.scan(item)
        elif isinstance(value, list):
            for item in value:
                self.scan(item)


class API:
    def __init__(self, repo, token):
        if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo):
            raise ValueError('invalid repository')
        self.root = 'https://api.github.com/repos/' + repo + '/'
        self.token = token

    def get(self, path):
        request = urllib.request.Request(self.root + path, headers={
            'Authorization': 'Bearer ' + self.token,
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
        })
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read(LIMIT + 1)
        if len(raw) > LIMIT:
            raise ValueError('response too large')
        return json.loads(raw)

    def pages(self, path, cap=3000):
        result = []
        for page in range(1, cap // 100 + 2):
            items = self.get(f'{path}?per_page=100&page={page}')
            if not isinstance(items, list):
                raise ValueError('invalid page')
            result.extend(items)
            # GitHub silently caps some endpoints; reaching the cap is unknown.
            if len(result) >= cap:
                raise ValueError('pagination limit')
            if len(items) < 100:
                return result
        raise ValueError('pagination incomplete')


def inspect_pr(api, guard, number):
    if not isinstance(number, int) or number < 1:
        raise ValueError('invalid pull request')
    path = f'pulls/{number}'
    pr = api.get(path)
    guard.scan([pr['title'], pr.get('body'), pr['head']['ref']])
    head = pr['head']['sha']
    if not re.fullmatch('[0-9a-f]{40}', head):
        raise ValueError('invalid head')
    for commit in api.pages(path + '/commits', cap=250):
        guard.scan(commit['commit']['message'])
    for file in api.pages(path + '/files'):
        # Removed names/content do not block cleanup of an earlier disclosure.
        if file['status'] == 'removed':
            continue
        guard.scan(file['filename'])
        # Read immutable blobs as data; never check out or execute PR content.
        sha = file['sha']
        if not re.fullmatch('[0-9a-f]{40}', sha):
            raise ValueError('invalid blob')
        blob = api.get('git/blobs/' + sha)
        if blob.get('encoding') != 'base64' or blob.get('size', LIMIT + 1) > LIMIT:
            raise ValueError('unsupported blob')
        content = base64.b64decode(blob['content'], validate=False)
        if len(content) != blob['size']:
            raise ValueError('incomplete blob')
        guard.scan(content.decode('utf-8', errors='replace'))
    for endpoint in (f'issues/{number}/comments', path + '/reviews', path + '/comments'):
        for item in api.pages(endpoint):
            guard.scan(item.get('body'))
    if api.get(path)['head']['sha'] != head:
        raise ValueError('head changed during scan')


def main():
    try:
        guard = Guard(os.environ.get('PUBLICATION_FORBIDDEN_TERMS', ''))
        with open(os.environ['GITHUB_EVENT_PATH'], encoding='utf-8') as stream:
            event = json.load(stream)
        api = API(os.environ['GITHUB_REPOSITORY'], os.environ['GH_TOKEN'])
        name = os.environ['GITHUB_EVENT_NAME']
        if name == 'pull_request_target':
            inspect_pr(api, guard, event['number'])
        elif name in ('issues', 'issue_comment', 'pull_request_review', 'pull_request_review_comment'):
            for key in ('issue', 'pull_request', 'comment', 'review'):
                item = event.get(key, {})
                guard.scan([item.get('title'), item.get('body')])
        elif name == 'workflow_dispatch':
            inspect_pr(api, guard, int(event['inputs']['pull_request']))
        else:
            raise ValueError('unsupported event')
        if guard.found:
            print('Publication guard: restricted content detected. Maintainer review required.')
            return 1
        print('Publication guard: scanned content passed.')
        return 0
    except Exception:
        # Exceptions may include URLs, filenames, source text or credentials.
        print('Publication guard: scan incomplete or configuration unavailable. Maintainer review required.')
        return 2


if __name__ == '__main__':
    sys.exit(main())
