#include "account_session_store.h"

#include <windows.h>
#include <dpapi.h>
#include <shlobj.h>

#include <utility>
#include <vector>

namespace dropo {
namespace {
constexpr char kEntropy[] = "dropo.account_session.v1";

DATA_BLOB Entropy() {
  return {static_cast<DWORD>(sizeof(kEntropy) - 1),
          reinterpret_cast<BYTE*>(const_cast<char*>(kEntropy))};
}

bool RegularFileOrAbsent(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    return GetLastError() == ERROR_FILE_NOT_FOUND;
  }
  return (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0;
}
}  // namespace

AccountSessionStore::AccountSessionStore(std::wstring directory)
    : directory_(std::move(directory)) {
  if (directory_.empty()) {
    PWSTR local_app_data = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE,
                                      nullptr, &local_app_data))) {
      directory_ = std::wstring(local_app_data) + L"\\dropo";
    }
    CoTaskMemFree(local_app_data);
  }
  if (!directory_.empty()) path_ = directory_ + L"\\account-session.dpapi";
}

bool AccountSessionStore::ValidToken(const std::string& token) {
  if (token.empty() || token.size() > kMaxTokenBytes) return false;
  for (const unsigned char value : token) {
    if (value < 0x21 || value > 0x7e) return false;
  }
  return true;
}

bool AccountSessionStore::EnsureDirectory() const {
  if (directory_.empty()) return false;
  if (!CreateDirectoryW(directory_.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) return false;
  const DWORD attributes = GetFileAttributesW(directory_.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
         (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
}

AccountSessionError AccountSessionStore::Read(
    std::optional<std::string>* token) const {
  token->reset();
  if (path_.empty()) return AccountSessionError::kUnavailable;
  const DWORD directory_attributes = GetFileAttributesW(directory_.c_str());
  if (directory_attributes != INVALID_FILE_ATTRIBUTES &&
      ((directory_attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
       (directory_attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)) {
    return AccountSessionError::kUnavailable;
  }
  const DWORD attributes = GetFileAttributesW(path_.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    const DWORD error = GetLastError();
    return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND
               ? AccountSessionError::kNone : AccountSessionError::kUnavailable;
  }
  if (!RegularFileOrAbsent(path_)) return AccountSessionError::kUnavailable;
  HANDLE file = CreateFileW(path_.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (file == INVALID_HANDLE_VALUE) return AccountSessionError::kUnavailable;
  LARGE_INTEGER size;
  if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 ||
      size.QuadPart > static_cast<LONGLONG>(kMaxProtectedBytes)) {
    CloseHandle(file);
    return AccountSessionError::kInvalid;
  }
  std::vector<BYTE> ciphertext(static_cast<size_t>(size.QuadPart));
  DWORD count = 0;
  const bool read = ReadFile(file, ciphertext.data(),
                             static_cast<DWORD>(ciphertext.size()), &count,
                             nullptr) != FALSE;
  CloseHandle(file);
  if (!read || count != ciphertext.size()) return AccountSessionError::kUnavailable;
  DATA_BLOB input{count, ciphertext.data()};
  DATA_BLOB output{};
  DATA_BLOB entropy = Entropy();
  if (!CryptUnprotectData(&input, nullptr, &entropy, nullptr, nullptr,
                         CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    return AccountSessionError::kUnavailable;
  }
  std::string value;
  if (output.cbData > 0 && output.cbData <= kMaxTokenBytes) {
    value.assign(reinterpret_cast<const char*>(output.pbData), output.cbData);
  }
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  if (!ValidToken(value)) {
    if (!value.empty()) SecureZeroMemory(value.data(), value.size());
    return AccountSessionError::kInvalid;
  }
  *token = std::move(value);
  return AccountSessionError::kNone;
}

AccountSessionError AccountSessionStore::Write(const std::string& token) const {
  if (!ValidToken(token)) return AccountSessionError::kInvalid;
  if (!EnsureDirectory() || !RegularFileOrAbsent(path_)) {
    return AccountSessionError::kUnavailable;
  }
  DATA_BLOB input{static_cast<DWORD>(token.size()),
                  reinterpret_cast<BYTE*>(const_cast<char*>(token.data()))};
  DATA_BLOB output{};
  DATA_BLOB entropy = Entropy();
  // Deliberately omit CRYPTPROTECT_LOCAL_MACHINE: other users cannot decrypt.
  if (!CryptProtectData(&input, L"Dropo account session", &entropy, nullptr,
                        nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    return AccountSessionError::kUnavailable;
  }
  if (output.cbData == 0 || output.cbData > kMaxProtectedBytes) {
    LocalFree(output.pbData);
    return AccountSessionError::kUnavailable;
  }
  GUID guid;
  WCHAR suffix[40]{};
  if (FAILED(CoCreateGuid(&guid)) || StringFromGUID2(guid, suffix, 40) == 0) {
    LocalFree(output.pbData);
    return AccountSessionError::kUnavailable;
  }
  const std::wstring temporary = directory_ + L"\\account-session-" + suffix + L".tmp";
  HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  bool committed = false;
  if (file != INVALID_HANDLE_VALUE) {
    DWORD count = 0;
    const bool written = WriteFile(file, output.pbData, output.cbData, &count,
                                  nullptr) != FALSE && count == output.cbData &&
                         FlushFileBuffers(file) != FALSE;
    CloseHandle(file);
    if (written) {
      committed = MoveFileExW(temporary.c_str(), path_.c_str(),
                              MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
    }
    if (!committed) DeleteFileW(temporary.c_str());
  }
  LocalFree(output.pbData);
  return committed ? AccountSessionError::kNone : AccountSessionError::kUnavailable;
}

AccountSessionError AccountSessionStore::Clear() const {
  if (path_.empty()) return AccountSessionError::kUnavailable;
  const DWORD directory_attributes = GetFileAttributesW(directory_.c_str());
  if (directory_attributes != INVALID_FILE_ATTRIBUTES &&
      ((directory_attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
       (directory_attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)) {
    return AccountSessionError::kUnavailable;
  }
  const DWORD attributes = GetFileAttributesW(path_.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    const DWORD error = GetLastError();
    return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND
               ? AccountSessionError::kNone : AccountSessionError::kUnavailable;
  }
  if (!RegularFileOrAbsent(path_)) return AccountSessionError::kUnavailable;
  if (DeleteFileW(path_.c_str())) return AccountSessionError::kNone;
  const DWORD error = GetLastError();
  return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND
             ? AccountSessionError::kNone : AccountSessionError::kUnavailable;
}
}  // namespace dropo
