// loadtest: publish N messages split across T threads.
// Each std::thread has its own NATS connection.
//
//   ./loadtest                                   # 1000 messages, 4 threads
//   ./loadtest --n 100000 --threads 16 --size 512
#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>

#include "common.hpp"

int main(int argc, char** argv) {
    common::Args args(argc, argv,
        {{"url", common::defaultUrl()}, {"subject", common::kDefaultSubject},
         {"n", "1000"}, {"threads", "4"}, {"size", "64"}},
        "usage: loadtest [--url URL] [--subject S] [--n MESSAGES] [--threads T] [--size BYTES]");

    const std::string url = args.str("url"), subject = args.str("subject");
    const long long total = args.num("n"), size = args.num("size");
    long long threads = args.num("threads");
    if (total < 1 || threads < 1 || size < 0) {
        std::cerr << "--n and --threads must be >= 1, --size must be >= 0" << std::endl;
        return 2;
    }
    if (threads > total) threads = total;

    const std::string data(static_cast<size_t>(size), 'x');
    std::atomic<long long> sent{0}, failed{0};

    std::printf("load test: %lld messages, %lld threads, %lld-byte payload -> [%s] at %s\n",
                total, threads, size, subject.c_str(), url.c_str());
    std::fflush(stdout);

    const auto start = std::chrono::steady_clock::now();
    std::vector<std::thread> pool;
    for (long long t = 0; t < threads; ++t) {
        // Spread the total evenly; the first (total % threads) workers send one extra.
        const long long n = total / threads + (t < total % threads ? 1 : 0);
        pool.emplace_back([&, t, n] {
            const std::string sender = "cpp-loadtest-" + std::to_string(t);
            natsConnection* nc = nullptr;
            natsStatus s = natsConnection_ConnectTo(&nc, url.c_str());
            if (s != NATS_OK) {
                std::fprintf(stderr, "thread %lld: connect: %s\n", t, natsStatus_GetText(s));
                failed += n;
                return;
            }
            for (long long i = 1; i <= n; ++i) {
                const std::string payload = common::envelope(i, sender, data);
                s = natsConnection_Publish(nc, subject.c_str(), payload.data(),
                                           static_cast<int>(payload.size()));
                if (s == NATS_OK) ++sent; else ++failed;
            }
            // Publish only buffers; Flush waits until the server has everything.
            s = natsConnection_FlushTimeout(nc, 30000);
            if (s != NATS_OK)
                std::fprintf(stderr, "thread %lld: flush: %s\n", t, natsStatus_GetText(s));
            natsConnection_Destroy(nc);
        });
    }
    for (auto& th : pool) th.join();
    const double elapsed =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    nats_Close();

    std::printf("sent %lld messages (%lld failed) in %.3fs = %.0f msgs/sec\n",
                sent.load(), failed.load(), elapsed, sent.load() / elapsed);
    return failed.load() > 0 ? 1 : 0;
}
