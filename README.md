# ocaml-polycall

OCaml binding for the [Polycall](https://github.com/obinexus/polycall) core
library, **binding ABI v1** (`polycall.h`, documented in the core's
`docs/BINDING_ABI.md`). Also distributed as the npm source package
`ocaml-polycall`.

The binding is a set of C stubs (`src/ocaml_polycall_stubs.c`) compiled by
dune and linked against libpolycall through `pkg-config polycall`. It adds no
configuration parser, no protocol code and no network code: every operation is
one call into the core.

## Requirements

- OCaml >= 4.14 (OCaml 5 adds the domain tests), dune >= 3.9,
  `dune-configurator`, `pkg-config`
- libpolycall >= 1.1.0 (binding ABI 1) with its `polycall.pc`, e.g. built and
  installed from https://github.com/obinexus/polycall
  (`cmake -S . -B build && cmake --build build && cmake --install build`)
- at run time the dynamic loader must find `libpolycall.so.1`
  (`LD_LIBRARY_PATH`, `ldconfig`, or an rpath)

If pkg-config cannot be used, set both `POLYCALL_CFLAGS` and `POLYCALL_LIBS`
(e.g. `-I/opt/polycall/include/polycall` and `-L/opt/polycall/lib -lpolycall`).

## Build and install

```sh
export PKG_CONFIG_PATH=/opt/polycall/lib/pkgconfig   # where polycall.pc lives
dune build                      # library, example, tests
opam install .                  # or: opam pin add ocaml-polycall <git url>
```

`ocaml-polycall.opam` is generated from `dune-project`. Nothing here is
published to opam or npm automatically.

## API (`Polycall`, see [`src/polycall.mli`](src/polycall.mli))

```ocaml
Polycall.abi_version ()            (* 1; checked when the module initialises *)
Polycall.version ()                (* "1.1.0" *)
Polycall.run_config ~config_path:"ocaml-polycallrc" ()
                                   (* legacy: polycall_ffi_run_config(path, 1), raw status *)
Polycall.check_config path         (* strict; ~strict:false = validate only; raises *)
Polycall.describe path             (* JSON description of a config file *)
Polycall.call ~endpoint:"127.0.0.1:7000" ~service:"inventory" ~operation:"get"
  ~input_json:{|{"item_id":"widget-a"}|} ()

let a = Polycall.Peer.create ~token "alpha"          (* 127.0.0.1:0 = ephemeral *)
and b = Polycall.Peer.create ~token "beta" in
Polycall.Peer.register a "beta" (Polycall.Peer.endpoint b);
Polycall.Peer.send ~message_id:"m-1" a "beta" "payload bytes";
let m = Polycall.Peer.recv ~timeout_ms:5000 b in     (* m.sender, m.message_id, m.payload *)
Polycall.Peer.close a; Polycall.Peer.close b
```

`Peer` covers create (listening or send-only) / close / endpoint / node_id /
register / unregister / list / ping / send / recv / cancel / health. Payloads
are OCaml strings used as byte buffers (binary-safe, up to 1 MiB).

Errors raise `Polycall.Polycall_error { code; name; detail; info }`: the
negative status, its `polycall_strerror` name, the `polycall_last_error`
detail of the failing call (read on the same thread) and, for `call`, the
remote error object (`info`). The legacy `run_config_or_error` raises
`Polycall.Error status`.

**Threads and domains.** Every call that can block (config, call, open,
close, ping, send, recv) copies its arguments out of the OCaml heap and
releases the runtime lock (OCaml 4.14 master lock / OCaml 5 domain lock)
while it waits, so other threads keep running, other domains' collections
are not held up, and `Peer.cancel` / `Peer.close` from another thread or
domain wake a blocked `recv`.

**Ownership.** The library never returns memory to free. A `Peer.t` is closed
by `Peer.close` or, if forgotten, by a GC finaliser; calls on a closed peer
(including a second `close`) raise `Polycall_error` with
`Status.invalid_handle`, never crash.

## Loading and version checks

This is a link-time binding: executables record `libpolycall.so.1` as a
dependency. A missing library or an old 1.0 library without the ABI v1
symbols makes the dynamic loader stop the program before `main` with a
message naming the library or the missing `polycall_*` symbol; a library
reporting a binding ABI other than 1 is refused when the `Polycall` module
initialises (`Failure "libpolycall X reports binding ABI N; ocaml-polycall
requires ABI 1"`). `tests/load_errors.sh` checks all three.

## Tests

```sh
sh scripts/test-linux.sh   # dune build + dune test + adapter + loader errors + example
make test-valgrind         # test executables under valgrind memcheck
make test-asan             # test executables with AddressSanitizer C stubs
make test-tsan             # ThreadSanitizer (switch with ocaml-option-tsan)
sh scripts/test-package.sh # opam install of this checkout + a clean consumer project
```

The sanitizer targets disable ASLR with `setarch -R` when the system allows
it: on kernels with `vm.mmap_rnd_bits=32` the sanitizer runtimes of GCC <= 12
otherwise fail at start-up at random (inside Docker this needs a seccomp
profile that permits `personality`, e.g. `--security-opt seccomp=unconfined`).

`test/test_polycall.ml` runs against the real library and the real `polycall`
CLI (`POLYCALL_CLI` or `PATH`) and covers the BINDING_ABI.md checklist:
version/ABI, run_config (valid, missing, invalid, strict, TLS, non-ASCII
path), `call` against `polycall start` and `polycall daemon start` (success,
unknown operation, remote error, deadline, invalid input and timeout bounds,
no runtime, concurrent calls), two nodes exchanging empty / UTF-8 /
binary / 1 MiB / 1 MiB + 1 payloads both ways, registry ownership,
duplicates, auth, dead peer, receive timeout, too-small buffer, cancel and
close waking a blocked receive, the runtime-lock release, double close and
use after close, the finaliser, concurrent senders, and interop with
`polycall peer serve` / `send` / `recv` / `register` in both directions.
`test/test_domains.ml` (OCaml 5) repeats the concurrency checks from
parallel domains. With `POLYCALL_INTEROP_ECHO` set to another binding's echo
agent (e.g. `dotnet fsharp-polycall.dll`) the suite also exchanges payloads
with that binding; `examples/peer_echo.exe peer echo --node-id ID ...` is
this binding's own agent for the other bindings' tests. Checks that cannot run print `SKIP` and never count as
passes; `scripts/test-linux.sh` exits 77 when dune or libpolycall is missing.

`tests/ocaml_polycall_adapter_test.c` is a clearly-labelled adapter unit test
against a MOCK of `polycall_ffi_run_config` (`tests/polycall_ffi_mock.c`);
`tests/fixtures/fake_polycall.c` builds fake libraries for the loader tests
only.

## Platforms

| Platform | Status |
| --- | --- |
| Linux x86_64 | tested (Debian 12, OCaml 5.2, against libpolycall built from source) |
| Windows x64 | intended: an OCaml for Windows toolchain (MinGW-w64 / MSYS2 UCRT64) with dune and pkg-config, linking `libpolycall.dll` via its `polycall.pc`. **Not yet tested** — no OCaml toolchain was available on the QA Windows host |
| macOS | not tested |

## npm source package

`npm pack` produces `ocaml-polycall` with the OCaml/C sources,
dune files, tests and configuration (no binaries). Requiring it from Node
only indexes those files (`index.js`); build it with dune as above.

## Author and license

Nnamdi Michael Okpala (`okpalan@protonmail.com`). MIT, see [LICENSE](LICENSE).
