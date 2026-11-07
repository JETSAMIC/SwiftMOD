# Contributing to SwiftMOD

Thanks for the interest. This is a small, focused library — the bar is "ships clean, doesn't regress, stays minimal." Patches that match that bar are very welcome.

## Running the tests

```sh
swift test
```

The test target uses Swift Testing (the `import Testing` framework), not XCTest. Tests live in `Tests/SwiftMODTests/`. Add a test for any behavioral change — the suite is small enough that adding one or two cases is cheap and forces you to articulate intent.

```sh
swift build -c release -Xswiftc -warnings-as-errors   # must be warning-free
xcodebuild build -scheme SwiftMOD -destination 'generic/platform=iOS' -quiet
```

Behavioural changes to playback should cite the ProTracker behaviour they
implement and update `Reference/MOD-Format.md` and the spec-coverage table
in `README.md`.

## Commit style

Commits follow conventional commits in `action(noun): verb` form, lowercase, imperative mood:

```
feat(mixer): implement vibrato effect (4)
fix(parser): handle truncated pattern data without crashing
docs(readme): clarify AVAudioEngine bridge example
test(mixer): cover sample offset clamping at end of sample
refactor(parser): hoist period decoding into a helper
```

Keep the subject under ~72 characters. Use the body for the *why*. Group related changes in one commit; split unrelated changes across commits.

## Pull requests

For anything non-trivial — a new effect implementation, a parser change, a public API change — **open an issue first** so we can agree on shape and scope before you spend time on code. Typos, small doc fixes, and obvious bug fixes don't need an issue.

When opening a PR, ensure:

- `swift test` passes locally
- New public symbols have `///` doc comments
- No new dependencies (Foundation only, by design)
- The public API of `MODFile`, `MODMixer`, and `MODError` is unchanged unless explicitly discussed
- No code copied from LGPL/GPL sources (libxmp, OpenMPT, MikMod, Schism Tracker). Clean-room implementation against the public specs in [`Reference/MOD-Format.md`](Reference/MOD-Format.md) only.

## Code of conduct

Be kind. Disagree about code, not people. Maintainers reserve the right to close threads that go off the rails.
