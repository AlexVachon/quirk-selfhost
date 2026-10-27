# quirk-selfhost

A Quirk-in-Quirk compiler. Compiles a working subset of the [Quirk
language](https://github.com/AlexVachon/quirk) to LLVM IR — written
in Quirk itself.

## What this is

- **Bootstrap proof.** `bin/quirk-selfhost` compiles its own source
  to byte-identical IR under itself. The language is complete enough
  to describe its own compiler. Verify with `make fixedpoint`.
- **Working subset compiler.** 40 of the production compiler's 58
  corpus tests run to completion; 28 produce output identical to
  `quirk-cpp` (see [Coverage](#coverage) below).
- **Milestone artifact.** Split out from the main `quirk` repo at
  compiler v5.2.0. Reached its current milestone at
  [`ef857b8`](https://github.com/AlexVachon/quirk/commit/ef857b8)
  (published as `v5.0.0-alpha.43` before the alpha series was closed).

## Why it lives in its own repo

The selfhost push was an ambitious project that produced a real
result: byte-identical bootstrap. Now that it's frozen as a
subset compiler, keeping ~13k lines of code coupled to the main compiler's
release cycle has costs (feature parity taxes, doc asterisks, CI
routing bugs) that outweigh the benefits of same-repo colocation.

The bootstrap proof is *stronger* as a separately-checkable
artifact than as a dormant subtree of the main compiler. Anyone can
clone this repo, run `make fixedpoint`, and confirm the result.

## Build

Requires:
- A working `bin/quirk-cpp` (the C++ compiler) from
  `github.com/AlexVachon/quirk`
- `bin/runtime.so` from the same
- `llc-14` and `clang-14` on `PATH`

```bash
# Sibling-checkout layout (standard)
git clone https://github.com/AlexVachon/quirk.git
git clone https://github.com/AlexVachon/quirk-selfhost.git
cd quirk/quirk-compiler && make bootstrap-stdlib && make -j"$(nproc)"
cd ../../quirk-selfhost && make               # bin/quirk-selfhost
make fixedpoint                                # verifies byte-identical bootstrap
```

Or point at a specific checkout:

```bash
make QUIRK_DIR=/path/to/quirk/quirk-compiler
# or
make QUIRK=/path/to/bin/quirk-cpp RUNTIME=/path/to/runtime.so
```

## Fixed-point verification

`make fixedpoint` runs the following chain:

```
bin/quirk-cpp        compiles selfhost/quirk_main.quirk → ir0.ll
ir0.ll → toolchain                                     → bin/quirk-selfhost
bin/quirk-selfhost   compiles selfhost/quirk_main.quirk → ir1.ll
ir1.ll → toolchain                                     → quirk-selfhost-v2
quirk-selfhost-v2    compiles selfhost/quirk_main.quirk → ir2.ll
```

Then it `diff`s `ir1.ll` against `ir2.ll`. When they match
byte-for-byte, the compiler has reached a fixed point: further
self-compilation produces the same output. That's the canonical
proof of self-hosting completeness.

(Note: ir0 and ir1 do *not* need to match — the C++ compiler and the
Quirk-side compiler emit different label manglings and comments even
for the same semantics. The real fixed-point criterion is
selfhost-vs-selfhost.)

## Layout

```
selfhost/
├── quirk_main.quirk      entry point (arg parsing, phase orchestration)
├── build.quirk           the four-phase pipeline glue
├── lexer.quirk           source → tokens
├── tokens.quirk          token types
├── parser.quirk          tokens → AST
├── ast.quirk             AST node definitions
├── sema.quirk            AST → typed AST
├── types.quirk           Ty representation for the type checker
├── codegen.quirk         typed AST → LLVM IR text
├── quirk-driver.sh       driver shell script (compile + link + run)
├── codegen_e2e.sh        end-to-end codegen probes
└── *_test.quirk          per-phase unit tests

src/
└── selfhost_aliases.c    C forwarding stubs from selfhost's
                          unmangled names to runtime.so's mangled ones
```

## Coverage

Run `tools/corpus.sh` (add `-v` for failure details) to measure against
the sibling quirk checkout's `quirk-compiler/tests/*.quirk`. It reports
where each test stops — `emit` / `llc` / `link` / `crash` / `exit` — and,
for tests that run, whether the output matches `bin/quirk-cpp`.

Against quirk v6.1.1 (58 tests):

| | |
|---|---|
| Clean exits (ran to completion, exit 0) | **40 / 58** |
| Output identical to `quirk-cpp` | **28 / 58** |

The old "40/60" figure counted clean exits only, against the v5.1 corpus.
Recompiled against the current stdlib, it had decayed to 12 clean exits
and 6 matches, mainly because the selfhost parser didn't know the
`extern { ... }` blocks typing uses since v5.1.

What the remaining tests need:

- **Value shape tagging.** A `String` is either a raw C string or a
  runtime `String*`, and lists / maps use selfhost's own layouts
  (`%QListP`, `%QMap`). Calls into the runtime (JSON, `String.encode`,
  `List.str()` ...) can't tell which shape they got. This is behind
  most crashes and most wrong output (`<list>` placeholders, numbers
  printed for map values).
- Closure capture (lambda block bodies referencing outer scope)
- Distinguishable-null `Int?` / `Bool?` representation
- Decorators; package-qualified calls (`slug`, `File`); mixed
  top-level statements + definitions (no `main` synthesized)

Named arguments, parameter defaults and variadic `...rest` packing are
bound at call sites (functions, constructors, methods; variadic packing
for Quirk-defined functions only). `List.__set` and `b: Bool := xs[i]`
lower correctly.

## License

MIT — see [`LICENSE`](LICENSE).
