#!/bin/bash
# Run the corpus (quirk/quirk-compiler/tests/*.quirk) through
# bin/quirk-selfhost and classify each test by where it stops:
#
#   emit   selfhost failed to produce IR
#   llc    IR rejected by llc-14 (invalid LLVM)
#   link   unresolved symbols at link time
#   crash  binary died on a signal (SIGSEGV / SIGABRT / ...) or timed out
#   exit   ran to completion, exit status != 0
#   differ ran cleanly but output differs from bin/quirk-cpp
#   match  output identical to bin/quirk-cpp
#
# "clean exits" (exit-0 runs: differ + match) is the metric the README's
# 40/60 used; "match" is the stricter correctness measure.
#
# Usage: tools/corpus.sh [-v] [test-name-substring]
#   -v   print the first lines of each non-match result
# Env:   QUIRK_DIR (default ../quirk/quirk-compiler)

set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
QUIRK_DIR=$(cd "${QUIRK_DIR:-$HERE/../quirk/quirk-compiler}" && pwd)
SELFHOST="$HERE/bin/quirk-selfhost"
SHIM="$HERE/bin/selfhost_shim.so"
CPP="$QUIRK_DIR/bin/quirk-cpp"
RUNTIME="$QUIRK_DIR/bin/runtime.so"
WORK="$HERE/build/corpus"
export QUIRK_HOME="$QUIRK_DIR"

verbose=0
[ "${1:-}" = "-v" ] && { verbose=1; shift; }
filter="${1:-}"

mkdir -p "$WORK"
declare -A count
results=()

cd "$QUIRK_DIR"   # tests use paths relative to the compiler dir
for t in tests/*.quirk; do
    name=$(basename "$t" .quirk)
    [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue
    # Network fixtures need a live server; not meaningful here.
    case "$name" in http_client_test|server_test) continue ;; esac

    ll="$WORK/$name.ll"; s="$WORK/$name.s"; bin="$WORK/$name"
    detail=""
    if ! timeout 30 "$SELFHOST" "$t" "$ll" > "$WORK/$name.emit.log" 2>&1 || [ ! -s "$ll" ]; then
        status=emit; detail=$(head -3 "$WORK/$name.emit.log")
    elif ! llc-14 -relocation-model=pic "$ll" -o "$s" 2> "$WORK/$name.llc.log"; then
        status=llc; detail=$(head -3 "$WORK/$name.llc.log")
    elif ! clang-14 -pie "$s" "$RUNTIME" "$SHIM" -lm -ldl -o "$bin" \
            -Wl,-rpath,"$(dirname "$RUNTIME")" -Wl,-rpath,"$(dirname "$SHIM")" \
            2> "$WORK/$name.link.log"; then
        status=link; detail=$(grep -m3 "undefined reference" "$WORK/$name.link.log")
    else
        timeout 10 "$bin" > "$WORK/$name.out" 2>&1 < /dev/null
        rc=$?
        if [ $rc -ge 124 ]; then
            status=crash; detail="rc=$rc; $(tail -2 "$WORK/$name.out")"
        elif [ $rc -ne 0 ]; then
            status=exit; detail="rc=$rc; $(tail -2 "$WORK/$name.out")"
        else
            timeout 30 "$CPP" run --no-aot --no-cache "$t" > "$WORK/$name.expected" 2>&1 < /dev/null
            if cmp -s "$WORK/$name.out" "$WORK/$name.expected"; then
                status=match
            else
                status=differ
                detail=$(diff "$WORK/$name.expected" "$WORK/$name.out" | head -4)
            fi
        fi
    fi
    count[$status]=$(( ${count[$status]:-0} + 1 ))
    results+=("$status $name")
    printf '%-7s %s\n' "$status" "$name"
    if [ $verbose -eq 1 ] && [ "$status" != match ] && [ -n "$detail" ]; then
        printf '%s\n' "$detail" | sed 's/^/          /'
    fi
done

total=${#results[@]}
clean=$(( ${count[match]:-0} + ${count[differ]:-0} ))
echo
echo "corpus: $total tests"
for k in match differ exit crash link llc emit; do
    printf '  %-7s %3d\n' "$k" "${count[$k]:-0}"
done
echo "  clean exits: $clean/$total   output matches quirk-cpp: ${count[match]:-0}/$total"
