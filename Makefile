# ocaml-polycall -- OCaml C stubs over the Polycall binding ABI v1.
# libpolycall is found through `pkg-config polycall` (src/config/discover.ml;
# POLYCALL_CFLAGS + POLYCALL_LIBS override it).
#
#   make build          dune build (library, example, test executables)
#   make test           dune test against the REAL library (needs the
#                       polycall CLI for the RPC/interop checks); a missing
#                       toolchain is a SKIP (exit 77), never a pass
#   make test-adapter   C adapter unit test against a MOCK core (labelled)
#   make test-valgrind  the test executables under valgrind memcheck
#   make test-asan      the test executables with AddressSanitizer-instrumented
#                       C stubs (separate build dir _build_asan)
#   make test-tsan      the tests under ThreadSanitizer (needs an OCaml switch
#                       with ocaml-option-tsan; build dir _build_tsan)
#   make verify-dry     thin-adapter lint (no parsing/runtime logic here)

DUNE ?= dune
CC ?= cc
PKG_CONFIG ?= pkg-config
POLYCALL_CFLAGS_PC := $(shell $(PKG_CONFIG) --cflags polycall 2>/dev/null)
POLYCALL_LIBS_PC := $(shell $(PKG_CONFIG) --libs polycall 2>/dev/null)

.PHONY: all build
all: build
build:
	@command -v $(DUNE) >/dev/null 2>&1 || { echo "SKIP: dune not found" >&2; exit 77; }
	$(DUNE) build

.PHONY: test
test:
	@command -v $(DUNE) >/dev/null 2>&1 || { echo "SKIP: dune not found; OCaml tests did not run" >&2; exit 77; }
	$(DUNE) test --force

# Adapter unit test: src/ocaml_polycall.c against a MOCK of
# polycall_ffi_run_config (tests/polycall_ffi_mock.c). Not a core test.
.PHONY: test-adapter
test-adapter:
	@mkdir -p build
	$(CC) -std=c11 -Wall -Wextra -Iinclude -Itests $(POLYCALL_CFLAGS_PC) src/ocaml_polycall.c \
		tests/polycall_ffi_mock.c tests/ocaml_polycall_adapter_test.c -o build/ocaml_polycall_adapter_test
	./build/ocaml_polycall_adapter_test

# Memcheck errors and definite leaks fail the target. test/ocaml5-runtime.supp
# suppresses only two leaks inside the OCaml 5 runtime itself (domain
# teardown), see that file.
.PHONY: test-valgrind
test-valgrind: build
	@command -v valgrind >/dev/null 2>&1 || { echo "SKIP: valgrind not found" >&2; exit 77; }
	$(DUNE) build ./ocaml-polycallrc ./examples/ocaml-polycallrc   # the tests' file deps
	@set -e; cd _build/default/test; for t in test_polycall.exe test_domains.exe; do \
		if [ ! -x $$t ]; then echo "SKIP: $$t not built (test_domains needs OCaml >= 5)"; continue; fi; \
		echo "== valgrind $$t"; \
		valgrind --error-exitcode=99 --leak-check=full --errors-for-leak-kinds=definite \
			--track-origins=yes --suppressions=$(CURDIR)/test/ocaml5-runtime.supp ./$$t; \
	done

# AddressSanitizer on the C stubs (and on the core too when the libpolycall
# found by pkg-config was itself built with -fsanitize=address), run through
# dune in a separate build dir. Leak detection is off here (LeakSanitizer
# reports the OCaml runtime's own allocations); leaks are covered by
# test-valgrind. ASLR is disabled for the run when setarch allows it: with
# vm.mmap_rnd_bits=32 (recent kernels) the libasan of GCC <= 12 randomly
# loops on "AddressSanitizer:DEADLYSIGNAL" at start-up.
SETARCH_NORAND := $(shell setarch $$(uname -m) -R true >/dev/null 2>&1 && echo setarch $$(uname -m) -R)
.PHONY: test-asan
test-asan:
	@command -v $(DUNE) >/dev/null 2>&1 || { echo "SKIP: dune not found" >&2; exit 77; }
	@$(PKG_CONFIG) --exists polycall || { echo "SKIP: pkg-config polycall not found" >&2; exit 77; }
	@[ -n "$(SETARCH_NORAND)" ] || echo "warning: setarch -R is not permitted here; with vm.mmap_rnd_bits=32 the libasan of GCC <= 12 may loop at start-up" >&2
	ASAN_OPTIONS=detect_leaks=0:halt_on_error=1:exitcode=99 \
	POLYCALL_CFLAGS="$(POLYCALL_CFLAGS_PC) -fsanitize=address -fno-omit-frame-pointer -g" \
	POLYCALL_LIBS="$(POLYCALL_LIBS_PC) -fsanitize=address" \
		$(SETARCH_NORAND) $(DUNE) build --build-dir=_build_asan @runtest --force
	@nm _build_asan/default/src/libocaml_polycall_stubs.a | grep -q __asan_report \
		|| { echo "FAIL: the stubs were not built with AddressSanitizer" >&2; exit 1; }
	@echo "ASan: C stubs instrumented; test executables passed with no sanitizer report"

# ThreadSanitizer: needs an OCaml >= 5.2 switch built with ocaml-option-tsan
# (OCaml code, runtime and the C stubs are then all instrumented); the core
# is instrumented too when the libpolycall found by pkg-config was built with
# -fsanitize=thread. Any race report fails the run (exit code 66).
.PHONY: test-tsan
test-tsan:
	@command -v $(DUNE) >/dev/null 2>&1 || { echo "SKIP: dune not found" >&2; exit 77; }
	@$(SETARCH_NORAND) ocamlfind ocamlopt -config 2>/dev/null | grep -q '^tsan: true' \
		|| $(SETARCH_NORAND) ocamlopt -config 2>/dev/null | grep -q '^tsan: true' \
		|| { echo "SKIP: this OCaml switch is not built with ThreadSanitizer (ocaml-option-tsan)" >&2; exit 77; }
	@[ -n "$(SETARCH_NORAND)" ] || echo "warning: setarch -R is not permitted here; with vm.mmap_rnd_bits=32 TSan may refuse to start" >&2
	TSAN_OPTIONS="halt_on_error=0 exitcode=66" \
		$(SETARCH_NORAND) $(DUNE) build --build-dir=_build_tsan @runtest --force
	@nm _build_tsan/default/src/libocaml_polycall_stubs.a | grep -q __tsan_ \
		|| { echo "FAIL: the stubs were not built with ThreadSanitizer" >&2; exit 1; }
	@echo "TSan: C stubs instrumented; test executables passed with no race report"

.PHONY: verify-dry
verify-dry:
	sh scripts/verify-dry.sh

.PHONY: clean
clean:
	rm -rf _build _build_asan _build_tsan build lib
