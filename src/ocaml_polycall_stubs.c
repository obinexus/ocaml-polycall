/*
 * ocaml_polycall_stubs.c -- OCaml C stubs over the Polycall binding ABI v1
 * (<polycall.h>; docs/BINDING_ABI.md in https://github.com/obinexus/polycall).
 *
 * Every call that can block (run_config, describe, call, peer open / close /
 * ping / send / recv) copies its OCaml arguments to C memory, RELEASES the
 * OCaml runtime lock (caml_release_runtime_system: the master lock on
 * OCaml 4.14, the domain lock on OCaml 5) for the duration of the library
 * call and re-acquires it before touching the OCaml heap again. Other threads
 * keep running while a recv waits, and on OCaml 5 other domains' stop-the-world
 * collections are not held up by a blocked receive.
 *
 * Failures return (code, detail): polycall_last_error() is thread-local in
 * the core, so it is read on the same thread right after the failing call.
 * String arguments are checked for embedded NULs before anything is
 * allocated (Invalid_argument), and the C copies are owned by one cstrs_t,
 * so neither a raise nor an allocation failure leaks.
 *
 * Ownership: the library never returns memory to free; every output goes to
 * a buffer allocated here and freed here. Peer handles are plain ints that
 * the core validates on every call (unknown / closed -> INVALID_HANDLE).
 */

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#include <polycall.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "ocaml_polycall.h"

#define DETAIL_MAX 1024

typedef struct {
    int rc;
    char detail[DETAIL_MAX];
} status_t;

static void capture(status_t *st, int rc)
{
    st->rc = rc;
    st->detail[0] = '\0';
    if (rc != POLYCALL_OK) {
        (void)polycall_last_error(st->detail, sizeof st->detail);
        st->detail[sizeof st->detail - 1] = '\0';
    }
}

static void set_status(status_t *st, int rc, const char *detail)
{
    st->rc = rc;
    strncpy(st->detail, detail, sizeof st->detail - 1);
    st->detail[sizeof st->detail - 1] = '\0';
}

/* (code, detail) for the OCaml side; success is code 0 */
static value status_pair(const status_t *st)
{
    CAMLparam0();
    CAMLlocal2(res, detail);
    detail = caml_copy_string(st->detail);
    res = caml_alloc_tuple(2);
    Store_field(res, 0, Val_int(st->rc));
    Store_field(res, 1, detail);
    CAMLreturn(res);
}

/* ((code, detail), v) */
static value with_status(const status_t *st, value v)
{
    CAMLparam1(v);
    CAMLlocal2(res, pair);
    pair = status_pair(st);
    res = caml_alloc_tuple(2);
    Store_field(res, 0, pair);
    Store_field(res, 1, v);
    CAMLreturn(res);
}

static void require_c_string(value s, const char *what)
{
    if (memchr(String_val(s), '\0', caml_string_length(s)) != NULL) {
        caml_invalid_argument(what);
    }
}

static void require_c_string_opt(value o, const char *what)
{
    if (Is_some(o)) require_c_string(Some_val(o), what);
}

/* C copies of OCaml arguments, owned together: if one allocation fails,
   every copy made so far is freed before Out_of_memory is raised, so no
   path leaks. Call only after the require_c_string checks. */
#define CSTRS_MAX 8
typedef struct {
    void *v[CSTRS_MAX];
    int n;
} cstrs_t;

static void cstrs_free(cstrs_t *c)
{
    while (c->n > 0) free(c->v[--c->n]);
}

static void *cstrs_alloc(cstrs_t *c, size_t n)
{
    void *p = malloc(n ? n : 1);
    if (!p || c->n >= CSTRS_MAX) {
        free(p);
        cstrs_free(c);
        caml_raise_out_of_memory();
    }
    c->v[c->n++] = p;
    return p;
}

/* OCaml string -> NUL-terminated copy */
static char *cstrs_dup(cstrs_t *c, value s)
{
    mlsize_t n = caml_string_length(s);
    char *p = (char *)cstrs_alloc(c, n + 1);
    memcpy(p, String_val(s), n);
    p[n] = 0;
    return p;
}

static char *cstrs_dup_opt(cstrs_t *c, value o)
{
    return Is_none(o) ? NULL : cstrs_dup(c, Some_val(o));
}

/* overwrite a secret before its copy is freed */
static void wipe(char *s)
{
    if (s) {
        volatile char *v = s;
        size_t i, n = strlen(s);
        for (i = 0; i < n; ++i) v[i] = 0;
    }
}

/* peer timeouts: negative or >= UINT32_MAX = wait forever (UINT32_MAX) */
static uint32_t to_timeout(value v)
{
    intnat t = Long_val(v);
    if (t < 0 || (uintnat)t >= (uintnat)UINT32_MAX) return UINT32_MAX;
    return (uint32_t)t;
}

/* ------------------------------------------------------------------------ */
/* library                                                                   */

CAMLprim value caml_polycall_abi_version(value unit)
{
    (void)unit;
    return Val_int(polycall_ffi_abi_version());
}

CAMLprim value caml_polycall_version(value unit)
{
    CAMLparam1(unit);
    char buf[64];
    if (polycall_ffi_version(buf, (int)sizeof buf) < 0) caml_failwith("polycall_ffi_version failed");
    CAMLreturn(caml_copy_string(buf));
}

CAMLprim value caml_polycall_strerror(value code)
{
    CAMLparam1(code);
    CAMLreturn(caml_copy_string(polycall_strerror(Int_val(code))));
}

/* ------------------------------------------------------------------------ */
/* configuration                                                             */

/* legacy entry point: the status of polycall_ffi_run_config(path, 1) */
CAMLprim value caml_ocaml_polycall_run_config(value config_path)
{
    CAMLparam1(config_path);
    cstrs_t c = { { NULL }, 0 };
    char *path;
    int32_t rc;
    require_c_string(config_path, "Polycall.run_config: config_path contains NUL");
    path = cstrs_dup(&c, config_path);
    caml_release_runtime_system();
    rc = ocaml_polycall_run_config(path);
    caml_acquire_runtime_system();
    cstrs_free(&c);
    CAMLreturn(Val_long((intnat)rc));
}

CAMLprim value caml_polycall_run_config(value config_path, value strict)
{
    CAMLparam2(config_path, strict);
    cstrs_t c = { { NULL }, 0 };
    char *path;
    int run = Bool_val(strict) ? 1 : 0;
    status_t st;
    require_c_string(config_path, "Polycall.check_config: config_path contains NUL");
    path = cstrs_dup(&c, config_path);
    caml_release_runtime_system();
    capture(&st, run ? ocaml_polycall_run_config(path) : polycall_ffi_run_config(path, 0));
    caml_acquire_runtime_system();
    cstrs_free(&c);
    CAMLreturn(status_pair(&st));
}

/* ((code, detail), json) */
CAMLprim value caml_polycall_describe(value config_path)
{
    CAMLparam1(config_path);
    CAMLlocal1(json);
    cstrs_t c = { { NULL }, 0 };
    char *path, *buf = NULL;
    int n, m;
    status_t st;
    require_c_string(config_path, "Polycall.describe: config_path contains NUL");
    path = cstrs_dup(&c, config_path);
    caml_release_runtime_system();
    n = polycall_ffi_describe(path, NULL, 0);   /* snprintf rules: the length */
    if (n < 0) {
        capture(&st, n);
    } else if ((buf = (char *)malloc((size_t)n + 1)) == NULL) {
        set_status(&st, POLYCALL_E_NO_MEMORY, "out of memory");
    } else {
        m = polycall_ffi_describe(path, buf, n + 1);
        if (m < 0) capture(&st, m);
        else if (m > n) set_status(&st, POLYCALL_E_TOO_LARGE, "configuration changed while being described");
        else capture(&st, POLYCALL_OK);
    }
    caml_acquire_runtime_system();
    cstrs_free(&c);
    json = caml_copy_string(st.rc == POLYCALL_OK && buf ? buf : "");
    free(buf);
    CAMLreturn(with_status(&st, json));
}

/* ------------------------------------------------------------------------ */
/* RPC: call endpoint service operation input_opt timeout -> ((code, detail), out) */

CAMLprim value caml_polycall_call(value endpoint, value service, value operation,
                                  value input, value timeout)
{
    CAMLparam5(endpoint, service, operation, input, timeout);
    CAMLlocal1(out);
    cstrs_t c = { { NULL }, 0 };
    char *ep, *svc, *op, *in, *buf;
    intnat t = Long_val(timeout);
    /* sized for the documented maximum: a too-small buffer would discard a
       result that already ran */
    size_t cap = (size_t)POLYCALL_CALL_MAX_OUTPUT + 1, len = 0;
    status_t st;
    require_c_string(endpoint, "Polycall.call: endpoint contains NUL");
    require_c_string(service, "Polycall.call: service contains NUL");
    require_c_string(operation, "Polycall.call: operation contains NUL");
    require_c_string_opt(input, "Polycall.call: input_json contains NUL");
    buf = (char *)cstrs_alloc(&c, cap);
    ep = cstrs_dup(&c, endpoint);
    svc = cstrs_dup(&c, service);
    op = cstrs_dup(&c, operation);
    in = cstrs_dup_opt(&c, input);
    buf[0] = '\0';
    caml_release_runtime_system();
    /* out-of-range timeouts become 0, which the core rejects (1..600000):
       never silently wrapped to a different deadline */
    capture(&st, polycall_call(ep, svc, op, in,
                               (t < 0 || t > (intnat)UINT32_MAX) ? 0u : (uint32_t)t,
                               buf, cap, &len));
    caml_acquire_runtime_system();
    out = caml_copy_string(st.rc == POLYCALL_E_TOO_LARGE ? "" : buf);
    cstrs_free(&c);
    CAMLreturn(with_status(&st, out));
}

/* ------------------------------------------------------------------------ */
/* peers -- handles are plain OCaml ints; the core validates every one      */

/* open node_id bind_opt token_opt -> ((code, detail), handle) */
CAMLprim value caml_polycall_peer_open(value node_id, value bind, value token)
{
    CAMLparam3(node_id, bind, token);
    cstrs_t c = { { NULL }, 0 };
    char *id, *b, *tok;
    polycall_peer_t h = 0;
    status_t st;
    require_c_string(node_id, "Polycall.Peer.create: node_id contains NUL");
    require_c_string_opt(bind, "Polycall.Peer.create: bind contains NUL");
    require_c_string_opt(token, "Polycall.Peer.create: token contains NUL");
    id = cstrs_dup(&c, node_id);
    b = cstrs_dup_opt(&c, bind);
    tok = cstrs_dup_opt(&c, token);
    caml_release_runtime_system();
    capture(&st, polycall_peer_open(id, b, tok, &h));
    caml_acquire_runtime_system();
    wipe(tok);                    /* do not leave the secret in the C heap */
    cstrs_free(&c);
    CAMLreturn(with_status(&st, Val_int(h)));
}

CAMLprim value caml_polycall_peer_close(value handle)
{
    CAMLparam1(handle);
    polycall_peer_t h = (polycall_peer_t)Long_val(handle);
    status_t st;
    caml_release_runtime_system();
    capture(&st, polycall_peer_close(h));   /* joins the node's workers */
    caml_acquire_runtime_system();
    CAMLreturn(status_pair(&st));
}

/* close for a finaliser: no allocation, no exception */
CAMLprim value caml_polycall_peer_close_quiet(value handle)
{
    polycall_peer_t h = (polycall_peer_t)Long_val(handle);
    caml_release_runtime_system();
    (void)polycall_peer_close(h);
    caml_acquire_runtime_system();
    return Val_unit;
}

typedef int (*text_fn)(polycall_peer_t, char *, size_t, size_t *);

static int endpoint_fn(polycall_peer_t h, char *b, size_t c, size_t *n)
{
    int rc = polycall_peer_endpoint(h, b, c);
    *n = rc == POLYCALL_OK ? strlen(b) : POLYCALL_ENDPOINT_MAX;
    return rc;
}

static int node_id_fn(polycall_peer_t h, char *b, size_t c, size_t *n)
{
    int rc = polycall_peer_node_id(h, b, c);
    *n = rc == POLYCALL_OK ? strlen(b) : POLYCALL_PEER_ID_MAX;
    return rc;
}

/* short, non-blocking text getters (snprintf rules): ((code, detail), text) */
static value text_result(value handle, text_fn fn)
{
    CAMLparam1(handle);
    CAMLlocal1(text);
    polycall_peer_t h = (polycall_peer_t)Long_val(handle);
    size_t cap = 4096, need = 0;
    char *buf = NULL;
    status_t st;
    int attempt;
    set_status(&st, POLYCALL_E_TOO_LARGE, "output kept growing");
    for (attempt = 0; attempt < 4; ++attempt) {
        free(buf);
        buf = (char *)malloc(cap);
        if (!buf) caml_raise_out_of_memory();
        need = 0;
        capture(&st, fn(h, buf, cap, &need));
        if (st.rc != POLYCALL_E_TOO_LARGE) break;
        cap = need + 1;
    }
    text = caml_copy_string(st.rc == POLYCALL_OK ? buf : "");
    free(buf);
    CAMLreturn(with_status(&st, text));
}

CAMLprim value caml_polycall_peer_endpoint(value h) { return text_result(h, endpoint_fn); }
CAMLprim value caml_polycall_peer_node_id(value h) { return text_result(h, node_id_fn); }
CAMLprim value caml_polycall_peer_list(value h) { return text_result(h, polycall_peer_list); }
CAMLprim value caml_polycall_peer_health(value h) { return text_result(h, polycall_peer_health); }

CAMLprim value caml_polycall_peer_register(value handle, value peer_id, value endpoint)
{
    CAMLparam3(handle, peer_id, endpoint);
    cstrs_t c = { { NULL }, 0 };
    char *id, *ep;
    status_t st;
    require_c_string(peer_id, "Polycall.Peer.register: peer_id contains NUL");
    require_c_string(endpoint, "Polycall.Peer.register: endpoint contains NUL");
    id = cstrs_dup(&c, peer_id);
    ep = cstrs_dup(&c, endpoint);
    capture(&st, polycall_peer_register((polycall_peer_t)Long_val(handle), id, ep));
    cstrs_free(&c);
    CAMLreturn(status_pair(&st));
}

CAMLprim value caml_polycall_peer_unregister(value handle, value peer_id)
{
    CAMLparam2(handle, peer_id);
    cstrs_t c = { { NULL }, 0 };
    char *id;
    status_t st;
    require_c_string(peer_id, "Polycall.Peer.unregister: peer_id contains NUL");
    id = cstrs_dup(&c, peer_id);
    capture(&st, polycall_peer_unregister((polycall_peer_t)Long_val(handle), id));
    cstrs_free(&c);
    CAMLreturn(status_pair(&st));
}

CAMLprim value caml_polycall_peer_ping(value handle, value target, value timeout)
{
    CAMLparam3(handle, target, timeout);
    cstrs_t c = { { NULL }, 0 };
    char *t;
    polycall_peer_t h = (polycall_peer_t)Long_val(handle);
    uint32_t ms = to_timeout(timeout);
    status_t st;
    require_c_string(target, "Polycall.Peer.ping: target contains NUL");
    t = cstrs_dup(&c, target);
    caml_release_runtime_system();
    capture(&st, polycall_peer_ping(h, t, ms));
    caml_acquire_runtime_system();
    cstrs_free(&c);
    CAMLreturn(status_pair(&st));
}

/* send handle target payload msg_id_opt timeout */
CAMLprim value caml_polycall_peer_send(value handle, value target, value payload,
                                       value message_id, value timeout)
{
    CAMLparam5(handle, target, payload, message_id, timeout);
    cstrs_t c = { { NULL }, 0 };
    char *t, *mid, *data;
    size_t len = caml_string_length(payload);
    polycall_peer_t h = (polycall_peer_t)Long_val(handle);
    uint32_t ms = to_timeout(timeout);
    status_t st;
    require_c_string(target, "Polycall.Peer.send: target contains NUL");
    require_c_string_opt(message_id, "Polycall.Peer.send: message_id contains NUL");
    /* the payload is copied out of the OCaml heap: the GC may move the
       string while the runtime lock is released */
    data = (char *)cstrs_alloc(&c, len);
    if (len) memcpy(data, String_val(payload), len);
    t = cstrs_dup(&c, target);
    mid = cstrs_dup_opt(&c, message_id);
    caml_release_runtime_system();
    capture(&st, polycall_peer_send(h, t, data, len, mid, ms));
    caml_acquire_runtime_system();
    cstrs_free(&c);
    CAMLreturn(status_pair(&st));
}

/* recv handle timeout capacity ->
 *   ((code, detail), (sender, message_id, payload, needed)) */
CAMLprim value caml_polycall_peer_recv(value handle, value timeout, value capacity)
{
    CAMLparam3(handle, timeout, capacity);
    CAMLlocal4(msg, sender_v, id_v, payload_v);
    polycall_peer_t h = (polycall_peer_t)Long_val(handle);
    uint32_t ms = to_timeout(timeout);
    intnat cap_i = Long_val(capacity);
    size_t cap, len = 0;
    char sender[POLYCALL_PEER_ID_MAX], mid[POLYCALL_MESSAGE_ID_MAX];
    char *buf;
    status_t st;
    if (cap_i < 0 || cap_i > (intnat)POLYCALL_PEER_MAX_PAYLOAD) {
        caml_invalid_argument("Polycall.Peer.recv: max_payload must be 0..1048576");
    }
    cap = (size_t)cap_i;
    buf = (char *)malloc(cap ? cap : 1);
    if (!buf) caml_raise_out_of_memory();
    sender[0] = mid[0] = '\0';
    caml_release_runtime_system();
    capture(&st, polycall_peer_recv(h, ms, sender, sizeof sender, mid, sizeof mid, buf, cap, &len));
    caml_acquire_runtime_system();
    if (st.rc == POLYCALL_OK && len <= cap) {
        payload_v = caml_alloc_string(len);
        if (len) memcpy((char *)Bytes_val(payload_v), buf, len);
    } else {
        payload_v = caml_alloc_string(0);
    }
    free(buf);
    sender_v = caml_copy_string(st.rc == POLYCALL_OK ? sender : "");
    id_v = caml_copy_string(st.rc == POLYCALL_OK ? mid : "");
    msg = caml_alloc_tuple(4);
    Store_field(msg, 0, sender_v);
    Store_field(msg, 1, id_v);
    Store_field(msg, 2, payload_v);
    Store_field(msg, 3, Val_long(st.rc == POLYCALL_E_TOO_LARGE ? (intnat)len : 0));
    CAMLreturn(with_status(&st, msg));
}

CAMLprim value caml_polycall_peer_cancel(value handle)
{
    CAMLparam1(handle);
    status_t st;
    capture(&st, polycall_peer_cancel((polycall_peer_t)Long_val(handle)));
    CAMLreturn(status_pair(&st));
}
