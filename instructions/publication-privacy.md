# Publication privacy

Private project identities and adoption relationships stay private. A public
upstream contribution must stand on generic technical facts. Authorization to
contribute, follow a PR or ship a change does not authorize disclosing who uses
it or which private repositories consume it. Existing accidental disclosure is
not permission to repeat it.

Before every external write:

1. Establish the destination and audience. Treat unknown visibility as public
   until verified; authentication or write access does not imply privacy.
2. Inspect the exact outgoing title, body, reply, commit message, diff, attachment
   and tool payload against the private context available in the session. Remove
   identifying project/customer/org names, repo URLs and slugs, private issue/PR
   references, internal commit IDs, local paths, hostnames, logs and screenshots.
   Prefer synthetic examples. A keyword scan supplements this semantic check;
   it cannot prove that a payload is safe.
3. Keep cross-repository delivery links and adoption tracking in private records.
   Public upstream records contain only public upstream dependencies, technical
   evidence and generic follow-up requirements. A requirement to record durable
   state on the forge never requires publishing private context.
4. Pass this audience boundary to delegated agents before they can publish.
   Their reports and review replies require the same check as the main agent's.
5. Recheck after editing, composing or generating the final payload. Do not repeat
   identifying material in a cleanup explanation or privacy-rule example.

Use generic wording without asking for permission when it satisfies the task.
Only explicit user authorization for the particular identity and audience permits
an exception. If disclosure is essential and unauthorized, prepare a sanitized
result and ask about that specific remaining disclosure.

When an existing disclosure is discovered, correct editable public text and
verify the published result. Distinguish that repair from history removal:
older commits, edit revisions, notifications and third-party copies may remain.
Do not rewrite shared Git history as an incidental documentation cleanup.
