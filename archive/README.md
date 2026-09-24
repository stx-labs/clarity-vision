# Archive: legacy Stacks track

These documents cover running Clarity 1–6 on today's Stacks chain: extracting
the interpreter from stacks-core behind a stable kernel, pinning engine
revisions to epochs, and classifying consensus gates. That work continues on
its own track.

None of it applies to the new Clarity design in the parent directory. The new
chain executes Wasm, and legacy contracts keep running on the interpreter
under separate rules.

| Document | Content |
|---|---|
| [kernel-architecture.md](kernel-architecture.md) | Kernel plus frozen per-version engine crates, epoch pinning, the interop boundary |
| [extraction-plan.md](extraction-plan.md) | File-level extraction plan and status log |
| [consensus-gates.md](consensus-gates.md) | Language-version, engine-revision, kernel-ruleset, and host epoch gates |
| [demo/](demo/) | Interactive walkthrough of the extraction |
