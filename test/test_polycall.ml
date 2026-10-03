(* Tests of ocaml-polycall against the REAL installed libpolycall (no mocks):
   the docs/BINDING_ABI.md checklist, `polycall_call` against
   `polycall start` and `polycall daemon start`, and interop with a
   `polycall peer serve` C node in both directions. Needs the `polycall` CLI
   (POLYCALL_CLI or PATH) for the RPC and interop checks; checks that cannot
   run print SKIP and never count as passes. Exit status 1 when any check
   fails. *)

open Polycall

let passes = ref 0
let failures = ref 0
let skips = ref 0

let check name f =
  match f () with
  | true -> incr passes; Printf.printf "PASS  %s\n%!" name
  | false -> incr failures; Printf.printf "FAIL  %s\n%!" name
  | exception e ->
      incr failures;
      Printf.printf "FAIL  %s (exception %s)\n%!" name (Printexc.to_string e)

let skip name reason = incr skips; Printf.printf "SKIP  %s: %s\n%!" name reason

let status_of f =
  match f () with
  | _ -> 0
  | exception Polycall_error e -> e.code

let error_of f =
  match f () with
  | _ -> None
  | exception Polycall_error e -> Some e

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  go 0

let starts_with s p = String.length s >= String.length p && String.sub s 0 (String.length p) = p
let now () = Unix.gettimeofday ()
let mib = 1 lsl 20

let token =
  match Sys.getenv_opt "POLYCALL_DEV_TOKEN" with
  | Some t when t <> "" -> t
  | _ ->
      Random.self_init ();
      Printf.sprintf "ml-test-%d-%d" (Unix.getpid ()) (Random.bits ())

(* environment of every polycall CLI child: this process's environment with
   the test token, telemetry off, and the [extra] overrides (NAME=value sets,
   NAME alone removes). Unix.putenv is not used: its strings are never freed. *)
let child_env ?(extra = []) () =
  let name e = match String.index_opt e '=' with Some i -> String.sub e 0 i | None -> e in
  (* later entries win; an entry without '=' removes the variable *)
  let final =
    List.fold_left (fun acc e -> (name e, e) :: List.remove_assoc (name e) acc) []
      ([ "POLYCALL_DEV_TOKEN=" ^ token; "POLYCALL_TELEMETRY=off" ] @ extra) in
  let base = Array.to_list (Unix.environment ())
             |> List.filter (fun kv -> not (List.mem_assoc (name kv) final)) in
  Array.of_list
    (base @ List.filter_map (fun (_, e) -> if String.contains e '=' then Some e else None) final)

let utf8_text = "h\xc3\xa9llo \xe2\x80\x94 \xe4\xb8\x96\xe7\x95\x8c \xf0\x9f\x8c\x8d"
let bytes_0_255 = String.init 256 Char.chr
let node ?bind id = Peer.create ?bind ~token id

(* deterministic pseudo-random bytes *)
let noise seed n = String.init n (fun i -> Char.chr ((i * 7 + seed + (i / 256) * 13) land 0xff))

let tmp =
  let d = Filename.concat (Filename.get_temp_dir_name ())
            (Printf.sprintf "ocaml-polycall-test-%d" (Unix.getpid ())) in
  (try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  d

let write_file path text =
  let oc = open_out_bin path in
  output_string oc text;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

let cli =
  match Sys.getenv_opt "POLYCALL_CLI" with
  | Some c when c <> "" -> Some c
  | _ ->
      let sep = if Sys.win32 then ';' else ':' in
      let exe = if Sys.win32 then "polycall.exe" else "polycall" in
      let path = try String.split_on_char sep (Sys.getenv "PATH") with Not_found -> [] in
      List.find_map
        (fun d ->
          let p = Filename.concat d exe in
          if d <> "" && Sys.file_exists p then Some p else None)
        path

let children = ref []

let start_cli name args =
  match cli with
  | None -> None
  | Some exe ->
      let ep_file = Filename.concat tmp (name ^ ".ep") in
      let log = Unix.openfile (Filename.concat tmp (name ^ ".log"))
                  [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
      let argv = Array.of_list ((exe :: args) @ [ "--endpoint-file"; ep_file ]) in
      let pid = Unix.create_process_env exe argv (child_env ()) Unix.stdin log log in
      Unix.close log;
      children := pid :: !children;
      let rec wait n =
        if n = 0 then failwith (name ^ " did not write its endpoint")
        else if Sys.file_exists ep_file && (Unix.stat ep_file).Unix.st_size > 0 then
          String.trim (read_file ep_file)
        else (Unix.sleepf 0.1; wait (n - 1))
      in
      Some (wait 100)

(* run the CLI with extra environment (NAME=value, or NAME alone to drop it),
   capture stdout+stderr, return (exit code, output) *)
let out_counter = ref 0

let run_cli ?(env = []) args =
  match cli with
  | None -> (-1, "")
  | Some exe ->
      incr out_counter;
      let out = Filename.concat tmp (Printf.sprintf "cli-%d.out" !out_counter) in
      let fd = Unix.openfile out [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
      let pid = Unix.create_process_env exe (Array.of_list (exe :: args)) (child_env ~extra:env ())
                  Unix.stdin fd fd in
      Unix.close fd;
      let _, status = Unix.waitpid [] pid in
      let code = match status with Unix.WEXITED c -> c | _ -> -1 in
      (code, read_file out)

let json_field json key =
  let pat = "\"" ^ key ^ "\":\"" in
  let n = String.length json and m = String.length pat in
  let rec find i =
    if i + m > n then None
    else if String.sub json i m = pat then
      let j = try String.index_from json (i + m) '"' with Not_found -> n in
      Some (String.sub json (i + m) (j - i - m))
    else find (i + 1)
  in
  find 0

let b64decode s =
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
  let buf = Buffer.create (String.length s) in
  let acc = ref 0 and bits = ref 0 in
  (try
     String.iter
       (fun c ->
         if c = '=' then raise Exit;
         let v = String.index alphabet c in
         acc := ((!acc lsl 6) lor v) land 0xffffff;
         bits := !bits + 6;
         if !bits >= 8 then begin
           bits := !bits - 8;
           Buffer.add_char buf (Char.chr ((!acc lsr !bits) land 0xff))
         end)
       s
   with Exit -> ());
  Buffer.contents buf

let msg_eq (m : Peer.message) sender id payload =
  m.sender = sender && m.message_id = id && m.payload = payload

(* ===================================================================== *)

let rpc = start_cli "rpc" [ "start"; "--endpoint"; "127.0.0.1:0" ]
let cli_node =
  start_cli "cli-node" [ "peer"; "serve"; "--node-id"; "cli-node"; "--endpoint"; "127.0.0.1:0" ]

let () =
  if cli = None then skip "rpc + interop fixtures" "polycall CLI not found (set POLYCALL_CLI or PATH)";

  check "version and ABI check" (fun () ->
      abi_version () = 1 && expected_abi_version = 1 && version () = "1.1.0"
      && (check_abi (); true)
      && starts_with (strerror (-4)) "POLYCALL_E_TIMEOUT"
      && starts_with (strerror 0) "POLYCALL_OK"
      && contains (strerror (-999)) "UNKNOWN"
      && List.for_all (fun c -> starts_with (strerror c) "POLYCALL_") (List.init 19 (fun i -> -i)));

  (* ---- configuration ---- *)
  let rc name text = let p = Filename.concat tmp name in write_file p text; p in
  check "run_config valid (legacy status API and strict check_config)" (fun () ->
      run_config ~config_path:"../ocaml-polycallrc" () = 0
      && run_config ~config_path:"../examples/ocaml-polycallrc" () = 0
      && (run_config_or_error ~config_path:"../ocaml-polycallrc" (); true)
      && (check_config "../ocaml-polycallrc"; true)
      && (check_config ~strict:false "../examples/ocaml-polycallrc"; true));
  check "run_config missing -> NOT_FOUND" (fun () ->
      let p = Filename.concat tmp "does-not-exist-polycallrc" in
      run_config ~config_path:p () = Status.not_found
      && (match error_of (fun () -> check_config p) with
         | Some e -> e.code = Status.not_found && starts_with e.name "POLYCALL_E_NOT_FOUND"
                     && contains e.detail "does-not-exist-polycallrc"
         | None -> false)
      && (match run_config_or_error ~config_path:p () with
         | () -> false
         | exception Error s -> s = Status.not_found));
  check "run_config invalid -> CONFIG naming the key" (fun () ->
      let p = rc "bad-polycallrc" "max_connections=lots\n" in
      (match error_of (fun () -> check_config ~strict:false p) with
       | Some e -> e.code = Status.config && contains e.detail "max_connections"
                   && starts_with e.name "POLYCALL_E_CONFIG"
       | None -> false)
      && run_config ~config_path:p () = Status.config
      && status_of (fun () -> check_config (rc "garbage-polycallrc" "this is not a config line\n"))
         = Status.config);
  check "run_config strict: unknown key is a warning, strict an error" (fun () ->
      let p = rc "unknown-polycallrc" "log_level=info\nmystery_key=1\n" in
      status_of (fun () -> check_config ~strict:false p) = 0
      && (match error_of (fun () -> check_config ~strict:true p) with
         | Some e -> e.code = Status.config && contains e.detail "mystery_key"
         | None -> false));
  check "run_config tls_enabled=true -> UNSUPPORTED when strict" (fun () ->
      let p = rc "tls-polycallrc" "tls_enabled=true\ncert_file=/x/c.pem\nkey_file=/x/k.pem\n" in
      status_of (fun () -> check_config ~strict:false p) = 0
      && (match error_of (fun () -> check_config p) with
         | Some e -> e.code = Status.unsupported && contains e.detail "tls_enabled"
         | None -> false)
      && run_config ~config_path:p () = Status.unsupported);
  check "run_config argument errors" (fun () ->
      run_config ~config_path:"" () = Status.invalid_argument
      && status_of (fun () -> check_config "") = Status.invalid_argument
      && (match check_config "a\000b" with
         | () -> false
         | exception Invalid_argument _ -> true)
      && (match run_config ~config_path:"a\000b" () with
         | _ -> false
         | exception Invalid_argument _ -> true));
  (* non-ASCII directory and file names (UTF-8: Latin-1, CJK, a 4-byte
     code point); each outcome proves the core opened exactly that file *)
  check "run_config with a non-ASCII (UTF-8) path" (fun () ->
      let dir = Filename.concat tmp "dossier-\xc3\xa9-\xe7\x9b\xae\xe5\xbd\x95-\xf0\x9f\x8c\x8d" in
      (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      let valid = Filename.concat dir "caf\xc3\xa9-\xe4\xb8\x96\xe7\x95\x8c-\xf0\x9f\x8c\x8d-polycallrc" in
      write_file valid "log_level=info\nmax_connections=4242\n";
      let invalid = Filename.concat dir "\xc3\xb1and\xc3\xba-polycallrc" in
      write_file invalid "max_connections=many\n";
      let absent = Filename.concat dir "absent-\xc3\xbc-\xe4\xb8\x8d\xe5\xad\x98\xe5\x9c\xa8-polycallrc" in
      run_config ~config_path:valid () = 0
      && (check_config valid; true)
      && contains (describe valid) "4242"
      && (match error_of (fun () -> check_config invalid) with
         | Some e -> e.code = Status.config && contains e.detail "max_connections"
         | None -> false)
      && (match error_of (fun () -> check_config absent) with
         | Some e -> e.code = Status.not_found
                     && contains e.detail "absent-\xc3\xbc-\xe4\xb8\x8d\xe5\xad\x98\xe5\x9c\xa8-polycallrc"
         | None -> false));
  check "describe reports peers and keys" (fun () ->
      let p = rc "Polycallfile"
          "server node 8080:8084\nnetwork start\nworkspace_root=/opt/x\nlog_directory=/var/log/x\n\
           daemon_endpoint=127.0.0.1:0\nauth_token_env=POLYCALL_DEV_TOKEN\npeer_node_id=alpha\n\
           peer beta 127.0.0.1:9002\n" in
      check_config p;
      let d = describe p in
      contains d "\"beta\":\"127.0.0.1:9002\"" && starts_with d "{"
      && status_of (fun () -> describe (Filename.concat tmp "nope")) = Status.not_found);

  (* ---- RPC against polycall start ---- *)
  (match rpc with
   | None -> skip "call checks" "polycall CLI not found"
   | Some ep ->
       check "call success (inventory.get against polycall start)" (fun () ->
           let out = call ~endpoint:ep ~service:"inventory" ~operation:"get"
                       ~input_json:"{\"item_id\":\"widget-a\"}" () in
           contains out "\"quantity\":42" && contains out "\"in_stock\":true");
       check "call debug.echo round-trips UTF-8 JSON; null input" (fun () ->
           call ~endpoint:ep ~service:"debug" ~operation:"echo"
             ~input_json:("{\"text\":\"" ^ utf8_text ^ "\"}") ()
           = "{\"echo\":{\"text\":\"" ^ utf8_text ^ "\"}}"
           && call ~endpoint:ep ~service:"debug" ~operation:"echo" () = "{\"echo\":null}");
       check "call unknown operation -> NOT_FOUND with the remote error object" (fun () ->
           match error_of (fun () -> call ~endpoint:ep ~service:"inventory" ~operation:"nope" ()) with
           | Some { code; info = Some i; _ } -> code = Status.not_found && contains i "operation.unknown"
           | _ -> false);
       check "call remote failure -> REMOTE (item.unknown)" (fun () ->
           match error_of (fun () -> call ~endpoint:ep ~service:"inventory" ~operation:"get"
                                       ~input_json:"{\"item_id\":\"nope\"}" ()) with
           | Some { code; info = Some i; _ } -> code = Status.remote && contains i "item.unknown"
           | _ -> false);
       check "call deadline exceeded -> TIMEOUT" (fun () ->
           let t0 = now () in
           status_of (fun () -> call ~timeout_ms:300 ~endpoint:ep ~service:"debug" ~operation:"sleep"
                                  ~input_json:"{\"ms\":3000}" ()) = Status.timeout
           && now () -. t0 < 2.9);
       check "call invalid input / timeout bounds -> INVALID_ARGUMENT (never sent)" (fun () ->
           let bad f = status_of f = Status.invalid_argument in
           bad (fun () -> call ~endpoint:ep ~service:"debug" ~operation:"echo" ~input_json:"{bad" ())
           && bad (fun () -> call ~timeout_ms:0 ~endpoint:ep ~service:"debug" ~operation:"echo" ())
           && bad (fun () -> call ~timeout_ms:(-1) ~endpoint:ep ~service:"debug" ~operation:"echo" ())
           && bad (fun () -> call ~timeout_ms:600001 ~endpoint:ep ~service:"debug" ~operation:"echo" ())
           && bad (fun () -> call ~timeout_ms:(1 lsl 32) ~endpoint:ep ~service:"debug" ~operation:"echo" ())
           && bad (fun () -> call ~endpoint:"no-port" ~service:"debug" ~operation:"echo" ())
           && bad (fun () -> call ~endpoint:ep ~service:"" ~operation:"echo" ())
           && call ~timeout_ms:600000 ~endpoint:ep ~service:"debug" ~operation:"echo" () = "{\"echo\":null}"
           && (match call ~endpoint:ep ~service:"debug" ~operation:"echo" ~input_json:"\"a\000b\"" () with
              | _ -> false
              | exception Invalid_argument _ -> true));
       check "call with no runtime -> TRANSPORT" (fun () ->
           let p = Peer.create "ml-probe" in
           let free = Peer.endpoint p in
           Peer.close p;
           status_of (fun () -> call ~timeout_ms:2000 ~endpoint:free ~service:"debug" ~operation:"echo" ())
           = Status.transport);
       check "concurrent calls from 8 threads x 16 calls" (fun () ->
           let bad = Atomic.make 0 in
           let threads =
             List.init 8 (fun i ->
                 Thread.create
                   (fun () ->
                     for j = 1 to 16 do
                       let input = Printf.sprintf "{\"t\":%d,\"j\":%d}" i j in
                       match call ~timeout_ms:10000 ~endpoint:ep ~service:"debug" ~operation:"echo"
                               ~input_json:input () with
                       | out when out = "{\"echo\":" ^ input ^ "}" -> ()
                       | _ -> Atomic.incr bad
                       | exception _ -> Atomic.incr bad
                     done)
                   ())
           in
           List.iter Thread.join threads;
           Atomic.get bad = 0));

  (* ---- RPC against polycall daemon start (background daemon) ---- *)
  (match cli with
   | None -> skip "call through polycall daemon" "polycall CLI not found"
   | Some _ ->
       check "call through polycall daemon start / stop" (fun () ->
           let dir = Filename.concat tmp "daemon" in
           (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
           let file = Filename.concat dir "Polycallfile" in
           write_file file
             "# ocaml-polycall daemon test\nserver node 8080:8084\nnetwork start\n\
              daemon_endpoint=127.0.0.1:0\nauth_token_env=POLYCALL_DEV_TOKEN\n";
           let code, out = run_cli [ "--format"; "json"; "daemon"; "start"; "-t"; "15000"; file ] in
           let result =
             match code, json_field out "endpoint" with
             | 0, Some ep ->
                 let o = call ~endpoint:ep ~service:"inventory" ~operation:"get"
                           ~input_json:"{\"item_id\":\"widget-b\"}" () in
                 contains o "\"quantity\":7"
             | _ -> Printf.printf "      daemon start: exit %d: %s\n%!" code out; false
           in
           let stop, sout = run_cli [ "daemon"; "stop"; "-t"; "10000"; file ] in
           if stop <> 0 then Printf.printf "      daemon stop: exit %d: %s\n%!" stop sout;
           result && stop = 0));

  (* ---- peers ---- *)
  check "peer open: endpoint, node id, send-only, invalid arguments" (fun () ->
      let p = Peer.create "ml-open" in
      let ep = Peer.endpoint p in
      let ok1 = starts_with ep "127.0.0.1:" && ep <> "127.0.0.1:0" && Peer.node_id p = "ml-open"
                && contains (Peer.health p) "\"node_id\":\"ml-open\"" && Peer.handle p > 0 in
      let clash = status_of (fun () -> Peer.create ~bind:(Some ep) "ml-clash") in
      Peer.close p;
      let s = Peer.create ~bind:None "ml-sendonly" in
      let ok2 = Peer.endpoint s = "" in
      Peer.close s;
      ok1 && ok2 && Peer.is_closed p && clash = Status.address_in_use
      && status_of (fun () -> Peer.create "bad id!") = Status.invalid_argument
      && status_of (fun () -> Peer.create "") = Status.invalid_argument
      && status_of (fun () -> Peer.create (String.make 63 'a') |> Peer.close) = 0
      && status_of (fun () -> Peer.create (String.make 64 'a')) = Status.invalid_argument
      && status_of (fun () -> Peer.create ~bind:(Some "nonsense") "x") = Status.invalid_argument
      && status_of (fun () -> Peer.create ~bind:(Some "0.0.0.0:0") "x") = Status.config
      && (match Peer.create "a\000b" with _ -> false | exception Invalid_argument _ -> true));

  check "two OCaml nodes exchange payloads both ways (bytes, sender, id)" (fun () ->
      let a = node "ml-alpha" and b = node "ml-beta" in
      Peer.send ~message_id:"m-a2b" a (Peer.endpoint b) "hello beta";
      let m1 = Peer.recv ~timeout_ms:3000 b in
      Peer.send ~message_id:"m-b2a" b (Peer.endpoint a) "hello alpha";
      let m2 = Peer.recv ~timeout_ms:3000 a in
      Peer.send a (Peer.endpoint b) "auto";
      let m3 = Peer.recv ~timeout_ms:3000 b in
      Peer.close a; Peer.close b;
      msg_eq m1 "ml-alpha" "m-a2b" "hello beta" && msg_eq m2 "ml-beta" "m-b2a" "hello alpha"
      && m3.message_id <> "" && m3.payload = "auto");

  check "payloads: empty, UTF-8, binary with NUL, 1 MiB exact, 1 MiB + 1" (fun () ->
      let a = node "ml-sizes-a" and b = node "ml-sizes-b" in
      let epb = Peer.endpoint b in
      let big = noise 0 mib in
      let ok =
        List.for_all
          (fun (id, bytes) ->
            Peer.send ~message_id:id ~timeout_ms:10000 a epb bytes;
            msg_eq (Peer.recv ~timeout_ms:10000 b) "ml-sizes-a" id bytes)
          [ ("m-empty", ""); ("m-utf8", utf8_text); ("m-bin", bytes_0_255);
            ("m-nul", "\000\000\001\000"); ("m-max", big) ]
      in
      let over = status_of (fun () -> Peer.send ~message_id:"m-over" a epb (big ^ "x")) in
      let none = status_of (fun () -> Peer.recv ~timeout_ms:300 b) in
      let received0 = contains (Peer.health b) "\"received\":5" in
      Peer.close a; Peer.close b;
      ok && over = Status.too_large && none = Status.timeout && received0);

  check "registry ownership: per node, explicit, never implied by receiving" (fun () ->
      let a = node "ml-reg-a" and b = node "ml-reg-b" in
      let epb = Peer.endpoint b in
      let r0 = Peer.list a = "{}" in
      Peer.register a "ml-reg-b" epb;
      let r1 = Peer.list a = "{\"ml-reg-b\":\"" ^ epb ^ "\"}" && Peer.list b = "{}" in
      Peer.send ~message_id:"m-id" a "ml-reg-b" "by id";
      let r2 = msg_eq (Peer.recv ~timeout_ms:3000 b) "ml-reg-a" "m-id" "by id" && Peer.list b = "{}" in
      let r2b = status_of (fun () -> Peer.send b "ml-reg-a" "back") = Status.not_found in
      Peer.ping a "ml-reg-b";
      Peer.register a "impostor" epb;
      let r3 = status_of (fun () -> Peer.ping a "impostor") = Status.protocol
               && status_of (fun () -> Peer.send a "impostor" "x") = Status.protocol in
      ignore (status_of (fun () -> Peer.recv ~timeout_ms:500 b));  (* may have been stored *)
      Peer.unregister a "impostor";
      Peer.unregister a "ml-reg-b";
      let r4 = status_of (fun () -> Peer.unregister a "ml-reg-b") = Status.not_found
               && status_of (fun () -> Peer.send a "ml-reg-b" "x") = Status.not_found
               && status_of (fun () -> Peer.register a "bad id" epb) = Status.invalid_argument
               && status_of (fun () -> Peer.register a "ok-id" "no-port") = Status.invalid_argument
               && Peer.list a = "{}" in
      Peer.close a; Peer.close b;
      r0 && r1 && r2 && r2b && r3 && r4);

  check "duplicate message id is delivered once" (fun () ->
      let a = node "ml-dup-a" and b = node "ml-dup-b" in
      Peer.send ~message_id:"m-dup" a (Peer.endpoint b) "once";
      Peer.send ~message_id:"m-dup" a (Peer.endpoint b) "once";
      let ok = msg_eq (Peer.recv ~timeout_ms:3000 b) "ml-dup-a" "m-dup" "once"
               && status_of (fun () -> Peer.recv ~timeout_ms:500 b) = Status.timeout
               && contains (Peer.health b) "\"duplicates\":1" in
      Peer.close a; Peer.close b;
      ok);

  check "auth failure: wrong or missing token is refused, nothing queued" (fun () ->
      let b = node "ml-auth-b" in
      let wrong = Peer.create ~token:"not-the-token" "ml-mallory" in
      let anon = Peer.create ~bind:None "ml-anon" in
      let ok = status_of (fun () -> Peer.send wrong (Peer.endpoint b) "x") = Status.auth
               && status_of (fun () -> Peer.send anon (Peer.endpoint b) "x") = Status.auth
               && status_of (fun () -> Peer.recv ~timeout_ms:300 b) = Status.timeout
               && status_of (fun () -> Peer.ping anon (Peer.endpoint b)) = 0 in
      List.iter Peer.close [ b; wrong; anon ];
      ok);

  check "send to a dead peer -> TRANSPORT" (fun () ->
      let a = node "ml-live" and d = node "ml-dead" in
      let epd = Peer.endpoint d in
      Peer.close d;
      let ok = status_of (fun () -> Peer.send ~timeout_ms:2000 a epd "void") = Status.transport
               && status_of (fun () -> Peer.ping ~timeout_ms:1000 a epd) = Status.transport in
      Peer.close a;
      ok);

  check "receive timeout and poll" (fun () ->
      let a = node "ml-timeout" in
      let t0 = now () in
      let r1 = status_of (fun () -> Peer.recv ~timeout_ms:250 a) = Status.timeout in
      let dt = now () -. t0 in
      let r2 = status_of (fun () -> Peer.recv ~timeout_ms:0 a) = Status.timeout in
      Peer.close a;
      r1 && r2 && dt >= 0.2 && dt < 3.0);

  check "too-small buffer -> TOO_LARGE with size, message stays queued" (fun () ->
      let a = node "ml-small-a" and b = node "ml-small-b" in
      let payload = String.concat "" (List.init 10 (fun _ -> "0123456789")) in
      Peer.send ~message_id:"m-small" a (Peer.endpoint b) payload;
      let e = error_of (fun () -> Peer.recv ~timeout_ms:3000 ~max_payload:10 b) in
      let e0 = error_of (fun () -> Peer.recv ~timeout_ms:3000 ~max_payload:0 b) in
      let ok = (match e with Some { code; info = Some "100"; _ } -> code = Status.too_large | _ -> false)
               && (match e0 with Some { code; info = Some "100"; _ } -> code = Status.too_large | _ -> false)
               && msg_eq (Peer.recv ~timeout_ms:1000 ~max_payload:100 b) "ml-small-a" "m-small" payload
               && (match Peer.recv ~max_payload:(mib + 1) b with
                  | _ -> false
                  | exception Invalid_argument _ -> true) in
      Peer.close a; Peer.close b;
      ok);

  check "blocked recv releases the runtime lock (other threads keep running)" (fun () ->
      let a = node "ml-lock" in
      let result = ref 0 in
      let t0 = now () in
      let th = Thread.create (fun () -> result := status_of (fun () -> Peer.recv ~timeout_ms:1500 a)) () in
      Thread.delay 0.2;
      (* if the stub kept the runtime lock, this thread could not resume
         until the recv returned (~1.5 s) *)
      let resumed = now () -. t0 in
      let counter = ref 0 in
      for i = 1 to 1_000_000 do counter := !counter + i land 1 done;
      Thread.join th;
      Peer.close a;
      Printf.printf "      main thread resumed after %.3f s while recv blocked\n%!" resumed;
      resumed < 1.0 && !result = Status.timeout && !counter > 0);

  check "cancel and close wake a blocked recv" (fun () ->
      let a = node "ml-cancel" in
      let r = ref 0 in
      let th = Thread.create (fun () -> r := status_of (fun () -> Peer.recv a)) () in
      Thread.delay 0.3;
      let t0 = now () in
      Peer.cancel a;
      Thread.join th;
      let ok1 = !r = Status.cancelled && now () -. t0 < 5.0
                && status_of (fun () -> Peer.recv ~timeout_ms:100 a) = Status.timeout in
      let th = Thread.create (fun () -> r := status_of (fun () -> Peer.recv a)) () in
      Thread.delay 0.3;
      Peer.close a;
      Thread.join th;
      ok1 && !r = Status.closed);

  check "double close, use after close are defined (INVALID_HANDLE)" (fun () ->
      let a = node "ml-closed" in
      let epa = Peer.endpoint a in
      Peer.close a;
      let ih f = status_of f = Status.invalid_handle in
      ih (fun () -> Peer.close a)
      && ih (fun () -> Peer.send a epa "x")
      && ih (fun () -> Peer.recv ~timeout_ms:0 a)
      && ih (fun () -> Peer.endpoint a)
      && ih (fun () -> Peer.node_id a)
      && ih (fun () -> Peer.list a)
      && ih (fun () -> Peer.health a)
      && ih (fun () -> Peer.register a "x" epa)
      && ih (fun () -> Peer.unregister a "x")
      && ih (fun () -> Peer.cancel a)
      && ih (fun () -> Peer.ping a epa)
      && (let b = node "ml-fresh" in
          let fresh = Peer.handle b <> Peer.handle a && Peer.node_id b = "ml-fresh" in
          let still = ih (fun () -> Peer.endpoint a) in
          Peer.close b;
          fresh && still));

  check "finaliser closes an unreachable peer" (fun () ->
      let ep = (fun () -> Peer.endpoint (Peer.create "ml-gc")) () in
      let probe = Peer.create ~bind:None "ml-gc-probe" in
      let rec wait n =
        Gc.full_major ();
        if status_of (fun () -> Peer.ping ~timeout_ms:500 probe ep) = Status.transport then true
        else if n = 0 then false
        else (Unix.sleepf 0.1; wait (n - 1))
      in
      let ok = wait 50 in
      Peer.close probe;
      ok);

  check "concurrent senders (8 threads x 25 messages) all delivered once" (fun () ->
      let b = node "ml-conc-b" in
      let epb = Peer.endpoint b in
      let errors = Atomic.make 0 in
      let threads =
        List.init 8 (fun i ->
            Thread.create
              (fun () ->
                try
                  let s = Peer.create ~bind:None ~token (Printf.sprintf "ml-conc-%d" i) in
                  for j = 1 to 25 do
                    Peer.send ~message_id:(Printf.sprintf "c%d-%d" i j) s epb (Printf.sprintf "%d:%d" i j)
                  done;
                  Peer.close s
                with _ -> Atomic.incr errors)
              ())
      in
      List.iter Thread.join threads;
      let got = Hashtbl.create 256 in
      for _ = 1 to 200 do
        let m = Peer.recv ~timeout_ms:5000 b in
        Hashtbl.replace got (m.sender, m.message_id, m.payload) ()
      done;
      let none_left = status_of (fun () -> Peer.recv ~timeout_ms:200 b) = Status.timeout in
      let all =
        List.for_all
          (fun i -> List.for_all (fun j ->
               Hashtbl.mem got (Printf.sprintf "ml-conc-%d" i, Printf.sprintf "c%d-%d" i j,
                                Printf.sprintf "%d:%d" i j)) (List.init 25 (fun j -> j + 1)))
          (List.init 8 Fun.id)
      in
      Peer.close b;
      Atomic.get errors = 0 && none_left && all && Hashtbl.length got = 200);

  check "concurrent senders on ONE shared handle (4 threads x 25)" (fun () ->
      let b = node "ml-shared-b" and s = node ~bind:None "ml-shared-s" in
      let epb = Peer.endpoint b in
      let errors = Atomic.make 0 in
      let threads =
        List.init 4 (fun i ->
            Thread.create (fun () ->
                for j = 1 to 25 do
                  try Peer.send ~message_id:(Printf.sprintf "h%d-%d" i j) s epb "x"
                  with _ -> Atomic.incr errors
                done) ())
      in
      List.iter Thread.join threads;
      let ids = Hashtbl.create 128 in
      (try
         for _ = 1 to 100 do
           let m = Peer.recv ~timeout_ms:5000 b in
           Hashtbl.replace ids m.message_id ()
         done
       with _ -> ());
      Peer.close b; Peer.close s;
      Atomic.get errors = 0 && Hashtbl.length ids = 100);

  (* ---- interop with the C CLI node ---- *)
  (match cli_node with
   | None -> skip "interop with polycall peer serve" "polycall CLI not found"
   | Some cep ->
       check "interop: OCaml peer -> C CLI node (verified by polycall peer recv)" (fun () ->
           let a = node "ml-interop" in
           let big = noise 3 mib in
           let ok =
             List.for_all
               (fun (id, bytes) ->
                 Peer.send ~message_id:id ~timeout_ms:20000 a cep bytes;
                 let code, out = run_cli [ "peer"; "recv"; "--to"; cep; "-t"; "10000" ] in
                 code = 0
                 && json_field out "from" = Some "ml-interop"
                 && json_field out "id" = Some id
                 && Option.map b64decode (json_field out "payload_b64") = Some bytes)
               [ ("x-m2c-text", "hello C node"); ("x-m2c-utf8", utf8_text);
                 ("x-m2c-bin", bytes_0_255); ("x-m2c-empty", ""); ("x-m2c-max", big) ]
           in
           Peer.close a;
           ok);
       check "interop: C CLI (polycall peer send) -> OCaml peer" (fun () ->
           let a = node "ml-interop-rx" in
           let epa = Peer.endpoint a in
           let bin = Filename.concat tmp "bin.in" in
           write_file bin bytes_0_255;
           let bigf = Filename.concat tmp "big.in" in
           let big = noise 5 mib in
           write_file bigf big;
           let c1, _ = run_cli [ "peer"; "send"; "--from"; "cli-node"; "--to"; epa; "--id"; "x-c2m-text";
                                 "--payload"; "hello OCaml" ] in
           let m1 = Peer.recv ~timeout_ms:3000 a in
           let c2, _ = run_cli [ "peer"; "send"; "--from"; "cli-node"; "--to"; epa; "--id"; "x-c2m-bin";
                                 "--payload-file"; bin ] in
           let m2 = Peer.recv ~timeout_ms:3000 a in
           let c3, _ = run_cli [ "peer"; "send"; "--from"; "cli-node"; "--to"; epa; "--id"; "x-c2m-max";
                                 "--payload-file"; bigf; "-t"; "20000" ] in
           let m3 = Peer.recv ~timeout_ms:20000 a in
           (* the same id again from the C side: stored once *)
           let c4, _ = run_cli [ "peer"; "send"; "--from"; "cli-node"; "--to"; epa; "--id"; "x-c2m-text";
                                 "--payload"; "hello OCaml" ] in
           let dup = status_of (fun () -> Peer.recv ~timeout_ms:400 a) = Status.timeout in
           let c5, h = run_cli [ "peer"; "health"; "--to"; epa ] in
           Peer.ping a cep;
           Peer.close a;
           c1 = 0 && c2 = 0 && c3 = 0 && c4 = 0 && c5 = 0 && dup
           && msg_eq m1 "cli-node" "x-c2m-text" "hello OCaml"
           && msg_eq m2 "cli-node" "x-c2m-bin" bytes_0_255
           && msg_eq m3 "cli-node" "x-c2m-max" big
           && contains h "\"node_id\":\"ml-interop-rx\"");
       check "interop: C CLI manages an OCaml-hosted node over the wire (token enforced)" (fun () ->
           let a = node "ml-host" in
           let epa = Peer.endpoint a in
           let c1, _ = run_cli [ "peer"; "register"; "--to"; epa; "--id"; "remote1";
                                 "--peer-endpoint"; "127.0.0.1:9" ] in
           let listed = Peer.list a = "{\"remote1\":\"127.0.0.1:9\"}" in
           let c2, peers = run_cli [ "peer"; "peers"; "--to"; epa ] in
           let c3, _ = run_cli ~env:[ "POLYCALL_DEV_TOKEN" ] [ "peer"; "peers"; "--to"; epa ] in
           let c4, _ = run_cli ~env:[ "POLYCALL_DEV_TOKEN=wrong-token" ]
                         [ "peer"; "send"; "--from"; "mallory"; "--to"; epa; "--payload"; "x" ] in
           let nothing = status_of (fun () -> Peer.recv ~timeout_ms:300 a) = Status.timeout in
           Peer.close a;
           c1 = 0 && listed && c2 = 0 && contains peers "remote1" && c3 = 7 && c4 = 7 && nothing));

  (* ---- interop with ANOTHER binding's echo agent (env-gated) ----
     POLYCALL_INTEROP_ECHO is the agent command (e.g. "dotnet .../fsharp-polycall.dll");
     it is started as AGENT peer echo --node-id echo-agent --endpoint 127.0.0.1:0
     --peer ocaml-origin=H:P --count N --idle-timeout-ms MS --endpoint-file F
     and must send every message back with id "echo-<id>". *)
  (match Sys.getenv_opt "POLYCALL_INTEROP_ECHO" with
   | None | Some "" -> skip "interop with another binding's echo agent" "POLYCALL_INTEROP_ECHO not set"
   | Some command ->
       let label = Option.value (Sys.getenv_opt "POLYCALL_INTEROP_ECHO_NAME") ~default:"external" in
       check (Printf.sprintf "interop: OCaml peer <-> %s echo agent, payloads both ways" label) (fun () ->
           let payloads = [ ""; "hello from ocaml to " ^ label; utf8_text; bytes_0_255;
                            noise 11 200000; noise 12 mib ] in
           let origin = node "ocaml-origin" in
           let words = String.split_on_char ' ' command |> List.filter (( <> ) "") in
           let exe = List.hd words in
           let ep_file = Filename.concat tmp "echo-agent.ep" in
           let log_path = Filename.concat tmp "echo-agent.log" in
           let log = Unix.openfile log_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
           let argv = Array.of_list (words @ [ "peer"; "echo"; "--node-id"; "echo-agent";
                                               "--endpoint"; "127.0.0.1:0";
                                               "--peer"; "ocaml-origin=" ^ Peer.endpoint origin;
                                               "--count"; string_of_int (List.length payloads);
                                               "--idle-timeout-ms"; "30000"; "--endpoint-file"; ep_file ]) in
           let exe_path =
             if Filename.is_implicit exe then
               (let sep = if Sys.win32 then ';' else ':' in
                List.find_map (fun d -> let p = Filename.concat d exe in
                                if d <> "" && Sys.file_exists p then Some p else None)
                  (String.split_on_char sep (try Sys.getenv "PATH" with Not_found -> ""))
                |> Option.value ~default:exe)
             else exe in
           let pid = Unix.create_process_env exe_path argv (child_env ()) Unix.stdin log log in
           Unix.close log;
           let rec wait n =
             if n = 0 then None
             else if Sys.file_exists ep_file && String.trim (read_file ep_file) <> "" then
               Some (String.trim (read_file ep_file))
             else (Unix.sleepf 0.1; wait (n - 1)) in
           match wait 300 with
           | None ->
               (try Unix.kill pid Sys.sigkill with _ -> ());
               ignore (Unix.waitpid [] pid);
               Printf.printf "      agent did not report an endpoint: %s\n%!" (read_file log_path);
               Peer.close origin; false
           | Some agent_ep ->
               Peer.register origin "echo-agent" agent_ep;
               let ok =
                 List.for_all Fun.id
                   (List.mapi (fun i p ->
                        let id = Printf.sprintf "x%d" i in
                        Peer.send ~message_id:id ~timeout_ms:20000 origin "echo-agent" p;
                        let m = Peer.recv ~timeout_ms:20000 origin in
                        let good = msg_eq m "echo-agent" ("echo-" ^ id) p in
                        if not good then Printf.printf "      payload %d differs after the round trip\n%!" i;
                        good) payloads) in
               let _, status = Unix.waitpid [] pid in
               let agent_log = read_file log_path in
               Peer.close origin;
               let exited_ok = status = Unix.WEXITED 0 in
               if not exited_ok then Printf.printf "      agent log:\n%s\n%!" agent_log;
               Printf.printf "      echo interop with %s: %d round trips\n%!" label (List.length payloads);
               ok && exited_ok && contains agent_log "\"from\":\"ocaml-origin\""));

  List.iter
    (fun pid ->
      (try Unix.kill pid (if Sys.win32 then Sys.sigkill else Sys.sigterm) with _ -> ());
      try ignore (Unix.waitpid [] pid) with _ -> ())
    !children;
  Printf.printf "--- ocaml-polycall: %d passed, %d failed, %d skipped ---\n%!" !passes !failures !skips;
  exit (if !failures > 0 then 1 else 0)
