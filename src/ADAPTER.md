# Adapter boundary

`polycall.ml` calls one OCaml runtime stub. The runtime stub obtains the OCaml
string with `String_val`, and `ocaml_polycall_run_config()` makes exactly one
call to `polycall_ffi_run_config(config_path, 1)`. The core status is returned
unchanged.

No layer here parses configuration or duplicates libpolycall runtime behavior.
