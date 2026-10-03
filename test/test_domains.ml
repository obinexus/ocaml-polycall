(* OCaml 5 domains against the REAL installed libpolycall (built only for
   OCaml >= 5.0, see test/dune). Each domain runs on its own OS thread, so
   this exercises the core's thread safety and its per-thread
   polycall_last_error from truly parallel OCaml code, and proves that a
   domain blocked in Peer.recv has released its domain lock: otherwise the
   stop-the-world collections of the other domains would stall until the
   receive returned. Exit status 1 when any check fails. *)

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

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  go 0

let now () = Unix.gettimeofday ()

let token =
  match Sys.getenv_opt "POLYCALL_DEV_TOKEN" with
  | Some t when t <> "" -> t
  | _ ->
      Random.self_init ();
      Printf.sprintf "ml-dom-%d-%d" (Unix.getpid ()) (Random.bits ())

let tmp =
  let d = Filename.concat (Filename.get_temp_dir_name ())
            (Printf.sprintf "ocaml-polycall-domains-%d" (Unix.getpid ())) in
  (try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  d

let write_file path text =
  let oc = open_out_bin path in
  output_string oc text;
  close_out oc

let cli =
  match Sys.getenv_opt "POLYCALL_CLI" with
  | Some c when c <> "" -> Some c
  | _ ->
      let sep = if Sys.win32 then ';' else ':' in
      let exe = if Sys.win32 then "polycall.exe" else "polycall" in
      let path = try String.split_on_char sep (Sys.getenv "PATH") with Not_found -> [] in
      List.find_map
        (fun d -> let p = Filename.concat d exe in
          if d <> "" && Sys.file_exists p then Some p else None) path

(* polycall start on an ephemeral port: (pid, endpoint) *)
let start_runtime () =
  match cli with
  | None -> None
  | Some exe ->
      let ep_file = Filename.concat tmp "rpc.ep" in
      let log = Unix.openfile (Filename.concat tmp "rpc.log")
                  [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
      let pid = Unix.create_process exe
                  [| exe; "start"; "--endpoint"; "127.0.0.1:0"; "--endpoint-file"; ep_file |]
                  Unix.stdin log log in
      Unix.close log;
      let rec wait n =
        if n = 0 then failwith "polycall start did not write its endpoint"
        else if Sys.file_exists ep_file && (Unix.stat ep_file).Unix.st_size > 0 then begin
          let ic = open_in_bin ep_file in
          let s = String.trim (really_input_string ic (in_channel_length ic)) in
          close_in ic;
          s
        end else (Unix.sleepf 0.1; wait (n - 1))
      in
      Some (pid, wait 100)

let () =
  Printf.printf "OCaml %s, %d domains recommended\n%!" Sys.ocaml_version
    (Domain.recommended_domain_count ());

  check "senders in 4 domains x 25 messages, all delivered exactly once" (fun () ->
      let b = Peer.create ~token "dm-recv" in
      let epb = Peer.endpoint b in
      let senders =
        List.init 4 (fun i ->
            Domain.spawn (fun () ->
                let s = Peer.create ~bind:None ~token (Printf.sprintf "dm-send-%d" i) in
                let ok = ref 0 in
                for j = 1 to 25 do
                  match Peer.send ~message_id:(Printf.sprintf "d%d-%d" i j) ~timeout_ms:10000 s epb
                          (Printf.sprintf "%d/%d" i j) with
                  | () -> incr ok
                  | exception _ -> ()
                done;
                Peer.close s;
                !ok))
      in
      let got = Hashtbl.create 128 in
      for _ = 1 to 100 do
        let m = Peer.recv ~timeout_ms:10000 b in
        Hashtbl.replace got (m.sender, m.message_id, m.payload) ()
      done;
      let sent = List.fold_left (fun acc d -> acc + Domain.join d) 0 senders in
      let extra = status_of (fun () -> Peer.recv ~timeout_ms:200 b) in
      let all =
        List.for_all (fun i ->
            List.for_all (fun j ->
                Hashtbl.mem got (Printf.sprintf "dm-send-%d" i, Printf.sprintf "d%d-%d" i j,
                                 Printf.sprintf "%d/%d" i j)) (List.init 25 succ)) (List.init 4 Fun.id)
      in
      Peer.close b;
      sent = 100 && Hashtbl.length got = 100 && all && extra = Status.timeout);

  check "per-thread last_error detail stays with its own domain (4 domains in parallel)" (fun () ->
      let ds =
        List.init 4 (fun i ->
            Domain.spawn (fun () ->
                let mine = Filename.concat tmp (Printf.sprintf "bad-key-%d-polycallrc" i) in
                write_file mine (Printf.sprintf "key_from_domain_%d=1\n" i);
                let ok = ref true in
                for _ = 1 to 200 do
                  match check_config mine with
                  | () -> ok := false
                  | exception Polycall_error e ->
                      if not (e.code = Status.config
                              && contains e.detail (Printf.sprintf "key_from_domain_%d" i)) then
                        ok := false
                done;
                !ok))
      in
      List.for_all Fun.id (List.map Domain.join ds));

  check "a domain blocked in recv does not stall the other domains' collections" (fun () ->
      let a = Peer.create ~token "dm-block" in
      let blocked = Domain.spawn (fun () -> status_of (fun () -> Peer.recv a)) in
      Unix.sleepf 0.3;
      let t0 = now () in
      (* allocation-heavy work forces minor and major collections; each needs
         every domain at a safepoint (or in a released blocking section) *)
      let keep = ref [] in
      for i = 1 to 300_000 do
        keep := string_of_int i :: !keep;
        if i mod 30_000 = 0 then (keep := []; Gc.minor ())
      done;
      Gc.full_major ();
      let dt = now () -. t0 in
      Printf.printf "      GC work finished in %.3f s while another domain was blocked in recv\n%!" dt;
      Peer.cancel a;
      let r = Domain.join blocked in
      Peer.close a;
      dt < 60.0 && r = Status.cancelled);

  check "close from the main domain wakes a recv blocked in another domain" (fun () ->
      let a = Peer.create ~token "dm-close" in
      let blocked = Domain.spawn (fun () -> status_of (fun () -> Peer.recv a)) in
      Unix.sleepf 0.3;
      Peer.close a;
      Domain.join blocked = Status.closed);

  (match start_runtime () with
   | None -> skip "concurrent calls from domains" "polycall CLI not found (set POLYCALL_CLI or PATH)"
   | Some (pid, ep) ->
       check "concurrent polycall_call from 4 domains x 20 calls" (fun () ->
           let ds =
             List.init 4 (fun i ->
                 Domain.spawn (fun () ->
                     let ok = ref 0 in
                     for j = 1 to 20 do
                       let input = Printf.sprintf "{\"d\":%d,\"j\":%d}" i j in
                       match call ~timeout_ms:10000 ~endpoint:ep ~service:"debug" ~operation:"echo"
                               ~input_json:input () with
                       | out when out = "{\"echo\":" ^ input ^ "}" -> incr ok
                       | _ -> ()
                       | exception _ -> ()
                     done;
                     !ok))
           in
           List.fold_left (fun acc d -> acc + Domain.join d) 0 ds = 80);
       (try Unix.kill pid (if Sys.win32 then Sys.sigkill else Sys.sigterm) with _ -> ());
       (try ignore (Unix.waitpid [] pid) with _ -> ()));

  Printf.printf "--- ocaml-polycall domains: %d passed, %d failed, %d skipped ---\n%!"
    !passes !failures !skips;
  exit (if !failures > 0 then 1 else 0)
