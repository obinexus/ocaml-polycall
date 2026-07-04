let default_config = "ocaml-polycallrc"

exception Error of int

external run_config_raw : string -> int = "caml_ocaml_polycall_run_config"

let run_config ?(config_path = default_config) () =
  run_config_raw config_path

let run_config_or_error ?(config_path = default_config) () =
  match run_config_raw config_path with
  | 0 -> ()
  | status -> raise (Error status)
