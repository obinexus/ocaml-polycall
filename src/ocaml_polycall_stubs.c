#include "ocaml_polycall.h"

#include <caml/memory.h>
#include <caml/mlvalues.h>

CAMLprim value caml_ocaml_polycall_run_config(value config_path) {
    int32_t status;

    CAMLparam1(config_path);
    status = ocaml_polycall_run_config(String_val(config_path));
    CAMLreturn(Val_long((intnat)status));
}
