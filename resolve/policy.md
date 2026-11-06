# Policy

Rules that apply to every package `resolve` acts on. A package's own `CLAUDE.md` and design documents take precedence over this file where they conflict.

## Libraries and applications

A package is a library if it has `.github/workflows/lean_bump_notify.yml`, and an application otherwise. A library is released after its bump PR is merged. An application is merged and not released, so it gets no changelog entry and no tag.

## Versions

Versions follow semantic versioning, read from the latest release tag (`v1.2.3` or `1.2.3`; use the same form for the next one).

| | Breaking | Not breaking |
|---|---|---|
| Before 1.0 | minor (0.13.0 → 0.14.0) | patch (0.3.0 → 0.3.1) |
| From 1.0 | major (1.4.2 → 2.0.0) | minor (1.4.2 → 1.5.0) |

A change is breaking if code that builds against the previous release could fail to build, or behave differently, against this one. That includes:

- a public declaration removed, renamed or moved to another module, or its type, statement, implicit or instance arguments changed;
- an instance added, removed or changed, or a change to which lemmas are `simp`;
- a module removed or renamed;
- a change to `lean-toolchain`, since every consumer has to move to the same toolchain;
- a dependency moved to a release that was itself breaking (its changelog says so), when this package's public declarations mention that dependency's types or its modules re-export it.

Changes confined to proofs, private declarations, tests and documentation are not breaking.

## Release changes

A release changes `CHANGELOG.md` and, if the lakefile (`lakefile.lean` or `lakefile.toml`) declares the package's `version`, that line, set to the new version. Nothing else.

## Changelog

`CHANGELOG.md` lists releases newest first under `# Changelog`. Each entry has a heading `## [x.y.z] - YYYY-MM-DD`, with the date the entry is written in UTC, followed by one bullet per change, written for someone who uses the package:

- prefix each breaking change with `Breaking:`, and say what to use in its place;
- a release whose only change is the bump itself is `* Chore: bump dependencies`, followed by a bullet for a toolchain change, if any.

Match the wording and level of detail of the entries already there.

## Fixes

A fix is **mechanical** when there is one obvious way to make it: following a rename, adapting to a changed signature, repairing a proof, threading a new argument through. A mechanical fix may well change this package's own public API; that is expected, and makes the release breaking.

A fix needs a **decision** when there is more than one reasonable way to make it and the choice has consequences the package's documents do not settle: what the public API should look like, whether to keep a feature that upstream has made awkward, accepting a performance or proof-strength cost, working around a suspected upstream bug. When in doubt, it is a decision.

While making a fix:

- Match the surrounding code's style, naming, comment density and copyright headers.
- Before a package reaches 1.0, correctness trumps compatibility: remove or change what is wrong rather than add deprecated aliases or shims.
- A module that embeds a file with `include_str` needs that file declared as a Lake `input_file` or `input_dir` and listed in the library's `needs`, with `text := true` for text. Without it, editing the file rebuilds nothing.
- Every statement in a Postgres up-migration must be idempotent (`ADD COLUMN IF NOT EXISTS` included). A down file must undo column additions as well as dropping what it created. Never change a migration that has shipped; add a new one.
- Never edit anything under `.github/`.
