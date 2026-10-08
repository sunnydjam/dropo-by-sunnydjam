// Standalone native smoke test; never linked into or run by the application.
#include "../account_session_store.h"

#include <windows.h>

#include <algorithm>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

namespace {
int failures = 0;
int checks = 0;
void Check(bool passed, const char* label) {
  ++checks;
  if (!passed) {
    ++failures;
    std::cerr << "FAIL: " << label << '\n';
  }
}

std::vector<char> ReadCiphertext(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return {};
  const DWORD size = GetFileSize(file, nullptr);
  if (size == INVALID_FILE_SIZE || size > 64 * 1024) {
    CloseHandle(file);
    return {};
  }
  std::vector<char> bytes(size);
  DWORD count = 0;
  const bool read = ReadFile(file, bytes.data(), size, &count, nullptr) != FALSE;
  CloseHandle(file);
  return read && count == size ? bytes : std::vector<char>{};
}

bool WriteFixture(const std::wstring& path, const std::vector<char>& bytes) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD count = 0;
  const bool written = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()),
                                  &count, nullptr) != FALSE;
  CloseHandle(file);
  return written && count == bytes.size();
}
}  // namespace

int main() {
  WCHAR temporary[MAX_PATH]{};
  GUID guid;
  WCHAR suffix[40]{};
  if (GetTempPathW(MAX_PATH, temporary) == 0 || FAILED(CoCreateGuid(&guid)) ||
      StringFromGUID2(guid, suffix, 40) == 0) return 2;
  const std::wstring directory = std::wstring(temporary) + L"dropo-session-test-" + suffix;
  const std::wstring path = directory + L"\\account-session.dpapi";
  dropo::AccountSessionStore store(directory);
  using Error = dropo::AccountSessionError;
  std::optional<std::string> read;
  const std::string token = "synthetic-only.account-session-0123456789";

  Check(store.Read(&read) == Error::kNone && !read.has_value(), "absent read");
  Check(store.Clear() == Error::kNone, "absent clear");
  Check(store.Write(token) == Error::kNone, "DPAPI write");
  Check(store.Read(&read) == Error::kNone && read == token, "DPAPI round trip");
  auto ciphertext = ReadCiphertext(path);
  Check(!ciphertext.empty() && std::search(ciphertext.begin(), ciphertext.end(),
         token.begin(), token.end()) == ciphertext.end(), "no plaintext in file");

  Check(store.Write(token + "-replacement") == Error::kNone &&
         store.Read(&read) == Error::kNone && read == token + "-replacement",
         "atomic replacement");
  Check(store.Write("") == Error::kInvalid &&
         store.Write("contains space") == Error::kInvalid &&
         store.Write("line\nbreak") == Error::kInvalid &&
         store.Write(std::string(16385, 'x')) == Error::kInvalid,
         "invalid token bounds");
  Check(store.Read(&read) == Error::kNone && read == token + "-replacement",
         "invalid write preserves previous session");
  const std::string maximum(dropo::AccountSessionStore::kMaxTokenBytes, 'a');
  Check(store.Write(maximum) == Error::kNone && store.Read(&read) == Error::kNone &&
         read == maximum, "maximum token round trip");

  ciphertext = ReadCiphertext(path);
  if (!ciphertext.empty()) ciphertext.back() ^= 1;
  Check(WriteFixture(path, ciphertext), "tampered ciphertext fixture");
  Check(store.Read(&read) != Error::kNone && !read.has_value(),
         "tampering fails closed");
  Check(WriteFixture(path, std::vector<char>(65537, 0)), "oversized ciphertext fixture");
  Check(store.Read(&read) == Error::kInvalid && !read.has_value(),
         "oversized ciphertext fails closed");
  Check(store.Clear() == Error::kNone && store.Read(&read) == Error::kNone &&
         !read.has_value(), "logout clears session");
  Check(store.Clear() == Error::kNone, "repeated logout is safe");
  // This exact GUID test directory contains only our ciphertext fixtures. A
  // non-recursive removal also checks that atomic-write temporaries are gone.
  Check(RemoveDirectoryW(directory.c_str()) != FALSE, "no leftover temporary files");
  std::cout << "Protected account session checks: " << checks << ", failures: "
            << failures << '\n';
  return failures == 0 ? 0 : 1;
}
