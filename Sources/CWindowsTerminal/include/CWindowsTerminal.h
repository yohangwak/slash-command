#pragma once
#include <stdint.h>
#include <stddef.h>
// All returned buffers belong to the caller; release with sc_free.
void sc_free(void *buffer);
#ifdef _WIN32
typedef struct SCChannel SCChannel;
typedef struct SCConsole SCConsole;
typedef struct SCUIA SCUIA;
typedef struct { uint32_t pid; uint64_t start; } SCMember;
typedef struct { uint16_t vk, scan, character; uint32_t modifiers; } SCKey;
SCUIA *sc_uia_create(void);
void sc_uia_close(SCUIA *);
int sc_focused_pane(SCUIA *, uintptr_t window, uint16_t **text, uint16_t **identity, int *panes, int *focused);
int sc_pane(SCUIA *, uintptr_t window, const uint16_t *want, uint16_t **text, uint16_t **identity, int *panes, int *matched);
SCChannel *sc_channel_start(const uint16_t *exe, uint32_t pid);
char *sc_channel_request(SCChannel *, const char *request, uint32_t timeout_ms);
int sc_channel_close(SCChannel *);
SCConsole *sc_console_attach(uint32_t pid);
int sc_console_pin(SCConsole *, uint32_t pid, uint64_t start);
int sc_console_valid(SCConsole *);
SCMember *sc_console_members(SCConsole *, uint32_t *count);
uint16_t *sc_console_screen(SCConsole *);
int sc_console_key(SCConsole *, SCKey key);
char *sc_console_receive(SCConsole *);
int sc_console_reply(SCConsole *, const char *reply);
void sc_console_close(SCConsole *);
#endif
