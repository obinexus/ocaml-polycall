#!/bin/sh
# Package check: lint ocaml-polycall.opam, `opam install` THIS checkout into
# the current opam switch (nothing is published), then build and run a clean
# dune project outside the repository that uses the installed library
# against the REAL libpolycall. Meant for a throwaway switch / container.
#
#   PKG_CONFIG_PATH=/opt/polycall/lib/pkgconfig LD_LIBRARY_PATH=/opt/polycall/lib \
#     sh scripts/test-package.sh [workdir outside the repository]
#
# Exit status: 0 = pass, 1 = failure, 77 = SKIP (no opam/dune or no libpolycall).
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
command -v opam >/dev/null 2>&1 || { echo "SKIP: opam not found"; exit 77; }
command -v dune >/dev/null 2>&1 || { echo "SKIP: dune not found"; exit 77; }
pkg-config --exists polycall 2>/dev/null || { echo "SKIP: pkg-config polycall not found"; exit 77; }
OUT=${1:-${TMPDIR:-/tmp}/ocaml-polycall-package}
rm -rf "$OUT"; mkdir -p "$OUT/consumer"
fail() { echo "FAIL: $*"; exit 1; }

echo "== opam lint"
opam lint ocaml-polycall.opam || fail "opam lint"
echo "== opam install of $REPO (working directory state, into switch $(opam switch show))"
opam install -y --working-dir "$REPO" || fail "opam install"
opam show ocaml-polycall --field=name,version,installed-version || fail "opam show"
LIBDIR="$(opam var lib)/ocaml-polycall"
[ -f "$LIBDIR/META" ] || fail "no META under $LIBDIR"
ls "$LIBDIR"

cat > "$OUT/consumer/dune-project" <<'EOF'
(lang dune 3.8)
EOF
cat > "$OUT/consumer/dune" <<'EOF'
(executable
 (name consumer)
 (libraries ocaml-polycall))
EOF
cat > "$OUT/consumer/consumer.ml" <<'EOF'
(* a clean project using the INSTALLED ocaml-polycall against the real core *)
let check what ok = if ok then Printf.printf "ok   %s\n%!" what else failwith ("FAIL: " ^ what)

let () =
  check "ABI 1" (Polycall.abi_version () = 1);
  Printf.printf "libpolycall %s\n%!" (Polycall.version ());
  let rc = Filename.temp_file "consumer-" "-polycallrc" in
  let write s = let oc = open_out_bin rc in output_string oc s; close_out oc in
  write "log_level=info\n";
  check "run_config strict on a valid file" (Polycall.run_config ~config_path:rc () = 0);
  write "tls_enabled=true\ncert_file=/x/c.pem\nkey_file=/x/k.pem\n";
  check "tls_enabled=true is Unsupported"
    (Polycall.run_config ~config_path:rc () = Polycall.Status.unsupported);
  let a = Polycall.Peer.create "consumer-a" and b = Polycall.Peer.create "consumer-b" in
  let payload = String.init 300 (fun i -> Char.chr (i land 0xff)) in
  Polycall.Peer.send ~message_id:"pkg-1" a (Polycall.Peer.endpoint b) payload;
  let m = Polycall.Peer.recv ~timeout_ms:5000 b in
  check "payload a -> b" (m.sender = "consumer-a" && m.message_id = "pkg-1" && m.payload = payload);
  Polycall.Peer.send ~message_id:"pkg-2" b (Polycall.Peer.endpoint a) "back";
  let m = Polycall.Peer.recv ~timeout_ms:5000 a in
  check "payload b -> a" (m.sender = "consumer-b" && m.payload = "back");
  check "Polycall_error with status, name and detail"
    (match Polycall.Peer.send a "nobody" "x" with
     | () -> false
     | exception Polycall.Polycall_error e ->
         e.code = Polycall.Status.not_found && e.name <> "" && e.detail <> "");
  Polycall.Peer.close a;
  Polycall.Peer.close b;
  print_endline "PACKAGE-CONSUMER PASS"
EOF
echo "== consumer project at $OUT/consumer (outside the repository)"
( cd "$OUT/consumer" && dune build --root . ./consumer.exe && ./_build/default/consumer.exe ) || fail "consumer"
echo "installed ocaml-polycall used by a clean dune project: PASS"
