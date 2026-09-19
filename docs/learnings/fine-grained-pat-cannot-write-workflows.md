# A fine-grained PAT needs "Workflows" to touch `.github/workflows/`

Committing any change under `.github/workflows/` with a fine-grained personal
access token fails unless that token carries **Workflows: Read and write**. The
error names neither the permission nor the path:

```
GraphQL: Resource not accessible by personal access token
```

The same restriction applies to `git push`, so switching transport does not
route around it. What makes it confusing is that the *same token* had just
written several commits successfully — the difference was that none of them
touched a workflow file. A token that works all session can fail on one commit
for a reason specific to one directory.

Fix it at github.com/settings/personal-access-tokens → the token → Repository
permissions → Workflows → Read and write. An organization-owned token may need
an administrator to approve the change before it takes effect.

Neighbouring permissions fail the same opaque way, so recognise the shape
rather than the message:

| Action | Permission | Symptom without it |
| --- | --- | --- |
| Commit under `.github/workflows/` | Workflows: write | `Resource not accessible by personal access token` |
| `gh secret list` | Secrets: read | `HTTP 403: Resource not accessible by personal access token` |
| `gh api .../branches/main/protection` | Administration: read | `HTTP 403: Resource not accessible by personal access token` |

Reach for `gh auth status` first: a token printed as `github_pat_…` is
fine-grained and governed by this per-resource model, whereas a classic
`ghp_…` token carries coarse scopes (`repo`, `workflow`) and fails differently.

**Paid for on 2026-09-18**, opening #227, which was the first pull request in
this sequence to modify `ci.yml`.

Related: [signing-commits-without-a-local-key.md](signing-commits-without-a-local-key.md)
covers the other API-side obstacle met the same day.
