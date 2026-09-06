#include <chrono>
#include <vector>

#include "source/common/http/date_provider_impl.h"
#include "source/common/http/header_map_impl.h"
#include "source/common/thread_local/thread_local_impl.h"

#include "test/mocks/event/mocks.h"
#include "test/mocks/thread_local/mocks.h"
#include "test/test_common/printers.h"
#include "test/test_common/simulated_time_system.h"

#include "gmock/gmock.h"
#include "gtest/gtest.h"

using testing::_;
using testing::AnyNumber;
using testing::NiceMock;
using testing::StrictMock;

namespace Envoy {
namespace Http {

TEST(DateProviderImplTest, All) {
  Event::MockDispatcher dispatcher;
  NiceMock<ThreadLocal::MockInstance> tls;
  Event::MockTimer* timer = new Event::MockTimer(&dispatcher);
  EXPECT_CALL(*timer, enableTimer(std::chrono::milliseconds(500), _));

  TlsCachingDateProviderImpl provider(dispatcher, tls);
  TestResponseHeaderMapImpl headers;
  provider.setDateHeader(headers);
  EXPECT_NE(nullptr, headers.Date());

  EXPECT_CALL(*timer, enableTimer(std::chrono::milliseconds(500), _));
  timer->invokeCallback();

  headers.removeDate();
  provider.setDateHeader(headers);
  EXPECT_NE(nullptr, headers.Date());
}

// Reproduces date-refresh posts accumulating on a worker dispatcher that has been registered
// but has not started. Without the thread-local timer fix this expectation fails because each
// 500ms refresh posts another callback (7200 refreshes grow the queue from 2 to 7202).
TEST(DateProviderImplTest, RefreshDoesNotQueueUpdatesOnUnstartedWorker) {
  Event::SimulatedTimeSystem time_system;
  time_system.setSystemTime(SystemTime{});
  StrictMock<Event::MockDispatcher> main_dispatcher;
  StrictMock<Event::MockDispatcher> worker_dispatcher;
  ThreadLocal::InstanceImpl tls;
  std::vector<Event::PostCb> pending_callbacks;
  // Hold worker posts instead of executing them, as during blocked server initialization.
  EXPECT_CALL(worker_dispatcher, post(_)).Times(AnyNumber()).WillRepeatedly([&](Event::PostCb cb) {
    pending_callbacks.push_back(std::move(cb));
  });
  tls.registerThread(main_dispatcher, true);
  tls.registerThread(worker_dispatcher, false);

  auto* timer = new StrictMock<Event::MockTimer>(&main_dispatcher);
  EXPECT_CALL(*timer, enableTimer(std::chrono::milliseconds(500), _)).Times(7201);
  TlsCachingDateProviderImpl provider(main_dispatcher, tls);
  // One post registers the worker dispatcher, and one initializes the date cache.
  EXPECT_EQ(2, pending_callbacks.size());
  for (int i = 1; i <= 7200; ++i) {
    time_system.setSystemTime(SystemTime{} + std::chrono::milliseconds(500 * i));
    timer->invokeCallback();
  }
  EXPECT_EQ(2, pending_callbacks.size());
  TestResponseHeaderMapImpl headers;
  provider.setDateHeader(headers);
  EXPECT_EQ("Thu, 01 Jan 1970 01:00:00 GMT", headers.getDateValue());

  tls.shutdownGlobalThreading();
  tls.shutdownThread();
}

} // namespace Http
} // namespace Envoy
