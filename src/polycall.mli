(** OCaml binding for the Polycall C library, binding ABI v1
    ([polycall.h]; contract: [docs/BINDING_ABI.md] in
    {{:https://github.com/obinexus/polycall}obinexus/polycall}).

    The C stubs link libpolycall through [pkg-config polycall]. Every call
    that can block releases the OCaml runtime lock while it waits, so other
    threads keep running. *)

(** {1 Errors} *)

type error = {
  code : int;  (** negative [POLYCALL_E_*] status *)
  name : string;  (** [polycall_strerror code] *)
  detail : string;  (** [polycall_last_error ()] of the failing call *)
  info : string option;
      (** remote error object JSON for {!call}; needed payload size (decimal)
          for a too-small {!Peer.recv} buffer *)
}

exception Polycall_error of error
(** Raised by every function below except the legacy status API. *)

val error_message : error -> string

(** Status codes of [polycall.h]. *)
module Status : sig
  val ok : int
  val invalid_argument : int
  val no_memory : int
  val invalid_handle : int
  val timeout : int
  val transport : int
  val protocol : int
  val not_found : int
  val auth : int
  val remote : int
  val too_large : int
  val busy : int
  val cancelled : int
  val config : int
  val address_in_use : int
  val unsupported : int
  val permission : int
  val closed : int
  val internal : int
end

(** {1 Library} *)

val expected_abi_version : int
(** [1]. *)

val abi_version : unit -> int
(** [polycall_ffi_abi_version ()] of the linked library. *)

val check_abi : unit -> unit
(** Raises [Failure] naming the library version if [abi_version () <> 1]. *)

val version : unit -> string
(** Library version, e.g. ["1.1.0"]. *)

val strerror : int -> string
(** [polycall_strerror status]: static name of any status code. *)

(** {1 Configuration} *)

val default_config : string
(** [ocaml-polycallrc]. *)

exception Error of int
(** Legacy: raised by {!run_config_or_error} with the raw status. *)

val run_config : ?config_path:string -> unit -> int
(** Legacy entry point: [polycall_ffi_run_config path 1], status unchanged
    (0 = valid for running with this build). *)

val run_config_or_error : ?config_path:string -> unit -> unit
(** Legacy: raises [Error status] when the status is nonzero. *)

val check_config : ?strict:bool -> string -> unit
(** [polycall_ffi_run_config path strict] (default [strict = true]: unknown
    keys are errors and [tls_enabled=true] is refused with
    [Status.unsupported]). Raises {!Polycall_error}. *)

val describe : string -> string
(** JSON description of a configuration file (secrets never resolved). *)

(** {1 RPC} *)

val call :
  ?timeout_ms:int -> ?input_json:string -> endpoint:string -> service:string ->
  operation:string -> unit -> string
(** One [polycall_rpc] v1 round trip (never retried) to a running
    [polycall start] / [polycall daemon] at [endpoint] (["host:port"]).
    Returns the output JSON. [timeout_ms] defaults to 5000; values outside
    1..600000 are rejected with [Status.invalid_argument] (never wrapped).
    [input_json] defaults to [null] and must be valid JSON. The C stub sizes
    the output buffer for the documented 1 MiB maximum. *)

(** {1 Peer nodes} *)

module Peer : sig
  type t
  (** A peer node. Closed by {!close}, or by a finaliser when it becomes
      unreachable. Calls after [close] (including a second [close]) raise
      {!Polycall_error} with [Status.invalid_handle]. *)

  type message = { sender : string; message_id : string; payload : string }
  (** [payload] holds the exact bytes received (binary-safe). *)

  val create : ?bind:string option -> ?token:string -> string -> t
  (** [create node_id]: [bind] defaults to [Some "127.0.0.1:0"] (ephemeral
      loopback port); [~bind:None] opens a send-only node. [token] is the
      shared secret (none by default); a non-loopback bind needs one. *)

  val close : t -> unit
  val is_closed : t -> bool
  val handle : t -> int
  val endpoint : t -> string
  val node_id : t -> string
  val register : t -> string -> string -> unit
  val unregister : t -> string -> unit
  val list : t -> string
  (** THIS node's registry as JSON text. *)

  val ping : ?timeout_ms:int -> t -> string -> unit
  (** [ping p target]: OK only when [target] (registered id or "host:port")
      answers healthy and, for a registered id, under that id. Peer timeouts
      default to 5000 ms; a negative value (or one >= 2{^32}-1) means wait
      indefinitely. *)

  val send : ?message_id:string -> ?timeout_ms:int -> t -> string -> string -> unit
  (** [send p target payload]: exactly one delivery attempt; returns once the
      receiver acknowledged it. Retry with the same [message_id] after
      timeout/transport/busy errors. Payloads over 1 MiB raise
      [Status.too_large] before any I/O. *)

  val recv : ?timeout_ms:int -> ?max_payload:int -> t -> message
  (** Oldest message. [timeout_ms] omitted = wait until a message, {!cancel}
      ([Status.cancelled]) or {!close} ([Status.closed]); [0] polls; a
      negative value also waits indefinitely. A message larger than
      [max_payload] (0..1048576, default 1 MiB; anything else is
      [Invalid_argument]) raises [Status.too_large] with
      [info = Some needed] and stays queued. *)

  val cancel : t -> unit
  val health : t -> string
end
