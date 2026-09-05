import base64
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('guard', Path(__file__).resolve().parents[1] / 'tools/publication-guard.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class FakeAPI:
    def __init__(self):
        self.content = b'ordinary text'
        self.file = {'status': 'modified', 'filename': 'example.txt', 'sha': 'b' * 40}
        self.pr = {'title': 'Generic update', 'body': '', 'head': {'sha': 'a' * 40, 'ref': 'feature/example'}}
        self.messages = [{'commit': {'message': 'Generic change'}}]
        self.comments = []

    def get(self, path):
        if path.startswith('git/blobs/'):
            return {'encoding': 'base64', 'size': len(self.content), 'content': base64.b64encode(self.content).decode()}
        return self.pr

    def pages(self, path, cap=3000):
        if path.endswith('/files'):
            return [self.file]
        if path.endswith('/commits'):
            return self.messages
        return self.comments


class Tests(unittest.TestCase):
    def test_unicode_literal_matching(self):
        guard = m.Guard('\n Orchid.Example \n')
        guard.scan({'nested': ['ＯＲＣＨＩＤ.example']})
        self.assertTrue(guard.found)
        guard = m.Guard('a.b')
        guard.scan('axb')
        self.assertFalse(guard.found)

    def test_empty_configuration(self):
        with self.assertRaises(ValueError):
            m.Guard(' \n')

    def test_pr_surfaces(self):
        for surface in ('title', 'body', 'ref', 'content', 'filename', 'commit', 'comment'):
            with self.subTest(surface=surface):
                api = FakeAPI()
                if surface in ('title', 'body'):
                    api.pr[surface] = 'Orchid.Example'
                elif surface == 'ref':
                    api.pr['head']['ref'] = 'Orchid.Example'
                elif surface == 'content':
                    api.content = b'Orchid.Example'
                elif surface == 'filename':
                    api.file['filename'] = 'Orchid.Example'
                elif surface == 'commit':
                    api.messages[0]['commit']['message'] = 'Orchid.Example'
                else:
                    api.comments = [{'body': 'Orchid.Example'}]
                guard = m.Guard('orchid.example')
                m.inspect_pr(api, guard, 1)
                self.assertTrue(guard.found)

    def test_clean_and_removed_content(self):
        api = FakeAPI()
        guard = m.Guard('orchid.example')
        m.inspect_pr(api, guard, 1)
        self.assertFalse(guard.found)
        api.file.update(status='removed', filename='orchid.example')
        api.content = b'orchid.example'
        m.inspect_pr(api, guard, 1)
        self.assertFalse(guard.found)

    def test_incomplete_blob_and_changing_head(self):
        api = FakeAPI()
        original = api.get
        def incomplete(path):
            result = original(path)
            if path.startswith('git/blobs/'):
                result['size'] += 1
            return result
        with patch.object(api, 'get', side_effect=incomplete):
            with self.assertRaises(ValueError):
                m.inspect_pr(api, m.Guard('orchid.example'), 1)
        calls = 0
        def changed(path):
            nonlocal calls
            result = original(path)
            if path == 'pulls/1':
                calls += 1
                if calls > 1:
                    result = dict(result, head={'sha': 'c' * 40})
            return result
        with patch.object(api, 'get', side_effect=changed):
            with self.assertRaises(ValueError):
                m.inspect_pr(api, m.Guard('orchid.example'), 1)

    def test_api_pagination_and_cap(self):
        api = m.API('example/repository', 'fake')
        with patch.object(api, 'get', side_effect=[[{}] * 100, [{}]]):
            self.assertEqual(len(api.pages('pulls/1/files')), 101)
        with patch.object(api, 'get', return_value=[{}] * 100):
            with self.assertRaises(ValueError):
                api.pages('pulls/1/commits', cap=250)

    def test_failures_do_not_echo_input(self):
        with tempfile.NamedTemporaryFile(mode='w') as event:
            event.write('{"number": 1}')
            event.flush()
            env = {'PUBLICATION_FORBIDDEN_TERMS': 'orchid.example', 'GITHUB_EVENT_PATH': event.name,
                   'GITHUB_REPOSITORY': 'example/repository', 'GH_TOKEN': 'fake', 'GITHUB_EVENT_NAME': 'pull_request_target'}
            for failure in (ValueError('orchid.example'), RuntimeError('fake secret')):
                output = io.StringIO()
                with patch.dict(os.environ, env), patch.object(m, 'inspect_pr', side_effect=failure), contextlib.redirect_stdout(output):
                    self.assertEqual(m.main(), 2)
                self.assertNotIn('orchid.example', output.getvalue())
                self.assertNotIn('fake secret', output.getvalue())

    def test_event_findings_are_generic(self):
        with tempfile.NamedTemporaryFile(mode='w') as event:
            event.write('{"comment": {"body": "Orchid.Example"}}')
            event.flush()
            env = {'PUBLICATION_FORBIDDEN_TERMS': 'orchid.example', 'GITHUB_EVENT_PATH': event.name,
                   'GITHUB_REPOSITORY': 'example/repository', 'GH_TOKEN': 'fake', 'GITHUB_EVENT_NAME': 'issue_comment'}
            output = io.StringIO()
            with patch.dict(os.environ, env), contextlib.redirect_stdout(output):
                self.assertEqual(m.main(), 1)
            self.assertNotIn('orchid', output.getvalue().lower())


if __name__ == '__main__':
    unittest.main()
