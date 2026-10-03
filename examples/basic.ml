(* dune exec examples/basic.exe -- [config-path] *)
let () =
  let config_path =
    if Array.length Sys.argv > 1 then Sys.argv.(1) else Polycall.default_config
  in
  Printf.printf "polycall %s (binding ABI %d)\n%!" (Polycall.version ()) (Polycall.abi_version ());
  (try Polycall.check_config config_path
   with Polycall.Polycall_error e ->
     prerr_endline (Polycall.error_message e);
     exit 1);
  Printf.printf "%s is valid for this build\n%!" config_path;
  let a = Polycall.Peer.create "example-a" and b = Polycall.Peer.create "example-b" in
  Polycall.Peer.send ~message_id:"example-1" a (Polycall.Peer.endpoint b) "hello from OCaml";
  let m = Polycall.Peer.recv ~timeout_ms:5000 b in
  Printf.printf "%s -> %s: %s (%s)\n" m.sender (Polycall.Peer.endpoint b) m.payload m.message_id;
  Polycall.Peer.close a;
  Polycall.Peer.close b
