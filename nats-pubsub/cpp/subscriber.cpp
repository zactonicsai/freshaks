// subscriber: receive messages from a NATS subject and print them.
//
//   ./subscriber                         # run until Ctrl-C
//   ./subscriber --expect 1000 --quiet   # count 1000, report rate, exit
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <thread>

#include "common.hpp"

namespace {

std::atomic<long long> g_received{0};
std::atomic<int64_t> g_first{0}, g_last{0};
std::atomic<bool> g_stop{false};
long long g_expect = 0;
bool g_quiet = false;

void onSignal(int) { g_stop = true; }

// Called by the NATS client library on its delivery thread, once per message.
void onMessage(natsConnection*, natsSubscription*, natsMsg* msg, void*) {
    const int64_t now = common::nowNanos();
    int64_t zero = 0;
    g_first.compare_exchange_strong(zero, now);
    g_last = now;
    const long long n = ++g_received;
    if (!g_quiet) {
        std::printf("received [%s] #%lld %.*s\n", natsMsg_GetSubject(msg), n,
                    natsMsg_GetDataLength(msg), natsMsg_GetData(msg));
        std::fflush(stdout);
    }
    if (g_expect > 0 && n >= g_expect) g_stop = true;
    natsMsg_Destroy(msg);
}

}  // namespace

int main(int argc, char** argv) {
    common::Args args(argc, argv,
        {{"url", common::defaultUrl()}, {"subject", common::kDefaultSubject},
         {"queue", ""}, {"expect", "0"}, {"quiet", "false"}},
        "usage: subscriber [--url URL] [--subject S] [--queue GROUP] [--expect N] [--quiet]");

    const std::string url = args.str("url"), subject = args.str("subject"), queue = args.str("queue");
    g_expect = args.num("expect");
    g_quiet = args.flag("quiet");

    natsConnection* nc = nullptr;
    natsSubscription* sub = nullptr;
    common::check(natsConnection_ConnectTo(&nc, url.c_str()), "connect");

    if (queue.empty())
        common::check(natsConnection_Subscribe(&sub, nc, subject.c_str(), onMessage, nullptr), "subscribe");
    else
        common::check(natsConnection_QueueSubscribe(&sub, nc, subject.c_str(), queue.c_str(),
                                                    onMessage, nullptr), "subscribe");
    // Lift the default pending-message cap so a fast load test is not dropped client-side.
    natsSubscription_SetPendingLimits(sub, -1, -1);
    // Flush so the subscription is registered on the server before we announce it.
    common::check(natsConnection_FlushTimeout(nc, 10000), "flush");
    std::cout << "listening on [" << subject << "] at " << url << std::endl;

    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);
    while (!g_stop) std::this_thread::sleep_for(std::chrono::milliseconds(20));

    natsSubscription_Destroy(sub);
    natsConnection_Destroy(nc);
    nats_Close();

    const long long n = g_received;
    std::printf("received %lld messages", n);
    const double elapsed = (g_last - g_first) / 1e9;
    if (n > 1 && elapsed > 0) std::printf(" in %.3fs (%.0f msgs/sec)", elapsed, n / elapsed);
    std::printf("\n");
    return 0;
}
