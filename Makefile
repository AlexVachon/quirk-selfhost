# quirk-selfhost — Makefile
#
# Builds `bin/quirk-selfhost`, the Quirk-in-Quirk compiler, from
# selfhost/*.quirk. Requires:
#   • bin/quirk-cpp (the C++ compiler) from github.com/AlexVachon/quirk
#   • bin/runtime.so (the shared runtime) from the same
#   • llc-14 and clang-14 on PATH
#
# Point the build at your quirk checkout via one of:
#
#   make QUIRK_DIR=/path/to/quirk               # standard: sibling checkout
#   make QUIRK=/path/to/quirk-cpp RUNTIME=/path/to/runtime.so
#
# Or install `quirk-cpp` system-wide (via `install.sh` from the main
# repo) and this Makefile will find it on PATH automatically.
#
# Targets:
#   all           bin/quirk-selfhost (default)
#   fixedpoint    verify byte-identical bootstrap fixed point
#   clean         remove bin/ and build/

# ─── Configuration ──────────────────────────────────────────────────────────

# Sibling-checkout convention: `./` (this repo) and `../quirk/` are peers.
QUIRK_DIR ?= ../quirk/quirk-compiler
QUIRK     ?= $(QUIRK_DIR)/bin/quirk-cpp
RUNTIME   ?= $(QUIRK_DIR)/bin/runtime.so
# Linked libraries are recorded by the path given to the linker, so a
# relative RUNTIME made bin/quirk-selfhost loadable only from this repo's
# root. Link (and rpath) with absolute paths.
RUNTIME_ABS = $(abspath $(RUNTIME))

BIN_DIR   = bin
BUILD_DIR = build

# The C shim (selfhost_aliases.c) has to be compiled into `runtime.so`
# before linking, because selfhost's emitted IR references forwarding
# stubs like `__qsh_str_len` that dispatch to the runtime's mangled
# names. We build a small shim library rather than requiring users to
# rebuild runtime.so from source — one extra .so, cleanly separated.
SHIM_LIB = $(BIN_DIR)/selfhost_shim.so
SHIM_ABS = $(abspath $(SHIM_LIB))

SELFHOST_LL   = $(BUILD_DIR)/quirk_selfhost.ll
SELFHOST_S    = $(BUILD_DIR)/quirk_selfhost.s
SELFHOST_BIN  = $(BIN_DIR)/quirk-selfhost

# ─── Rules ──────────────────────────────────────────────────────────────────

all: $(SELFHOST_BIN)

$(BIN_DIR) $(BUILD_DIR):
	@mkdir -p $@

# Shim: forwarding stubs from selfhost's unmangled names to runtime.so's
# mangled ones (Sys_ansi, Math_pi, etc.). Compiled as a shared library
# so we don't have to relink runtime.so.
$(SHIM_LIB): src/selfhost_aliases.c | $(BIN_DIR)
	$(CC) -O2 -fPIC -shared -o $@ $< $(RUNTIME_ABS) \
		-I$(QUIRK_DIR)/src/Runtime \
		-Wl,-rpath,$(dir $(RUNTIME_ABS))

# Compile selfhost/*.quirk → IR text via the C++ compiler.
#
# `quirk-cpp` receives the entry file twice — once as the source and
# once as its own second positional arg — because the C++ compiler has
# a known wrapping bug where a String returned by `arg_get` reaches
# `write_file` as a String-of-String. Emitting to stdout and
# redirecting sidesteps the bug.
$(SELFHOST_LL): $(wildcard selfhost/*.quirk) | $(BUILD_DIR)
	$(QUIRK) --no-aot --no-cache selfhost/quirk_main.quirk \
		selfhost/quirk_main.quirk > $@ \
		|| (rm -f $@ && echo "selfhost IR emission failed" && exit 1)

$(SELFHOST_S): $(SELFHOST_LL)
	llc-14 $< -o $@

$(SELFHOST_BIN): $(SELFHOST_S) $(RUNTIME) $(SHIM_LIB) | $(BIN_DIR)
	clang-14 -no-pie $(SELFHOST_S) $(RUNTIME_ABS) $(SHIM_ABS) -lm -ldl -o $@ \
		-Wl,-rpath,$(dir $(RUNTIME_ABS))
	@echo ""
	@echo "  built: $(SELFHOST_BIN)"
	@echo "  size:  $$(stat -c%s $(SELFHOST_BIN)) bytes"

# ─── Fixed-point verification ──────────────────────────────────────────────
#
# Chain:
#   bin/quirk-cpp        compiles selfhost/quirk_main.quirk → ir0.ll
#   ir0.ll  + toolchain                                    → bin/quirk-selfhost
#   bin/quirk-selfhost   compiles selfhost/quirk_main.quirk → ir1.ll
#   ir1.ll  + toolchain                                    → build/quirk-selfhost-v2
#   quirk-selfhost-v2    compiles selfhost/quirk_main.quirk → ir2.ll
#
# Then ir1.ll and ir2.ll are diffed. When they're byte-identical, the
# compiler has reached a fixed point: further self-compilation
# produces the same output. ir0 vs ir1 aren't required to match — the
# C++ and Quirk implementations emit different string manglings and
# comments even for the same semantics.
FP_IR1 = $(BUILD_DIR)/quirk_selfhost_fp1.ll
FP_IR2 = $(BUILD_DIR)/quirk_selfhost_fp2.ll
FP_BIN = $(BUILD_DIR)/quirk-selfhost-v2

$(FP_IR1): $(SELFHOST_BIN)
	./$(SELFHOST_BIN) selfhost/quirk_main.quirk $@

$(FP_BIN): $(FP_IR1) $(RUNTIME) $(SHIM_LIB)
	llc-14 $< -o $(BUILD_DIR)/quirk_selfhost_fp1.s
	clang-14 -no-pie $(BUILD_DIR)/quirk_selfhost_fp1.s $(RUNTIME_ABS) $(SHIM_ABS) \
		-lm -ldl -o $@ -Wl,-rpath,$(dir $(RUNTIME_ABS))

$(FP_IR2): $(FP_BIN)
	./$(FP_BIN) selfhost/quirk_main.quirk $@

fixedpoint: $(FP_IR1) $(FP_IR2)
	@if diff -q $(FP_IR1) $(FP_IR2) > /dev/null; then                        \
	    echo "";                                                             \
	    echo "  bootstrap fixed point verified — byte-identical.";           \
	    echo "  ir1 = $$(wc -c < $(FP_IR1)) bytes";                          \
	    echo "  ir2 = $$(wc -c < $(FP_IR2)) bytes";                          \
	    echo "";                                                             \
	    echo "  bin/quirk-selfhost compiled itself, the resulting binary";   \
	    echo "  compiled itself again, and the two IRs match exactly.";      \
	    echo "";                                                             \
	else                                                                     \
	    echo "";                                                             \
	    echo "  ✗ fixed point NOT reached — ir1 and ir2 differ.";            \
	    diff -u $(FP_IR1) $(FP_IR2) | head -50;                              \
	    exit 1;                                                              \
	fi

clean:
	rm -rf $(BIN_DIR) $(BUILD_DIR)

.PHONY: all fixedpoint clean
