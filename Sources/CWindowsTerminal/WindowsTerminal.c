#ifdef _WIN32
#define _CRT_SECURE_NO_WARNINGS
#define _WIN32_WINNT 0x0A00
#define CINTERFACE
#define COBJMACROS
#include <windows.h>
#include <stdlib.h>
#include <stdio.h>
#include <wchar.h>
#include "CWindowsTerminal.h"

void sc_free(void *p) { free(p); }

struct SCChannel { HANDLE input, output, process; };
static int put_line(HANDLE handle, const char *text) {
    DWORD n = 0; size_t size = strlen(text);
    return size < 4194304 && WriteFile(handle, text, (DWORD)size, &n, NULL) && n == size && WriteFile(handle, "\n", 1, &n, NULL) && n == 1;
}
static char *get_line(HANDLE handle, HANDLE process, DWORD timeout) {
    ULONGLONG deadline = GetTickCount64() + timeout;
    size_t used = 0, capacity = 1024; char *buffer = malloc(capacity);
    if (!buffer) return NULL;
    for (;;) {
        DWORD n = 0; char c;
        if (process) {
            DWORD available = 0;
            if (!PeekNamedPipe(handle, NULL, 0, NULL, &available, NULL)) break;
            if (!available) {
                if (GetTickCount64() >= deadline || WaitForSingleObject(process, 0) == WAIT_OBJECT_0) break;
                Sleep(2); continue;
            }
        }
        if (!ReadFile(handle, &c, 1, &n, NULL) || n != 1) break;
        if (c == '\n') { buffer[used] = 0; return buffer; }
        if (used + 1 >= capacity) {
            if (capacity >= 4194304) break;
            capacity *= 2; char *grown = realloc(buffer, capacity);
            if (!grown) break;
            buffer = grown;
        }
        buffer[used++] = c;
    }
    free(buffer); return NULL;
}
SCChannel *sc_channel_start(const uint16_t *exe, uint32_t pid) {
    SCChannel *c = calloc(1, sizeof(*c)); if (!c) return NULL;
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
    HANDLE read = NULL, write = NULL, error = INVALID_HANDLE_VALUE;
    STARTUPINFOEXW si; ZeroMemory(&si, sizeof(si)); si.StartupInfo.cb = sizeof(si);
    PROCESS_INFORMATION pi; ZeroMemory(&pi, sizeof(pi));
    SIZE_T size = 0; int initialized = 0, ok = 0;
    if (!CreatePipe(&read, &c->input, &sa, 0) || !CreatePipe(&c->output, &write, &sa, 0)) goto done;
    if (!SetHandleInformation(c->input, HANDLE_FLAG_INHERIT, 0) || !SetHandleInformation(c->output, HANDLE_FLAG_INHERIT, 0)) goto done;
    error = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, NULL);
    if (error == INVALID_HANDLE_VALUE) goto done;
    InitializeProcThreadAttributeList(NULL, 1, 0, &size);
    si.lpAttributeList = malloc(size); if (!si.lpAttributeList) goto done;
    if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &size)) goto done;
    initialized = 1;
    HANDLE handles[] = {read, write, error};
    if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles), NULL, NULL)) goto done;
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = read; si.StartupInfo.hStdOutput = write; si.StartupInfo.hStdError = error;
    size_t length = wcslen((const wchar_t *)exe) + 80;
    wchar_t *command = calloc(length, sizeof(wchar_t)); if (!command) goto done;
    swprintf(command, length, L"\"%ls\" __console-bridge %lu", (const wchar_t *)exe, (unsigned long)pid);
    ok = CreateProcessW((const wchar_t *)exe, command, NULL, NULL, TRUE, CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT, NULL, NULL, &si.StartupInfo, &pi);
    free(command);
    if (ok) { c->process = pi.hProcess; CloseHandle(pi.hThread); }
done:
    if (initialized) DeleteProcThreadAttributeList(si.lpAttributeList);
    free(si.lpAttributeList);
    if (read) CloseHandle(read); if (write) CloseHandle(write); if (error != INVALID_HANDLE_VALUE) CloseHandle(error);
    if (!ok) { sc_channel_close(c); return NULL; }
    return c;
}
char *sc_channel_request(SCChannel *c, const char *request, uint32_t timeout) {
    if (!c || !c->input || !put_line(c->input, request)) return NULL;
    return get_line(c->output, c->process, timeout);
}
int sc_channel_close(SCChannel *c) {
    if (!c) return 0;
    if (c->input) CloseHandle(c->input);
    int exited = 1;
    if (c->process) {
        exited = WaitForSingleObject(c->process, 2000) == WAIT_OBJECT_0;
        if (!exited) { TerminateProcess(c->process, 1); WaitForSingleObject(c->process, 2000); }
        CloseHandle(c->process);
    }
    if (c->output) CloseHandle(c->output);
    free(c); return exited;
}

struct SCConsole { HANDLE pipeIn, pipeOut, input, output, pinned; DWORD pid; uint64_t start; };
static uint64_t started(HANDLE process) {
    FILETIME c,e,k,u; if (!GetProcessTimes(process,&c,&e,&k,&u)) return 0;
    return ((uint64_t)c.dwHighDateTime << 32) | c.dwLowDateTime;
}
static DWORD *console_ids(uint32_t *count) {
    *count = 0; DWORD size = 64;
    for (int i = 0; i < 4; i++) {
        DWORD *ids = calloc(size, sizeof(DWORD)); if (!ids) return NULL;
        DWORD n = GetConsoleProcessList(ids, size);
        if (n && n <= size) {
            // The bridge is an implementation detail, not part of console identity.
            DWORD used = 0; for (DWORD j = 0; j < n; j++) if (ids[j] != GetCurrentProcessId()) ids[used++] = ids[j];
            *count = used; return ids;
        }
        free(ids); if (!n || n > 65536) return NULL; size = n;
    }
    return NULL;
}
SCMember *sc_console_members(SCConsole *c, uint32_t *count) {
    (void)c; *count = 0;
    uint32_t n = 0; DWORD *ids = console_ids(&n);
    if (!ids) return NULL;
    SCMember *members = calloc(n ? n : 1, sizeof(*members));
    if (!members) { free(ids); return NULL; }
    uint32_t used = 0;
    for (uint32_t i = 0; i < n; i++) {
        HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, ids[i]);
        uint64_t start = process ? started(process) : 0;
        if (process) CloseHandle(process);
        if (!start) {
            uint32_t current_n = 0; DWORD *current = console_ids(&current_n);
            if (!current) { free(ids); free(members); return NULL; }
            int present = 0;
            for (uint32_t j = 0; j < current_n; j++) if (current[j] == ids[i]) present = 1;
            free(current);
            if (!present) continue;
            // Still a member but unreadable: preserve it; the parent must refuse, never infer a remote shell.
        }
        members[used].pid = ids[i]; members[used].start = start; used++;
    }
    free(ids); *count = used; return members;
}
int sc_console_valid(SCConsole *c) {
    if (!c || !c->pinned || WaitForSingleObject(c->pinned,0) != WAIT_TIMEOUT || started(c->pinned) != c->start) return 0;
    uint32_t n = 0; DWORD *members = console_ids(&n); int found = 0;
    for (uint32_t i = 0; i < n; i++) if (members[i] == c->pid) found = 1;
    free(members); return found;
}
int sc_console_pin(SCConsole *c, uint32_t pid, uint64_t start) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid);
    if (!process) return 0;
    uint64_t actual = started(process);
    if (!actual || (start && start != actual)) { CloseHandle(process); return 0; }
    HANDLE old = c->pinned; DWORD oldpid = c->pid; uint64_t oldstart = c->start;
    c->pinned = process; c->pid = pid; c->start = actual;
    if (!sc_console_valid(c)) { c->pinned = old; c->pid = oldpid; c->start = oldstart; CloseHandle(process); return 0; }
    if (old) CloseHandle(old); return 1;
}
SCConsole *sc_console_attach(uint32_t pid) {
    SCConsole *c = calloc(1, sizeof(*c)); if (!c) return NULL;
    HANDLE self = GetCurrentProcess();
    if (!DuplicateHandle(self, GetStdHandle(STD_INPUT_HANDLE), self, &c->pipeIn, 0, FALSE, DUPLICATE_SAME_ACCESS) ||
        !DuplicateHandle(self, GetStdHandle(STD_OUTPUT_HANDLE), self, &c->pipeOut, 0, FALSE, DUPLICATE_SAME_ACCESS)) goto fail;
    // FreeConsole and AttachConsole reset control handlers; install after both too.
    SetConsoleCtrlHandler(NULL, TRUE); FreeConsole();
    if (!AttachConsole(pid)) goto fail;
    SetConsoleCtrlHandler(NULL, TRUE);
    c->input = CreateFileW(L"CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    c->output = CreateFileW(L"CONOUT$", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (c->input == INVALID_HANDLE_VALUE || c->output == INVALID_HANDLE_VALUE || !sc_console_pin(c, pid, 0)) goto fail;
    return c;
fail: sc_console_close(c); return NULL;
}
uint16_t *sc_console_screen(SCConsole *c) {
    if (!sc_console_valid(c)) return NULL;
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (!GetConsoleScreenBufferInfo(c->output, &info)) return NULL;
    int width = info.srWindow.Right - info.srWindow.Left + 1, height = info.srWindow.Bottom - info.srWindow.Top + 1;
    if (width < 1 || height < 1 || (size_t)width * height > 1048576) return NULL;
    // ReadConsoleOutputW also exposes continuation cells: skip them for Korean/wide characters.
    CHAR_INFO *cells = calloc((size_t)width * height, sizeof(*cells));
    wchar_t *text = calloc(((size_t)width + 1) * height + 1, sizeof(*text));
    if (!cells || !text) { free(cells); free(text); return NULL; }
    COORD size = {(SHORT)width, (SHORT)height}, origin = {0,0}; SMALL_RECT rect = info.srWindow;
    if (!ReadConsoleOutputW(c->output, cells, size, origin, &rect) || memcmp(&rect, &info.srWindow, sizeof(rect))) { free(cells); free(text); return NULL; }
    size_t used = 0;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            CHAR_INFO cell = cells[y * width + x];
            if (!(cell.Attributes & COMMON_LVB_TRAILING_BYTE)) text[used++] = cell.Char.UnicodeChar ? cell.Char.UnicodeChar : L' ';
        }
        text[used++] = L'\n';
    }
    free(cells); return (uint16_t *)text;
}
int sc_console_key(SCConsole *c, SCKey key) {
    if (!sc_console_valid(c)) return 0;
    INPUT_RECORD records[2]; ZeroMemory(records, sizeof(records));
    for (int i = 0; i < 2; i++) {
        records[i].EventType = KEY_EVENT; KEY_EVENT_RECORD *k = &records[i].Event.KeyEvent;
        k->bKeyDown = i == 0; k->wRepeatCount = 1; k->wVirtualKeyCode = key.vk;
        k->wVirtualScanCode = key.scan; k->uChar.UnicodeChar = key.character; k->dwControlKeyState = key.modifiers;
    }
    DWORD n = 0; return WriteConsoleInputW(c->input, records, 2, &n) && n == 2;
}
char *sc_console_receive(SCConsole *c) { return get_line(c->pipeIn, NULL, 0); }
int sc_console_reply(SCConsole *c, const char *reply) { return put_line(c->pipeOut, reply); }
void sc_console_close(SCConsole *c) {
    if (!c) return;
    HANDLE handles[] = {c->pipeIn,c->pipeOut,c->input,c->output,c->pinned};
    for (int i = 0; i < 5; i++) if (handles[i] && handles[i] != INVALID_HANDLE_VALUE) CloseHandle(handles[i]);
    FreeConsole(); free(c);
}
#endif
