/*
 * The binding's documented C entry point: run_config(path) is
 * polycall_ffi_run_config(path, 1) -- strict validation for running with
 * this build (Binding ABI v1, <polycall.h>).
 */
#include "ocaml_polycall.h"

#include <polycall.h>

int32_t ocaml_polycall_run_config(const char *config_path) {
    return (int32_t)polycall_ffi_run_config(config_path, 1);
}
