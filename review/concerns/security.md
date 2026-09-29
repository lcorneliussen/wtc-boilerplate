---
id: security
title: Security
tier: strong
applies: "*auth* *Auth* *login* *session* *token* *secret* *Secret* *credential* *password* *permission* *iam* *policy* *cors* *middleware* .env* *.pem *.key Dockerfile* *.dockerfile docker-compose* *.sh *deploy* *publish* *pipeline* *pipelines* **/auth/** **/deploy/** **/security/** .github/** .gitlab-ci* .circleci/** *.tf *.tfvars requirements*.txt package.json pyproject.toml go.mod"
---
Does the change weaken authentication, authorization, secret handling, or the
build/deploy chain?

Check:

- secrets: committed keys, tokens, passwords, connection strings, private
  keys — also in tests, fixtures, examples, logs, and `diff.patch` context
- credentials printed, logged, echoed in CI, or baked into images/layers
- authn/authz: endpoints or jobs that lose a check, broadened roles/scopes,
  default-allow, CORS widened, trust of client-supplied identity
- injection: SQL/shell/template built from untrusted input, unsafe
  deserialization, path traversal
- CI/CD and containers: unpinned or untrusted images/actions, `curl | sh`,
  running as root without need, secrets exposed to untrusted branches,
  deploy targets reachable from feature branches
- data exposure: new exports or endpoints that move personal or restricted data
  to a wider audience

Severities:

- **blocker** — a live secret in the diff or history, an auth bypass, an
  injection reachable from untrusted input, or a deploy path that lets
  unreviewed code reach production
- **major** — a weakened control with a plausible exploit or leak path
- **minor** — hardening gap with no present exploit path
- **nit** — do not use for this concern
