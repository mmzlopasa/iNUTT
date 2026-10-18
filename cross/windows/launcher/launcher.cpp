// iNUTT.exe in the top folder: starts the real app from the "app" folder next to it,
// so the top folder holds only this file and that folder.
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>

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
    const DWORD err = GetLastError();
    std::wstring text = GetFileAttributesW(exe.c_str()) == INVALID_FILE_ATTRIBUTES
        ? std::wstring(L"iNUTT couldn't start because the \"app\" folder is missing next to iNUTT.exe.\n\n"
          L"Unzip the whole download first, then run iNUTT.exe from the unzipped folder.")
        : L"Windows refused to start app\\iNUTT.exe (error " + std::to_wstring(err) +
          L"). An antivirus may be blocking it.\n\nPlease send a screenshot of this message.";
    MessageBoxW(nullptr, text.c_str(), L"iNUTT", MB_ICONERROR | MB_OK);
    return 1;
  }
  // The app's window takes the foreground, not this launcher.
  AllowSetForegroundWindow(pi.dwProcessId);
  CloseHandle(pi.hThread);
  // If the app closes on its own while starting, say why instead of leaving nothing on screen.
  DWORD code = 0;
  if (WaitForSingleObject(pi.hProcess, 20000) == WAIT_OBJECT_0 && GetExitCodeProcess(pi.hProcess, &code) && code != 0) {
    std::wstring text = L"iNUTT closed while starting (code 0x";
    wchar_t hex[16];
    swprintf_s(hex, L"%08lX", code);
    text += hex;
    text += L").\n\n";
    wchar_t* base = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &base))) {
      std::wstring log = std::wstring(base) + L"\\SCYDE\\iNUTT\\native.log";
      CoTaskMemFree(base);
      HANDLE f = CreateFileW(log.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
      if (f != INVALID_HANDLE_VALUE) {
        LARGE_INTEGER size{};
        GetFileSizeEx(f, &size);
        const LONGLONG take = size.QuadPart < 1200 ? size.QuadPart : 1200;
        LARGE_INTEGER at{};
        at.QuadPart = size.QuadPart - take;
        SetFilePointerEx(f, at, nullptr, FILE_BEGIN);
        std::string tail(static_cast<size_t>(take), '\0');
        DWORD got = 0;
        ReadFile(f, tail.data(), static_cast<DWORD>(take), &got, nullptr);
        CloseHandle(f);
        tail.resize(got);
        text += std::wstring(tail.begin(), tail.end());
      }
    }
    text += L"\nPlease send a screenshot of this message.";
    MessageBoxW(nullptr, text.c_str(), L"iNUTT", MB_ICONERROR | MB_OK);
  }
  CloseHandle(pi.hProcess);
  return 0;
}
