// iNUTT.exe in the top folder: starts the real app from the "app" folder next to it,
// so the top folder holds only this file and that folder.
#include <windows.h>
#include <shellapi.h>

#include <iterator>
#include <string>

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  wchar_t self[MAX_PATH * 4];
  DWORD n = GetModuleFileNameW(nullptr, self, static_cast<DWORD>(std::size(self)));
  std::wstring dir(self, n);
  dir = dir.substr(0, dir.find_last_of(L"\\/"));
  const std::wstring appDir = dir + L"\\app";
  const std::wstring exe = appDir + L"\\iNUTT.exe";

  // Pass on anything the launcher was started with.
  std::wstring cmd = L"\"" + exe + L"\"";
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  for (int i = 1; argv && i < argc; i++) {
    cmd += L" \"";
    cmd += argv[i];
    cmd += L"\"";
  }
  if (argv) LocalFree(argv);

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (!CreateProcessW(exe.c_str(), cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, appDir.c_str(), &si, &pi)) {
    MessageBoxW(nullptr,
                L"iNUTT couldn't start because the \"app\" folder is missing next to iNUTT.exe.\n\n"
                L"Unzip the whole download first, then run iNUTT.exe from the unzipped folder.",
                L"iNUTT", MB_ICONERROR | MB_OK);
    return 1;
  }
  // The app's window takes the foreground, not this launcher.
  AllowSetForegroundWindow(pi.dwProcessId);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return 0;
}
