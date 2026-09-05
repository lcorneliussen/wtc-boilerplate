# Publication guard

Configure the repository Actions secret `PUBLICATION_FORBIDDEN_TERMS` with one
literal term per line. Blank lines are ignored; matching uses Unicode NFKC
normalization and case folding. Keep real terms exclusively in the secret.
Never add them to fixtures, command arguments, documentation or PR discussions.
Set the secret using `gh secret set PUBLICATION_FORBIDDEN_TERMS` and private stdin.

The workflow runs trusted default-branch scanner code. PR data arrives through
the read-only GitHub API and is never executed. It scans current PR title/body,
branch name, commit messages, changed non-deleted file names and complete blobs,
and current comments/reviews. Issue and comment/review events scan their event
text. Manual dispatch rescans a specified PR. Removed files and old filenames
are excluded to allow cleanup; historical commit messages still count.

Missing configuration, API failures, large responses, endpoint caps and a PR
head changing during inspection fail closed with a generic message. Findings
also produce only a generic failure: no matched terms, snippets, filenames,
counts, artifacts or annotations. Maintainers must investigate privately.
The pass/fail result itself can reveal whether a guessed term matched; this is
a detection mechanism, not a way to keep dictionary membership unobservable.

This is post-publication detection, not pre-publication prevention. It cannot
remove public content, notifications or history. It does not OCR images, unpack
archives, decode arbitrary encodings or inspect external links/attachments.
Comments have separate event runs and do not update a PR head's required check.
No automatic comments, edits, branch protection changes or merges are performed.
Manual audience review remains necessary before every external write.

Activation requires this workflow and scanner to land on the default branch;
the introducing PR cannot exercise the secret-backed workflow beforehand.
Run the synthetic tests with `tests/run.sh publication_guard`. After merge,
configure the secret, dispatch against a clean PR and verify the workflow result.
Use only synthetic terms and a disposable test repository for failure probes.

Security model: [GitHub's pull_request_target guidance](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target).
