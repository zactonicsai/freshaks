// publisher: send a fixed number of messages to a NATS subject.
//
//   ./publisher --count 5 --msg "hello"
#include <chrono>
#include <thread>

#include "common.hpp"

int main(int argc, char** argv) {
    common::Args args(argc, argv,
        {{"url", common::defaultUrl()}, {"subject", common::kDefaultSubject},
         {"count", "10"}, {"interval", "500"}, {"msg", "hello from c++"}},
        "usage: publisher [--url URL] [--subject S] [--count N] [--interval MS] [--msg TEXT]");

    const std::string url = args.str("url"), subject = args.str("subject");
    const long long count = args.num("count"), intervalMs = args.num("interval");
    const std::string data = common::jsonEscape(args.str("msg"));

    natsConnection* nc = nullptr;
    common::check(natsConnection_ConnectTo(&nc, url.c_str()), "connect");

    for (long long i = 1; i <= count; ++i) {
        const std::string payload = common::envelope(i, "cpp-publisher", data);
        common::check(natsConnection_Publish(nc, subject.c_str(), payload.data(),
                                             static_cast<int>(payload.size())), "publish");
        std::cout << "published [" << subject << "] " << payload << std::endl;
        if (i < count) std::this_thread::sleep_for(std::chrono::milliseconds(intervalMs));
    }

    // Flush makes sure everything reached the server before we exit.
    common::check(natsConnection_FlushTimeout(nc, 10000), "flush");

    natsConnection_Destroy(nc);
    nats_Close();
    return 0;
}
