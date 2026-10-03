#ifndef OCAML_POLYCALL_H
#define OCAML_POLYCALL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* polycall_ffi_run_config(config_path, 1); returns a POLYCALL_* status. */
int32_t ocaml_polycall_run_config(const char *config_path);

#ifdef __cplusplus
}
#endif

#endif
