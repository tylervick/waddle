# A developer-only tool pinned in `[tools]` is a CI dependency on its vendor

`Scripts/check-mise-tools-registry.sh` refuses the shape; this file records
why it exists.

`mise.toml` pinned the Blink review CLI through mise's `http` backend, with
content-addressed download URLs on the vendor's own CDN. The pin was
documented as optional and per-developer, and it was: nothing on a CI runner
ever ran `blink`. But `mise install` does not know which tools a job will use.
It installs every entry in `[tools]`, so the pin made every CI run depend on
`blink.review` answering.

In late October 2026 that host stopped resolving in DNS. From then on every
run that missed the mise cache failed at "Install pinned CLI tools", before a
single test ran: PR #331 from 2026-10-27, and `main` itself at the #330 merge
on 2026-11-06. Runs that hit the cache for an older `mise.toml` hash stayed
green, so the break was invisible until an unrelated cmake bump changed the
hash. The graphghan repo had excluded the tool on runners with
`MISE_DISABLE_TOOLS` from the start, and the same pin cost it nothing.

Two rules follow. The check enforces the first mechanically; the second is
a judgement it cannot make, so it is for the reviewer of any `[tools]`
change:

- A tool in `[tools]` must come from a registry the build already trusts
  (the mise registry, or an `aqua:`/`ubi:`/`github:` pin served from GitHub).
  No `http:` backend, no `url =` under a tools table.
- A tool nobody needs on a runner does not belong in `[tools]` at all. Give
  it a task, or leave it to each developer's own mise config.

The second half of the lesson is about reading CI: a green run that restored
a tool cache has not proved the toolchain installs. Before trusting a verdict
on a change to `mise.toml` or the setup action, check that the run actually
installed the tools.
