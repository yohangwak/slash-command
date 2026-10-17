#ifdef _WIN32
#define _CRT_SECURE_NO_WARNINGS
#define _WIN32_WINNT 0x0A00
#define CINTERFACE
#define COBJMACROS
#include <windows.h>
#include <UIAutomationClient.h>
#include <stdlib.h>
#include <stdio.h>
#include <wchar.h>
#include "CWindowsTerminal.h"

// One COM apartment/client per switch, owned and used on the switch's worker thread.
struct SCUIA { IUIAutomation *client; DWORD thread; };
SCUIA *sc_uia_create(void) {
    HRESULT init = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(init)) return NULL;
    SCUIA *context = calloc(1, sizeof(*context));
    if (!context) { CoUninitialize(); return NULL; }
    context->thread = GetCurrentThreadId();
    if (FAILED(CoCreateInstance(&CLSID_CUIAutomation, NULL, CLSCTX_INPROC_SERVER, &IID_IUIAutomation, (void **)&context->client)) || !context->client) {
        sc_uia_close(context); return NULL;
    }
    return context;
}
void sc_uia_close(SCUIA *context) {
    if (!context) return;
    if (context->client) IUIAutomation_Release(context->client);
    CoUninitialize(); free(context);
}
// The runtime ID pins the actual control, so a same-window pane change is caught even if screens become identical.
static wchar_t *runtime_token(IUIAutomationElement *element) {
    SAFEARRAY *runtime = NULL; wchar_t *token = NULL; LONG lower, upper;
    if (FAILED(IUIAutomationElement_GetRuntimeId(element, &runtime)) || !runtime || SafeArrayGetDim(runtime) != 1) goto done;
    if (FAILED(SafeArrayGetLBound(runtime, 1, &lower)) || FAILED(SafeArrayGetUBound(runtime, 1, &upper)) || upper < lower || upper - lower > 128) goto done;
    token = calloc((size_t)(upper - lower + 1) * 16 + 1, sizeof(wchar_t));
    if (!token) goto done;
    for (LONG i = lower; i <= upper; i++) {
        int part = 0; wchar_t buffer[20];
        if (FAILED(SafeArrayGetElement(runtime, &i, &part))) { free(token); token = NULL; goto done; }
        swprintf(buffer, 20, L"%d/", part); wcscat(token, buffer);
    }
done:
    if (runtime) SafeArrayDestroy(runtime);
    return token;
}
// No window messages or synthetic keyboard input. UIA is read-only.
// Selects the pane with keyboard focus, or with `want` the pane with that runtime ID whether or not it has focus.
// With text NULL only the identity is read.
int sc_pane(SCUIA *context, uintptr_t window, const uint16_t *want, uint16_t **text, uint16_t **identity, int *panes, int *matched) {
    if (text) *text = NULL;
    *identity = NULL; *panes = 0; *matched = 0;
    if (!context || !context->client || context->thread != GetCurrentThreadId()) return 0;
    IUIAutomation *uia = context->client;
    IUIAutomationElement *root = NULL, *selected = NULL;
    IUIAutomationCondition *condition = NULL;
    IUIAutomationElementArray *elements = NULL;
    IUIAutomationTextPattern *pattern = NULL;
    IUIAutomationTextRangeArray *ranges = NULL;
    wchar_t *joined = NULL, *token = NULL;
    int ok = 0, length = 0;
    if (FAILED(IUIAutomation_ElementFromHandle(uia, (UIA_HWND)window, &root)) || !root) goto done;
    VARIANT value; VariantInit(&value); value.vt = VT_BSTR; value.bstrVal = SysAllocString(L"TermControl");
    if (!value.bstrVal) goto done;
    HRESULT hr = IUIAutomation_CreatePropertyCondition(uia, UIA_ClassNamePropertyId, value, &condition);
    VariantClear(&value);
    if (FAILED(hr) || !condition || FAILED(IUIAutomationElement_FindAll(root, TreeScope_Descendants, condition, &elements)) || !elements) goto done;
    if (FAILED(IUIAutomationElementArray_get_Length(elements, panes))) goto done;
    for (int i = 0; i < *panes; i++) {
        IUIAutomationElement *element = NULL; BOOL focus = FALSE;
        hr = IUIAutomationElementArray_GetElement(elements, i, &element);
        if (FAILED(hr) || !element) { if (element) IUIAutomationElement_Release(element); goto done; }
        if (want) {
            wchar_t *candidate = runtime_token(element);
            focus = candidate && !wcscmp(candidate, (const wchar_t *)want);
            free(candidate); hr = S_OK;
        } else hr = IUIAutomationElement_get_CurrentHasKeyboardFocus(element, &focus);
        if (SUCCEEDED(hr) && focus) {
            ++*matched;
            if (selected) IUIAutomationElement_Release(selected);
            selected = element;
        } else IUIAutomationElement_Release(element);
        if (FAILED(hr)) goto done;
    }
    if (*matched != 1 || !selected) goto done;
    if (!(token = runtime_token(selected))) goto done;
    if (!text) { *identity = (uint16_t *)token; token = NULL; ok = 1; goto done; }
    if (FAILED(IUIAutomationElement_GetCurrentPatternAs(selected, UIA_TextPatternId, &IID_IUIAutomationTextPattern, (void **)&pattern)) || !pattern) goto done;
    if (FAILED(IUIAutomationTextPattern_GetVisibleRanges(pattern, &ranges)) || !ranges || FAILED(IUIAutomationTextRangeArray_get_Length(ranges, &length)) || length < 1 || length > 4096) goto done;
    size_t used = 0;
    joined = calloc(1, sizeof(wchar_t));
    if (!joined) goto done;
    for (int i = 0; i < length; i++) {
        IUIAutomationTextRange *range = NULL; BSTR segment = NULL;
        hr = IUIAutomationTextRangeArray_GetElement(ranges, i, &range);
        if (FAILED(hr) || !range) { if (range) IUIAutomationTextRange_Release(range); goto done; }
        hr = IUIAutomationTextRange_GetText(range, -1, &segment);
        IUIAutomationTextRange_Release(range);
        if (FAILED(hr) || !segment) { if (segment) SysFreeString(segment); goto done; }
        size_t count = SysStringLen(segment);
        if (used + count > 1048576) { SysFreeString(segment); goto done; }
        wchar_t *grown = realloc(joined, (used + count + 1) * sizeof(wchar_t));
        if (!grown) { SysFreeString(segment); goto done; }
        joined = grown; memcpy(joined + used, segment, count * sizeof(wchar_t)); used += count; joined[used] = 0;
        SysFreeString(segment);
    }
    *text = (uint16_t *)joined; joined = NULL;
    *identity = (uint16_t *)token; token = NULL; ok = 1;
done:
    free(joined); free(token);
    if (ranges) IUIAutomationTextRangeArray_Release(ranges);
    if (pattern) IUIAutomationTextPattern_Release(pattern);
    if (selected) IUIAutomationElement_Release(selected);
    if (elements) IUIAutomationElementArray_Release(elements);
    if (condition) IUIAutomationCondition_Release(condition);
    if (root) IUIAutomationElement_Release(root);
    return ok;
}
int sc_focused_pane(SCUIA *context, uintptr_t window, uint16_t **text, uint16_t **identity, int *panes, int *focused) {
    return sc_pane(context, window, NULL, text, identity, panes, focused);
}

#endif
