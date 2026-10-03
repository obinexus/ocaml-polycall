(* OCaml binding for the Polycall binding ABI v1 -- see polycall.mli. *)

type error = { code : int; name : string; detail : string; info : string option }

exception Polycall_error of error

let error_message e =
  if e.detail = "" then Printf.sprintf "%s (status %d)" e.name e.code
  else Printf.sprintf "%s (status %d): %s" e.name e.code e.detail

let () =
  Printexc.register_printer (function
    | Polycall_error e -> Some ("Polycall_error: " ^ error_message e)
    | _ -> None)

module Status = struct
  let ok = 0
  let invalid_argument = -1
  let no_memory = -2
  let invalid_handle = -3
  let timeout = -4
  let transport = -5
  let protocol = -6
  let not_found = -7
  let auth = -8
  let remote = -9
  let too_large = -10
  let busy = -11
  let cancelled = -12
  let config = -13
  let address_in_use = -14
  let unsupported = -15
  let permission = -16
  let closed = -17
  let internal = -18
end

external abi_version : unit -> int = "caml_polycall_abi_version"
external version : unit -> string = "caml_polycall_version"
external strerror : int -> string = "caml_polycall_strerror"
external run_config_raw : string -> int = "caml_ocaml_polycall_run_config"
external run_config_stub : string -> bool -> int * string = "caml_polycall_run_config"
external describe_stub : string -> (int * string) * string = "caml_polycall_describe"

external call_stub :
  string -> string -> string -> string option -> int -> (int * string) * string
  = "caml_polycall_call"

let expected_abi_version = 1

let check_abi () =
  let found = abi_version () in
  if found <> expected_abi_version then
    failwith
      (Printf.sprintf "libpolycall %s reports binding ABI %d; ocaml-polycall requires ABI %d"
         (version ()) found expected_abi_version)

(* The C stubs are linked against libpolycall; refuse to run against a
   library with another ABI (a missing library or missing symbols already
   fail at program load time, naming the library/symbol). *)
let () = check_abi ()

let raise_error ?info (code, detail) =
  raise (Polycall_error { code; name = strerror code; detail; info })

let check ((code, _) as st) = if code <> 0 then raise_error st

(* ---- configuration (legacy API unchanged) ---- *)

let default_config = "ocaml-polycallrc"

exception Error of int

let run_config ?(config_path = default_config) () = run_config_raw config_path

let run_config_or_error ?(config_path = default_config) () =
  match run_config_raw config_path with 0 -> () | status -> raise (Error status)

let check_config ?(strict = true) path = check (run_config_stub path strict)

let describe path =
  let st, json = describe_stub path in
  check st;
  json

(* ---- RPC ---- *)

let call ?(timeout_ms = 5000) ?input_json ~endpoint ~service ~operation () =
  let ((code, _) as st), out = call_stub endpoint service operation input_json timeout_ms in
  if code <> 0 then raise_error ?info:(if out = "" then None else Some out) st;
  out

(* ---- peers ---- *)

module Peer = struct
  type t = { handle : int; mutable closed : bool }
  type message = { sender : string; message_id : string; payload : string }

  external open_stub : string -> string option -> string option -> (int * string) * int
    = "caml_polycall_peer_open"
  external close_stub : int -> int * string = "caml_polycall_peer_close"
  external close_quiet : int -> unit = "caml_polycall_peer_close_quiet"
  external endpoint_stub : int -> (int * string) * string = "caml_polycall_peer_endpoint"
  external node_id_stub : int -> (int * string) * string = "caml_polycall_peer_node_id"
  external list_stub : int -> (int * string) * string = "caml_polycall_peer_list"
  external health_stub : int -> (int * string) * string = "caml_polycall_peer_health"
  external register_stub : int -> string -> string -> int * string = "caml_polycall_peer_register"
  external unregister_stub : int -> string -> int * string = "caml_polycall_peer_unregister"
  external ping_stub : int -> string -> int -> int * string = "caml_polycall_peer_ping"

  external send_stub : int -> string -> string -> string option -> int -> int * string
    = "caml_polycall_peer_send"

  external recv_stub : int -> int -> int -> (int * string) * (string * string * string * int)
    = "caml_polycall_peer_recv"

  external cancel_stub : int -> int * string = "caml_polycall_peer_cancel"

  let wait_forever = -1
  let max_payload_default = 1 lsl 20

  let finalise p =
    if not p.closed then begin
      p.closed <- true;
      close_quiet p.handle
    end

  let create ?(bind = Some "127.0.0.1:0") ?token node_id =
    let st, handle = open_stub node_id bind token in
    check st;
    let p = { handle; closed = false } in
    Gc.finalise finalise p;
    p

  let close p =
    let ((code, _) as st) = close_stub p.handle in
    if code = 0 then p.closed <- true;
    check st

  let is_closed p = p.closed
  let handle p = p.handle

  let text f p =
    let st, s = f p.handle in
    check st;
    s

  let endpoint = text endpoint_stub
  let node_id = text node_id_stub
  let list = text list_stub
  let health = text health_stub
  let register p id ep = check (register_stub p.handle id ep)
  let unregister p id = check (unregister_stub p.handle id)
  let ping ?(timeout_ms = 5000) p target = check (ping_stub p.handle target timeout_ms)

  let send ?message_id ?(timeout_ms = 5000) p target payload =
    check (send_stub p.handle target payload message_id timeout_ms)

  let recv ?(timeout_ms = wait_forever) ?(max_payload = max_payload_default) p =
    let ((code, _) as st), (sender, message_id, payload, needed) =
      recv_stub p.handle timeout_ms max_payload
    in
    if code = Status.too_large then raise_error ~info:(string_of_int needed) st;
    check st;
    { sender; message_id; payload }

  let cancel p = check (cancel_stub p.handle)
end
