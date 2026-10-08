#ifndef RUNNER_ACCOUNT_SESSION_STORE_H_
#define RUNNER_ACCOUNT_SESSION_STORE_H_

#include <cstddef>
#include <optional>
#include <string>

namespace dropo {

enum class AccountSessionError { kNone, kInvalid, kUnavailable };

// User-bound DPAPI only. A custom directory is for isolated native smoke tests;
// production resolves the current user's LocalAppData known folder.
class AccountSessionStore {
 public:
  explicit AccountSessionStore(std::wstring directory = L"");
  static constexpr size_t kMaxTokenBytes = 16 * 1024;
  static constexpr size_t kMaxProtectedBytes = 64 * 1024;
  static bool ValidToken(const std::string& token);

  AccountSessionError Read(std::optional<std::string>* token) const;
  AccountSessionError Write(const std::string& token) const;
  AccountSessionError Clear() const;

 private:
  bool EnsureDirectory() const;
  std::wstring directory_;
  std::wstring path_;
};

}  // namespace dropo
#endif  // RUNNER_ACCOUNT_SESSION_STORE_H_
