#ifndef RUNNER_ACCOUNT_SESSION_CHANNEL_H_
#define RUNNER_ACCOUNT_SESSION_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include "account_session_store.h"

namespace dropo {
class AccountSessionChannel {
 public:
  explicit AccountSessionChannel(flutter::BinaryMessenger* messenger);
  ~AccountSessionChannel();

 private:
  AccountSessionStore store_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
};
}  // namespace dropo
#endif  // RUNNER_ACCOUNT_SESSION_CHANNEL_H_
