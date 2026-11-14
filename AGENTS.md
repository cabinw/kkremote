# KKRemote collaboration

## Stage completion and Git

- The user has authorized committing and pushing each completed, verified stage to the current task branch. Do this as part of completion rather than leaving changes accumulated in the working tree.
- Group commits by module or purpose. Name the change and relevant validation in the commit message; distinguish completed verification from deferred hardware or long-run checks.
- Inspect the index before committing. In this shared workspace, coordinate with other active development chats and stage explicit paths or reviewed hunks; do not use `git add .` or `git add -A`.
- `overlay-test/` is maintained and committed by other active agents; exclude it from communication/client checkpoints unless the user explicitly reassigns it. Use an isolated worktree when other agents are also committing.
- Preserve other contributors' work. Do not reset, discard, rewrite published history, force-push, or merge into `main` as part of routine stage completion.
- After pushing, verify the remote branch SHA matches local HEAD. Include the branch and commit summary in the handoff.

## Publication boundaries

- Never commit pairing codes, signing credentials, private keys, access tokens, provisioning profiles or device/account identifiers. Keep machine-specific connection and signing settings in ignored `Config/*.local.xcconfig` files; use placeholders in examples.
- Keep `.build`, build products, raw traces, device containers, crash bundles and local research captures ignored. Curated synthetic test images and sanitized measurement summaries under `docs/testing/data` may be committed after inspection.
- Check all staged paths and content before publishing, including generated projects, reports and image attachments. Do not print secret values while auditing.
- Keep reproducible test sources and document how to regenerate local artifacts. Do not treat an installed USB/TestFlight build as a Git backup.

## Responsibility and validation

- Communication work owns capture, codecs, transport, telemetry and host window lifecycle. The iOS chat owns client interaction; coordinate shared interfaces and files.
- Run checks appropriate to changed modules. Publishing a previously verified stage does not itself require restarting the phone, Host, virtual display or long-running media tests.
- Keep original endpoint and pairing settings unchanged unless the user asks to change them. Report experimental virtual-display and deferred stability limitations accurately.
