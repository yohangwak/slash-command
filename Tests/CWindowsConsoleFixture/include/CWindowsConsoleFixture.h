#pragma once
#include <stdint.h>
#ifdef _WIN32
typedef struct SCTestConsole SCTestConsole;
SCTestConsole *sc_test_console_start(const uint16_t *exe, const uint16_t *result, int records);
uint32_t sc_test_console_pid(SCTestConsole *);
int sc_test_console_finished(SCTestConsole *);
void sc_test_console_close(SCTestConsole *);
int sc_test_console_reader(const uint16_t *result, int records);
int sc_test_uia_null(int stage);
int sc_test_uia_reuse(int reads, double *milliseconds);
#endif
