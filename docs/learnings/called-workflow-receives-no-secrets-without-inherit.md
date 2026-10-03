# A called workflow receives no secrets unless the caller passes them, even when its job declares the environment that holds them

The first on-merge TestFlight release (CI run 37060983966, the merge of
PR #317) reached the signing step with every secret set to the empty string
and failed with:

```
security: SecKeychainItemImport: One or more parameters passed to a function were not valid.
```

The deployment to the `app-store` environment *was* recorded for that job,
which is what made the failure confusing: the environment had applied, its
branch rule had passed, and the called job's `environment: app-store` was
exactly what GitHub's docs say makes environment secrets "the ones used".
What the docs mean is narrower. The environment decides which **values** the
names `secrets.X` resolve to. Whether those names reach the called run at
all is the **caller's** decision, made with `secrets: inherit` or a named
`secrets:` map on the calling job, and the caller had passed none.

The check is `Scripts/check-called-workflow-secrets.sh`: for every job that
calls a workflow in this repository, if the called workflow reads
`${{ secrets.* }}`, the calling job must have a `secrets:` key. Its suite
pins the incident shape and, by stripping the line from a copy of the real
tree, proves the live assertion is not vacuous.

Why `inherit` and not a named list here: the names are the called
workflow's business, and the environment's deployment rule, not the list, is
what keeps the values from a branch. A named list would be a second copy of
the same names that drifts when one is renamed.
