CC ?= gcc
AR ?= ar
OCAMLC ?= ocamlc

CPPFLAGS ?=
CPPFLAGS += -Iinclude -Igenerated
CFLAGS ?= -O2
CFLAGS += -std=c11 -Wall -Wextra -Wpedantic
OCAMLFLAGS ?= -g

BUILD_DIR := build
OCAML_DIR := $(BUILD_DIR)/ocaml
LIB_DIR := lib
ADAPTER_OBJ := $(BUILD_DIR)/ocaml_polycall.o
MOCK_OBJ := $(BUILD_DIR)/polycall_ffi_mock.o
STUB_OBJ := $(BUILD_DIR)/ocaml_polycall_stubs.o
STATIC_LIB := $(LIB_DIR)/libocaml_polycall.a
NATIVE_TEST_BIN := $(BUILD_DIR)/ocaml_polycall_adapter_test
OCAML_CMI := $(OCAML_DIR)/polycall.cmi
OCAML_CMO := $(OCAML_DIR)/polycall.cmo
OCAML_TEST_CMO := $(OCAML_DIR)/ocaml_polycall_smoke.cmo
OCAML_TEST_BIN := $(BUILD_DIR)/ocaml_polycall_smoke

ifeq ($(OS),Windows_NT)
EXE_EXT := .exe
OCAMLC_PATH := $(shell where $(OCAMLC) 2>nul)
else
EXE_EXT :=
OCAMLC_PATH := $(shell command -v $(OCAMLC) 2>/dev/null)
endif

NATIVE_TEST_BIN := $(NATIVE_TEST_BIN)$(EXE_EXT)
OCAML_TEST_BIN := $(OCAML_TEST_BIN)$(EXE_EXT)

.DEFAULT_GOAL := all

.PHONY: all
all: $(STATIC_LIB)

$(BUILD_DIR) $(OCAML_DIR) $(LIB_DIR):
ifeq ($(OS),Windows_NT)
	@if not exist "$@" mkdir "$@"
else
	@mkdir -p $@
endif

$(ADAPTER_OBJ): src/ocaml_polycall.c include/ocaml_polycall.h generated/polycall/polycall_ffi.h | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@

$(MOCK_OBJ): tests/polycall_ffi_mock.c tests/polycall_ffi_mock.h | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) -Itests $(CFLAGS) -c $< -o $@

$(STATIC_LIB): $(ADAPTER_OBJ) | $(LIB_DIR)
	$(AR) rcs $@ $^

$(NATIVE_TEST_BIN): src/ocaml_polycall.c tests/polycall_ffi_mock.c tests/ocaml_polycall_adapter_test.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) -Itests $(CFLAGS) $^ -o $@

.PHONY: test
test: $(NATIVE_TEST_BIN)
	$(NATIVE_TEST_BIN)

$(OCAML_CMI): src/polycall.mli | $(OCAML_DIR)
	$(OCAMLC) $(OCAMLFLAGS) -c -o $@ $<

$(OCAML_CMO): src/polycall.ml $(OCAML_CMI) | $(OCAML_DIR)
	$(OCAMLC) $(OCAMLFLAGS) -I$(OCAML_DIR) -c -o $@ $<

$(STUB_OBJ): src/ocaml_polycall_stubs.c include/ocaml_polycall.h | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) -I"$(shell $(OCAMLC) -where)" $(CFLAGS) -c $< -o $@

.PHONY: ocaml
ocaml: $(OCAML_CMO) $(STUB_OBJ) $(STATIC_LIB)

$(OCAML_TEST_CMO): tests/ocaml_polycall_smoke.ml $(OCAML_CMI) | $(OCAML_DIR)
	$(OCAMLC) $(OCAMLFLAGS) -I$(OCAML_DIR) -c -o $@ $<

.PHONY: test-ocaml
test-ocaml: $(OCAML_CMO) $(OCAML_TEST_CMO) $(STUB_OBJ) $(ADAPTER_OBJ) $(MOCK_OBJ)
	$(OCAMLC) $(OCAMLFLAGS) -custom -I$(OCAML_DIR) -o $(OCAML_TEST_BIN) \
		$(OCAML_CMO) $(OCAML_TEST_CMO) $(STUB_OBJ) $(ADAPTER_OBJ) $(MOCK_OBJ)
	$(OCAML_TEST_BIN)

.PHONY: test-ocaml-if-available
ifneq ($(strip $(OCAMLC_PATH)),)
test-ocaml-if-available: test-ocaml
else
test-ocaml-if-available:
	@echo OCaml compiler not found; skipping OCaml smoke test
endif

.PHONY: verify-dry
verify-dry:
ifeq ($(OS),Windows_NT)
	powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-dry.ps1
else
	sh scripts/verify-dry.sh
endif

.PHONY: clean
clean:
ifeq ($(OS),Windows_NT)
	@if exist "$(BUILD_DIR)" rmdir /s /q "$(BUILD_DIR)"
	@if exist "$(LIB_DIR)" rmdir /s /q "$(LIB_DIR)"
	@if exist "_build" rmdir /s /q "_build"
else
	rm -rf $(BUILD_DIR) $(LIB_DIR) _build
endif

-include $(ADAPTER_OBJ:.o=.d)
