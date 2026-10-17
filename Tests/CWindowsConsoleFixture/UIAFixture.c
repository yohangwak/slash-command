#ifdef _WIN32
#define CINTERFACE
#define COBJMACROS
#include <windows.h>
// MIDL emits external const definitions in C. Use the production TU's constants.
#define __UIA_OtherConstants_MODULE_DEFINED__
#define __UIA_PatternIds_MODULE_DEFINED__
#define __UIA_EventIds_MODULE_DEFINED__
#define __UIA_PropertyIds_MODULE_DEFINED__
#define __UIA_TextAttributeIds_MODULE_DEFINED__
#define __UIA_ControlTypeIds_MODULE_DEFINED__
#define __UIA_AnnotationTypes_MODULE_DEFINED__
#define __UIA_StyleIds_MODULE_DEFINED__
#define __UIA_LandmarkTypeIds_MODULE_DEFINED__
#define __UIA_HeadingLevelIds_MODULE_DEFINED__
#define __UIA_ChangeIds_MODULE_DEFINED__
#define __UIA_MetadataIds_MODULE_DEFINED__
#include <UIAutomationClient.h>
extern const long UIA_ClassNamePropertyId, UIA_TextPatternId;
#include <stdlib.h>
#include "CWindowsTerminal.h"
#include "CWindowsConsoleFixture.h"

// Compile the production reader against fake COM providers. No desktop/window is queried.
static int null_at, initialized, created, released, uninitialized, has_focus = 1, text_reads;
static HRESULT WINAPI fake_initialize(LPVOID reserved, DWORD mode) { initialized++; return S_OK; }
static void WINAPI fake_uninitialize(void) { uninitialized++; }
static HRESULT WINAPI fake_create(REFCLSID cls, LPUNKNOWN outer, DWORD flags, REFIID iid, LPVOID *out);
#define CoInitializeEx fake_initialize
#define CoUninitialize fake_uninitialize
#define CoCreateInstance fake_create
#define sc_uia_create test_uia_create
#define sc_uia_close test_uia_close
#define sc_focused_pane test_focused_pane
#define sc_pane test_pane
// Forward declarations because the production header has already been included.
SCUIA *test_uia_create(void);
void test_uia_close(SCUIA *);
int test_focused_pane(SCUIA *, uintptr_t, uint16_t **, uint16_t **, int *, int *);
int test_pane(SCUIA *, uintptr_t, const uint16_t *, uint16_t **, uint16_t **, int *, int *);
#include "../../Sources/CWindowsTerminal/UIA.c"

static IUIAutomation client;
static IUIAutomationElement element;
static IUIAutomationCondition condition;
static IUIAutomationElementArray elements;
static IUIAutomationTextPattern pattern;
static IUIAutomationTextRangeArray ranges;
static IUIAutomationTextRange range;
static ULONG WINAPI release_client(IUIAutomation *self) { released++; return 1; }
static ULONG WINAPI release_element(IUIAutomationElement *self) { return 1; }
static ULONG WINAPI release_condition(IUIAutomationCondition *self) { return 1; }
static ULONG WINAPI release_elements(IUIAutomationElementArray *self) { return 1; }
static ULONG WINAPI release_pattern(IUIAutomationTextPattern *self) { return 1; }
static ULONG WINAPI release_ranges(IUIAutomationTextRangeArray *self) { return 1; }
static ULONG WINAPI release_range(IUIAutomationTextRange *self) { return 1; }
static HRESULT WINAPI from_handle(IUIAutomation *self, UIA_HWND window, IUIAutomationElement **out) { *out = null_at == 1 ? NULL : &element; return S_OK; }
static HRESULT WINAPI property(IUIAutomation *self, PROPERTYID id, VARIANT v, IUIAutomationCondition **out) { *out = null_at == 2 ? NULL : &condition; return S_OK; }
static HRESULT WINAPI find_all(IUIAutomationElement *self, enum TreeScope scope, IUIAutomationCondition *c, IUIAutomationElementArray **out) { *out = null_at == 3 ? NULL : &elements; return S_OK; }
static HRESULT WINAPI elements_length(IUIAutomationElementArray *self, int *out) { *out = 1; return S_OK; }
static HRESULT WINAPI get_element(IUIAutomationElementArray *self, int i, IUIAutomationElement **out) { *out = null_at == 4 ? NULL : &element; return S_OK; }
static HRESULT WINAPI get_focus(IUIAutomationElement *self, BOOL *out) { *out = has_focus ? TRUE : FALSE; return S_OK; }
static HRESULT WINAPI runtime_id(IUIAutomationElement *self, SAFEARRAY **out) {
    *out = SafeArrayCreateVector(VT_I4, 0, 1);
    LONG index = 0, value = 42; return SafeArrayPutElement(*out, &index, &value);
}
static HRESULT WINAPI get_pattern(IUIAutomationElement *self, PATTERNID id, REFIID iid, void **out) { *out = null_at == 5 ? NULL : &pattern; return S_OK; }
static HRESULT WINAPI visible_ranges(IUIAutomationTextPattern *self, IUIAutomationTextRangeArray **out) { *out = null_at == 6 ? NULL : &ranges; return S_OK; }
static HRESULT WINAPI ranges_length(IUIAutomationTextRangeArray *self, int *out) { *out = 1; return S_OK; }
static HRESULT WINAPI get_range(IUIAutomationTextRangeArray *self, int i, IUIAutomationTextRange **out) { *out = null_at == 7 ? NULL : &range; return S_OK; }
static HRESULT WINAPI get_text(IUIAutomationTextRange *self, int max, BSTR *out) { text_reads++; *out = null_at == 8 ? NULL : SysAllocString(L"first\nsecond\nthird"); return S_OK; }
static IUIAutomationVtbl client_vtable = { .Release = release_client, .ElementFromHandle = from_handle, .CreatePropertyCondition = property };
static IUIAutomationElementVtbl element_vtable = { .Release = release_element, .FindAll = find_all, .get_CurrentHasKeyboardFocus = get_focus, .GetRuntimeId = runtime_id, .GetCurrentPatternAs = get_pattern };
static IUIAutomationConditionVtbl condition_vtable = { .Release = release_condition };
static IUIAutomationElementArrayVtbl elements_vtable = { .Release = release_elements, .get_Length = elements_length, .GetElement = get_element };
static IUIAutomationTextPatternVtbl pattern_vtable = { .Release = release_pattern, .GetVisibleRanges = visible_ranges };
static IUIAutomationTextRangeArrayVtbl ranges_vtable = { .Release = release_ranges, .get_Length = ranges_length, .GetElement = get_range };
static IUIAutomationTextRangeVtbl range_vtable = { .Release = release_range, .GetText = get_text };
static HRESULT WINAPI fake_create(REFCLSID cls, LPUNKNOWN outer, DWORD flags, REFIID iid, LPVOID *out) {
    created++;
    client.lpVtbl = &client_vtable; element.lpVtbl = &element_vtable; condition.lpVtbl = &condition_vtable;
    elements.lpVtbl = &elements_vtable; pattern.lpVtbl = &pattern_vtable; ranges.lpVtbl = &ranges_vtable; range.lpVtbl = &range_vtable;
    *out = null_at == 9 ? NULL : &client; return S_OK;
}
int sc_test_uia_null(int stage) {
    null_at = stage;
    SCUIA *c = test_uia_create();
    if (stage == 9) return c == NULL;
    if (!c) return 0;
    uint16_t *text = NULL, *identity = NULL; int panes = 0, focused = 0;
    int ok = test_focused_pane(c, 123, &text, &identity, &panes, &focused);
    int passed = ok == 0 && !text && !identity;
    free(text); free(identity); test_uia_close(c); return passed;
}
// Once the tray is in front no pane has focus: the menu selects the pane by the runtime ID seen earlier.
int sc_test_uia_select(void) {
    null_at = 0; text_reads = 0;
    SCUIA *c = test_uia_create(); if (!c) return 0;
    has_focus = 0;
    uint16_t *text = NULL, *identity = NULL; int panes = 0, matched = 0, passed = 1;
    if (test_focused_pane(c, 123, &text, &identity, &panes, &matched) || matched != 0 || text || identity) passed = 0;
    if (!test_pane(c, 123, (const uint16_t *)L"42/", &text, &identity, &panes, &matched) || matched != 1 || !text || !identity
        || wcscmp((wchar_t *)identity, L"42/")) passed = 0;
    free(text); free(identity); text = identity = NULL;
    if (test_pane(c, 123, (const uint16_t *)L"43/", &text, &identity, &panes, &matched) || matched != 0 || text || identity) passed = 0;
    has_focus = 1; int reads = text_reads;
    if (!test_pane(c, 123, NULL, NULL, &identity, &panes, &matched) || !identity || wcscmp((wchar_t *)identity, L"42/") || text_reads != reads) passed = 0;
    free(identity); test_uia_close(c);
    return passed;
}
int sc_test_uia_reuse(int reads, double *milliseconds) {
    initialized = created = released = uninitialized = 0; null_at = 0;
    SCUIA *c = test_uia_create(); if (!c) return 0;
    LARGE_INTEGER frequency, begin, end; QueryPerformanceFrequency(&frequency); QueryPerformanceCounter(&begin);
    int ok = 1;
    for (int i = 0; i < reads; i++) {
        uint16_t *text = NULL, *identity = NULL; int panes = 0, focused = 0;
        if (!test_focused_pane(c, 123, &text, &identity, &panes, &focused) || !text || !identity || panes != 1 || focused != 1) ok = 0;
        free(text); free(identity);
    }
    QueryPerformanceCounter(&end); test_uia_close(c);
    *milliseconds = (double)(end.QuadPart - begin.QuadPart) * 1000.0 / frequency.QuadPart / reads;
    return ok && initialized == 1 && created == 1 && released == 1 && uninitialized == 1;
}
#endif
