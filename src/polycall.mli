(** Thin OCaml adapter for the libpolycall configuration runner. *)

val default_config : string
(** The default configuration path: [ocaml-polycallrc]. *)

exception Error of int
(** [Error status] is raised by [run_config_or_error] for nonzero statuses. *)

val run_config : ?config_path:string -> unit -> int
(** Run libpolycall and return its status unchanged. *)

val run_config_or_error : ?config_path:string -> unit -> unit
(** Run libpolycall and raise [Error status] when the status is nonzero. *)
