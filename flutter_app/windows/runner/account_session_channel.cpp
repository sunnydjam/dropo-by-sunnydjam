#include "account_session_channel.h"

#include <windows.h>
#include <flutter/standard_method_codec.h>

namespace dropo {
namespace {
void Complete(AccountSessionError error,
              flutter::MethodResult<flutter::EncodableValue>* result) {
  if (error == AccountSessionError::kNone) {
    result->Success();
  } else {
    result->Error(error == AccountSessionError::kInvalid
                      ? "ACCOUNT_SESSION_INVALID" : "ACCOUNT_SESSION_UNAVAILABLE",
                  "Protected account session storage is unavailable.");
  }
}
}  // namespace

AccountSessionChannel::AccountSessionChannel(flutter::BinaryMessenger* messenger)
    : channel_(messenger, "dropo/account_session",
               &flutter::StandardMethodCodec::GetInstance()) {
  channel_.SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "read") {
      std::optional<std::string> token;
      const auto error = store_.Read(&token);
      if (error == AccountSessionError::kNone && token.has_value()) {
        result->Success(flutter::EncodableValue(*token));
        SecureZeroMemory(token->data(), token->size());
      } else {
        Complete(error, result.get());
      }
    } else if (call.method_name() == "write") {
      const auto* arguments = call.arguments();
      const auto* values = arguments == nullptr ? nullptr
          : std::get_if<flutter::EncodableMap>(arguments);
      const std::string* token = nullptr;
      if (values != nullptr) {
        const auto entry = values->find(flutter::EncodableValue("token"));
        if (entry != values->end()) token = std::get_if<std::string>(&entry->second);
      }
      Complete(token == nullptr ? AccountSessionError::kInvalid
                                : store_.Write(*token), result.get());
    } else if (call.method_name() == "clear") {
      Complete(store_.Clear(), result.get());
    } else {
      result->NotImplemented();
    }
  });
}

AccountSessionChannel::~AccountSessionChannel() {
  channel_.SetMethodCallHandler(nullptr);
}
}  // namespace dropo
