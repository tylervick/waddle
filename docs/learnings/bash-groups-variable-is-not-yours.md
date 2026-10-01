# `GROUPS` is bash's, not yours: an assignment to it is silently ignored

bash pre-defines a handful of upper-case variables with meanings of their
own. `GROUPS` is an array of the current user's group ids, and assigning to
it is a no-op: `GROUPS="$(curl …)"` leaves `$GROUPS` expanding to the first
group id (an integer), with no error and no warning, in bash 3.2 and bash 5
alike. `set -u` does not help, because the variable is set.

Measured 2026-09-30 while writing `Scripts/promote-build.sh`: the response
of the beta-groups call was assigned to `GROUPS`, the next line parsed
`$GROUPS` as JSON, and the suite failed with

```
AttributeError: 'int' object has no attribute 'get'
error: unparseable betaGroups response
```

which reads as a bad response from App Store Connect, not as a variable
that was never written. Renaming it to `GROUP_RESP` fixed it.

Others in the same family that look like ordinary names: `UID`, `EUID`,
`PPID`, `HOSTNAME`, `OSTYPE`, `MACHTYPE`, `SECONDS`, `RANDOM`, `LINENO`,
`SHELLOPTS`, `BASHPID`, `COLUMNS`, `LINES`, `OPTARG`, `OPTIND`, `REPLY`,
`PIPESTATUS`, and `PATH` (in zsh the lower-case `path` array is bound to it,
so a loop variable named `path` clobbers PATH). Some are read-only and fail loudly;
`GROUPS`, `COLUMNS`, `LINES` and `SECONDS` do not. A script-local variable
that names a *list of things* is where this bites, so prefer a suffix
(`GROUP_RESP`, `BUILD_LIST`) over the bare plural.

`bash -n` cannot see it. The hermetic suite did, because its fixture was a
JSON array and the parse of an integer failed; a suite whose stub returned
something a bare integer could pass as would not have.
