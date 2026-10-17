#ifdef _WIN32
#define _CRT_SECURE_NO_WARNINGS
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include "CWindowsConsoleFixture.h"

struct SCTestConsole { HPCON console; HANDLE read, write, drain; PROCESS_INFORMATION child; };
static DWORD WINAPI drain_output(LPVOID pointer) {
    SCTestConsole *c = pointer; char buffer[8192]; DWORD n;
    while (ReadFile(c->read, buffer, sizeof(buffer), &n, NULL) && n) {}
    return 0;
}
SCTestConsole *sc_test_console_start(const uint16_t *exe, const uint16_t *result, int records) {
    SCTestConsole *c = calloc(1,sizeof(*c)); if (!c) return NULL;
    HANDLE input = NULL, output = NULL;
    STARTUPINFOEXW si; ZeroMemory(&si,sizeof(si)); si.StartupInfo.cb = sizeof(si);
    SIZE_T size = 0; int initialized = 0, ok = 0;
    if (!CreatePipe(&input,&c->write,NULL,0) || !CreatePipe(&c->read,&output,NULL,0)) goto done;
    COORD dimensions = {100,30};
    if (FAILED(CreatePseudoConsole(dimensions,input,output,0,&c->console))) goto done;
    CloseHandle(input); input = NULL; CloseHandle(output); output = NULL;
    c->drain = CreateThread(NULL,0,drain_output,c,0,NULL); if (!c->drain) goto done;
    InitializeProcThreadAttributeList(NULL,1,0,&size);
    si.lpAttributeList = malloc(size); if (!si.lpAttributeList) goto done;
    if (!InitializeProcThreadAttributeList(si.lpAttributeList,1,0,&size)) goto done;
    initialized = 1;
    if (!UpdateProcThreadAttribute(si.lpAttributeList,0,PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,c->console,sizeof(HPCON),NULL,NULL)) goto done;
    // Never inherit the SSH session's standard handles into the test console.
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    size_t length = wcslen((const wchar_t *)exe) + wcslen((const wchar_t *)result) + 80;
    wchar_t *command = calloc(length,sizeof(wchar_t)); if (!command) goto done;
    swprintf(command,length,L"\"%ls\" \"%ls\" %d",(const wchar_t *)exe,(const wchar_t *)result,records);
    ok = CreateProcessW((const wchar_t *)exe,command,NULL,NULL,FALSE,EXTENDED_STARTUPINFO_PRESENT,NULL,NULL,&si.StartupInfo,&c->child);
    free(command);
done:
    if (initialized) DeleteProcThreadAttributeList(si.lpAttributeList);
    free(si.lpAttributeList); if (input) CloseHandle(input); if (output) CloseHandle(output);
    if (!ok) { sc_test_console_close(c); return NULL; }
    return c;
}
uint32_t sc_test_console_pid(SCTestConsole *c) { return c->child.dwProcessId; }
int sc_test_console_finished(SCTestConsole *c) { return WaitForSingleObject(c->child.hProcess,0) == WAIT_OBJECT_0; }
void sc_test_console_close(SCTestConsole *c) {
    if (!c) return;
    if (c->child.hProcess) {
        if (WaitForSingleObject(c->child.hProcess,0) == WAIT_TIMEOUT) TerminateProcess(c->child.hProcess,0);
        WaitForSingleObject(c->child.hProcess,3000);
    }
    if (c->console) ClosePseudoConsole(c->console);
    if (c->write) CloseHandle(c->write);
    if (c->drain) { CancelSynchronousIo(c->drain); WaitForSingleObject(c->drain,3000); CloseHandle(c->drain); }
    if (c->read) CloseHandle(c->read);
    if (c->child.hThread) CloseHandle(c->child.hThread);
    if (c->child.hProcess) CloseHandle(c->child.hProcess);
    free(c);
}
int sc_test_console_reader(const uint16_t *result, int records) {
    SetConsoleCtrlHandler(NULL,TRUE);
    HANDLE input = CreateFileW(L"CONIN$",GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,0,NULL);
    HANDLE output = CreateFileW(L"CONOUT$",GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,0,NULL);
    if (input == INVALID_HANDLE_VALUE || output == INVALID_HANDLE_VALUE || !SetConsoleMode(input,0)) return 2;
    FlushConsoleInputBuffer(input);
    DWORD count = 0;
    const wchar_t *pattern = L"B13 synthetic console\r\nASCII known text\r\nKorean: \xD55C\xAE00\r\nCombining: e\x0301\r\nREADY";
    if (!WriteConsoleW(output,pattern,(DWORD)wcslen(pattern),&count,NULL)) return 2;
    FILE *file = _wfopen((const wchar_t *)result,L"wb"); if (!file) return 2;
    for (int i = 0; i < records;) {
        INPUT_RECORD r;
        if (!ReadConsoleInputW(input,&r,1,&count)) { fclose(file); return 2; }
        if (r.EventType != KEY_EVENT) continue;
        KEY_EVENT_RECORD k = r.Event.KeyEvent;
        fprintf(file,"%d,%u,%u,%u,%lu,%u\n",!!k.bKeyDown,k.wVirtualKeyCode,k.wVirtualScanCode,k.uChar.UnicodeChar,k.dwControlKeyState,k.wRepeatCount);
        fflush(file); i++;
    }
    // Stay alive and detect duplicates after the expected records, until the host closes us.
    ULONGLONG until = GetTickCount64() + 1500;
    while (GetTickCount64() < until) {
        INPUT_RECORD r; DWORD available = 0;
        if (!GetNumberOfConsoleInputEvents(input,&available)) break;
        if (available && ReadConsoleInputW(input,&r,1,&count) && r.EventType == KEY_EVENT) {
            fprintf(file,"EXTRA\n"); fflush(file);
        }
        Sleep(10);
    }
    fclose(file); CloseHandle(input); CloseHandle(output); return 0;
}
#endif
