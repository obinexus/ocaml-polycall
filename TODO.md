# TODO — ocaml-polycall

Status: OCaml binding of the Polycall binding ABI v1 (polycall >= 1.1.0).

- [x] C stubs over the real `<polycall.h>` (stub header of nonexistent symbols removed)
- [x] Link via `pkg-config polycall` (dune-configurator), POLYCALL_CFLAGS/POLYCALL_LIBS override
- [x] Legacy `run_config` / `run_config_or_error` kept; `check_config`, `describe`, `call`, `Peer`
- [x] `Polycall_error` with status, `polycall_strerror` name and `polycall_last_error` detail
- [x] Blocking calls release the runtime lock (threads and OCaml 5 domains)
- [x] Tests against the real library and `polycall` CLI, incl. daemon and C CLI interop
- [x] Loader failures (no library, 1.0 library, ABI 2) fail cleanly
- [x] valgrind, AddressSanitizer and ThreadSanitizer runs; opam install + consumer project
- [ ] Windows: build and test with an OCaml for Windows toolchain (MinGW-w64 /
      MSYS2 UCRT64 + dune + dune-configurator) against libpolycall.dll —
      blocked on the QA host (no OCaml toolchain)
- [ ] macOS run — not tested
- [ ] Publish to opam / npm (never done by QA)
