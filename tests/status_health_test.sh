#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
it "forge health failures survive snapshot encoding and rendering"
python3 - "$HARNESS_SRC/tools" <<'PY'
import importlib.util, json, pathlib, subprocess, sys, threading, unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
root = pathlib.Path(sys.argv[1])
def module(name, file):
    spec = importlib.util.spec_from_file_location(name, root / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
health = module('health', 'wtc-status-health.py')
fmt = module('fmt', 'wtc-status-format.py')
class HealthTests(unittest.TestCase):
    def result(self, code=0, out='{"data":{"repository":{"pullRequests":{"nodes":[]}}}}', err=''):
        return subprocess.CompletedProcess([], code, out, err)
    def test_both_auth_failures_and_no_raw_error_leaks(self):
        for forge in ['github', 'bitbucket']:
            with patch.object(health.subprocess, 'run', return_value=self.result(1, '', 'HTTP 401 private-error-detail')):
                warning = health.check(forge, 'example/widget')
                self.assertIn('authentication failed', warning)
                self.assertNotIn('private-error-detail', warning)
    def test_access_and_network_are_not_mislabelled_auth(self):
        for err, expected in [('HTTP 403', 'access unavailable'), ('DNS failure', 'API unavailable')]:
            with patch.object(health.subprocess, 'run', return_value=self.result(1, '', err)):
                self.assertIn(expected, health.check('github', 'example/widget'))
    def test_timeout_and_missing_cli(self):
        for err, expected in [(FileNotFoundError(), 'CLI missing'), (subprocess.TimeoutExpired('gh', 10), 'timed out'),
                              (PermissionError(), 'CLI unavailable')]:
            with patch.object(health.subprocess, 'run', side_effect=err):
                self.assertIn(expected, health.check('github', 'example/widget'))
    def test_success_and_recovery(self):
        with patch.object(health.subprocess, 'run', side_effect=[self.result(1, '', '401'), self.result()]):
            self.assertTrue(health.collect([('github', 'example/widget')]))
            self.assertEqual([], health.collect([('github', 'example/widget')]))
    def test_one_probe_per_forge_and_no_false_positive(self):
        with patch.object(health.subprocess, 'run', return_value=self.result(out='{"data":{"repository":{"pullRequests":{"nodes":[]},"description":"auth login 401"}}}')) as call:
            self.assertEqual([], health.collect([('github', 'example/a'), ('github', 'example/b')]))
            self.assertEqual(1, call.call_count)
            self.assertIn('graphql', call.call_args.args[0])
    def test_repo_metadata_success_does_not_hide_pr_permission_failure(self):
        with patch.object(health.subprocess, 'run', return_value=self.result(out='{"data":{"repository":{"id":"R_1"}},"errors":[{"message":"Resource not accessible by integration"}]}')):
            self.assertIn('access unavailable', health.check('github', 'example/widget'))
    def test_malformed_success_is_not_healthy(self):
        for body in ['{}', '{"data":"error"}', '{"data":{"repository":"error"}}']:
            with patch.object(health.subprocess, 'run', return_value=self.result(out=body)):
                self.assertIn('invalid API response', health.check('github', 'example/widget'))
    def test_bitbucket_pr_access_and_checks(self):
        with patch.object(health.subprocess, 'run', return_value=self.result(out='{"id":1}')) as call:
            self.assertIn('invalid API response', health.check('bitbucket', 'example/widget'))
            self.assertEqual('pr', call.call_args.args[0][1])
        with patch.object(health.subprocess, 'run', side_effect=[
                self.result(out='{"pullRequests":[{"id":7}]}'),
                self.result(1, '', 'HTTP 403')]):
            self.assertIn('check access unavailable', health.check('bitbucket', 'example/widget'))
        with patch.object(health.subprocess, 'run', side_effect=[
                self.result(out='{"pullRequests":[{"id":7}]}'),
                self.result(out='{}')]):
            self.assertIsNone(health.check('bitbucket', 'example/widget'))
    def test_forge_probes_run_together_and_keep_warning_order(self):
        barrier = threading.Barrier(2, timeout=1)
        def probe(forge, slug):
            barrier.wait()
            return forge
        with patch.object(health, 'check', side_effect=probe):
            self.assertEqual(['github', 'bitbucket'], health.collect([
                ('github', 'example/a'), ('bitbucket', 'example/b')]))
    def test_snapshot_roundtrip_and_cached_render(self):
        warning = 'GitHub (gh): authentication failed; PR/check data may be stale or unavailable'
        snapshot = fmt.assemble([{'kind': 'meta', 'forge_warnings': [warning]}])
        self.assertEqual([warning], snapshot['forge_warnings'])
        self.assertIn(warning, fmt.format_md(snapshot))
        shell = fmt.emit_bash_state(json.loads(json.dumps(snapshot)))
        result = subprocess.check_output(['bash', '-c', shell + '\nprintf "%s" "${FORGE_WARNINGS[0]}"'], text=True)
        self.assertEqual(warning, result)
unittest.main(argv=['health-tests'])
PY
assert_eq 0 "$?" "health and snapshot tests pass"

it "live and cached ANSI status show authentication failures"
ws="$(make_workspace)"
# Pin below native status support so all three calls exercise the shell path.
printf '0.1.8\n' > "$ws/main/harness/.wtc-cli-version"
mkdir -p "$ws/fake-bin"
cat > "$ws/fake-bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = api ]; then
  if [ "${HEALTH_OK:-no}" = yes ]; then printf '{"data":{"repository":{"pullRequests":{"nodes":[]}}}}\n'; exit 0; fi
  echo 'HTTP 401: private-error-detail' >&2
fi
exit 1
GH
chmod +x "$ws/fake-bin/gh"
out="$(PATH="$ws/fake-bin:$PATH" "$ws/main/harness/tools/wtc-status.sh" --repos --no-fetch --ansi main)"
assert_contains "$out" 'GitHub (gh): authentication failed'
assert_not_contains "$out" 'private-error-detail'
out="$(PATH="$ws/fake-bin:$PATH" "$ws/main/harness/tools/wtc-status.sh" --repos --cached --ansi main)"
assert_contains "$out" 'GitHub (gh): authentication failed'
out="$(HEALTH_OK=yes PATH="$ws/fake-bin:$PATH" "$ws/main/harness/tools/wtc-status.sh" --repos --no-fetch --ansi main)"
assert_not_contains "$out" 'authentication failed'
