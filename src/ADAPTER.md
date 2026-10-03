# Adapter boundary

`polycall.ml` declares OCaml externals implemented by
`ocaml_polycall_stubs.c`; each stub copies its OCaml arguments into C memory,
makes exactly one call into the Binding ABI v1 surface of libpolycall
(`#include <polycall.h>`), and converts the result. The legacy entry point
`Polycall.run_config` reaches `ocaml_polycall_run_config()`
(`ocaml_polycall.c`), which is exactly `polycall_ffi_run_config(config_path, 1)`;
its status is returned unchanged.

No layer here parses configuration, speaks the peer protocol or opens
sockets: `scripts/verify-dry.sh` (and `.ps1`) check that the sources contain
no file/socket/parsing primitives.

Rules the stubs follow (from docs/BINDING_ABI.md):

- only C scalars, NUL-terminated UTF-8 strings, (pointer, length) buffers and
  int32 handles cross the boundary; OCaml strings with an embedded NUL are
  rejected with `Invalid_argument` before any allocation;
- outputs go to buffers the stub allocates and frees; nothing the library
  returns is freed;
- `polycall_last_error()` is read on the calling thread right after the
  failing call;
- blocking calls release the OCaml runtime lock (domain lock on OCaml 5)
  and touch the OCaml heap only after re-acquiring it.
