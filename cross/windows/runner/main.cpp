#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shlobj.h>

#include <cstdio>
#include <string>

#include "flutter_window.h"
#include "utils.h"

// A start that fails before Flutter can show anything is written to
// %APPDATA%\SCYDE\iNUTT\native.log; the iNUTT.exe launcher shows it.
static std::wstring NativeLogPath() {
  PWSTR base = nullptr;
  std::wstring dir;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &base))) {
    dir = std::wstring(base) + L"\\SCYDE\\iNUTT";
    CoTaskMemFree(base);
    SHCreateDirectoryExW(nullptr, dir.c_str(), nullptr);
  }
  return dir + L"\\native.log";
}

static void NativeLog(const char* message) {
  FILE* f = nullptr;
  if (_wfopen_s(&f, NativeLogPath().c_str(), L"a") != 0 || !f) return;
  SYSTEMTIME t;
  GetLocalTime(&t);
  fprintf(f, "%04d-%02d-%02d %02d:%02d:%02d %s\n", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, message);
  fclose(f);
}

static LONG WINAPI OnCrash(EXCEPTION_POINTERS* info) {
  char module[MAX_PATH] = "unknown module";
  HMODULE handle = nullptr;
  void* address = info->ExceptionRecord->ExceptionAddress;
  if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         static_cast<LPCSTR>(address), &handle)) {
    GetModuleFileNameA(handle, module, MAX_PATH);
  }
  char line[MAX_PATH + 96];
  snprintf(line, sizeof(line), "crash 0x%08lX at %p in %s", info->ExceptionRecord->ExceptionCode, address, module);
  NativeLog(line);
  return EXCEPTION_CONTINUE_SEARCH;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  SetUnhandledExceptionFilter(OnCrash);
  NativeLog("starting");
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 820);
  if (!window.Create(L"iNUTT", origin, size)) {
    NativeLog("the window or the Flutter engine could not be created (is the data folder next to iNUTT.exe complete?)");
    return 3;
  }
  NativeLog("window created");
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
