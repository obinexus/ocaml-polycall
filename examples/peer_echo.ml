(* Cross-binding interop agent (same command line as the other bindings'
   echo agents, e.g. `fsharp-polycall peer echo`):

     peer_echo.exe peer echo --node-id ID [--endpoint H:P] [--endpoint-file F]
                   [--peer ID=H:P ...] [--count N] [--idle-timeout-ms N]
                   [--auth-token-env NAME]

   Every message received is sent back to its sender with message id
   "echo-<id>" (the sender must be registered with --peer: receiving never
   registers a sender). Prints one JSON line per event. With --count N it
   exits after N echoes; without, after --idle-timeout-ms of silence. The
   shared token comes from the environment (POLYCALL_DEV_TOKEN by default),
   never from argv. Exit codes: 0 ok, 1 an echo failed, 2 usage, and the
   polycall CLI codes for a failing call (4 not found, 5 transport,
   6 deadline, 7 auth). *)

let usage () =
  prerr_endline
    "usage: peer_echo.exe peer echo --node-id ID [--endpoint H:P] [--endpoint-file F]\n\
    \                     [--peer ID=H:P ...] [--count N] [--idle-timeout-ms N] [--auth-token-env NAME]";
  exit 2

let json s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let exit_code (e : Polycall.error) =
  let open Polycall.Status in
  if e.code = not_found || e.code = unsupported then 4
  else if e.code = transport then 5
  else if e.code = timeout then 6
  else if e.code = auth then 7
  else if e.code = config then 3
  else if e.code = invalid_argument || e.code = too_large then 2
  else 1

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  let args = match args with "peer" :: "echo" :: rest -> rest | _ -> usage () in
  let node_id = ref None and bind = ref "127.0.0.1:0" and ep_file = ref None
  and peers = ref [] and count = ref 0 and idle = ref 30000 and token_env = ref "POLYCALL_DEV_TOKEN" in
  let int_of name v = match int_of_string_opt v with Some n when n >= 0 -> n
                                                   | _ -> prerr_endline (name ^ " needs a number"); usage () in
  let rec parse = function
    | "--node-id" :: v :: r -> node_id := Some v; parse r
    | "--endpoint" :: v :: r -> bind := v; parse r
    | "--endpoint-file" :: v :: r -> ep_file := Some v; parse r
    | "--auth-token-env" :: v :: r -> token_env := v; parse r
    | "--count" :: v :: r -> count := int_of "--count" v; parse r
    | "--idle-timeout-ms" :: v :: r -> idle := int_of "--idle-timeout-ms" v; parse r
    | "--peer" :: v :: r ->
        (match String.index_opt v '=' with
         | Some i when i > 0 ->
             peers := (String.sub v 0 i, String.sub v (i + 1) (String.length v - i - 1)) :: !peers
         | _ -> prerr_endline ("--peer needs ID=HOST:PORT, got " ^ v); usage ());
        parse r
    | [] -> ()
    | o :: _ -> prerr_endline ("unknown option " ^ o); usage ()
  in
  parse args;
  let node_id = match !node_id with Some n -> n | None -> usage () in
  let token = match Sys.getenv_opt !token_env with Some t when t <> "" -> Some t | _ -> None in
  try
    let p = Polycall.Peer.create ~bind:(Some !bind) ?token node_id in
    List.iter (fun (id, ep) -> Polycall.Peer.register p id ep) (List.rev !peers);
    let ep = Polycall.Peer.endpoint p in
    (match !ep_file with
     | Some f ->
         let tmp = f ^ ".tmp" in
         let oc = open_out_bin tmp in
         output_string oc (ep ^ "\n");
         close_out oc;
         Sys.rename tmp f
     | None -> ());
    Printf.printf "{\"event\":\"listening\",\"node_id\":%s,\"endpoint\":%s,\"binding\":\"ocaml-polycall\"}\n%!"
      (json node_id) (json ep);
    let echoed = ref 0 and result = ref 0 and running = ref true in
    while !running && (!count = 0 || !echoed < !count) do
      match Polycall.Peer.recv ~timeout_ms:!idle p with
      | exception Polycall.Polycall_error e when e.code = Polycall.Status.timeout && !count = 0 ->
          running := false
      | m ->
          Printf.printf "{\"event\":\"received\",\"from\":%s,\"id\":%s,\"len\":%d,\"md5\":\"%s\"}\n%!"
            (json m.sender) (json m.message_id) (String.length m.payload)
            (Digest.to_hex (Digest.string m.payload));
          let reply = "echo-" ^ m.message_id in
          (try
             Polycall.Peer.send ~message_id:reply ~timeout_ms:10000 p m.sender m.payload;
             Printf.printf "{\"event\":\"echoed\",\"to\":%s,\"id\":%s}\n%!" (json m.sender) (json reply)
           with Polycall.Polycall_error e ->
             Printf.eprintf "peer_echo: echo to %s failed: %s\n%!" m.sender (Polycall.error_message e);
             Printf.printf "{\"event\":\"echo_failed\",\"to\":%s,\"status\":%s}\n%!" (json m.sender) (json e.name);
             result := 1);
          incr echoed
    done;
    Polycall.Peer.close p;
    exit !result
  with Polycall.Polycall_error e ->
    prerr_endline ("peer_echo: " ^ Polycall.error_message e);
    exit (exit_code e)
