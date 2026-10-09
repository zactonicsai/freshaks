// Shared helpers for the C++ clients: defaults, tiny flag parser, and the JSON
// message envelope (same shape as the Go and Python clients).
#pragma once

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <map>
#include <string>

#include <nats.h>

namespace common {

inline const char* kDefaultSubject = "demo.telemetry";

inline std::string defaultUrl() {
    const char* env = std::getenv("NATS_URL");
    return (env && *env) ? env : "nats://127.0.0.1:4222";
}

inline int64_t nowNanos() {
    using namespace std::chrono;
    return duration_cast<nanoseconds>(system_clock::now().time_since_epoch()).count();
}

// Escape a string for use inside JSON quotes.
inline std::string jsonEscape(const std::string& in) {
    std::string out;
    out.reserve(in.size());
    for (unsigned char c : in) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof buf, "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

// {"seq":1,"sender":"cpp-publisher","ts":1700000000000000000,"data":"..."}
inline std::string envelope(int64_t seq, const std::string& sender, const std::string& escapedData) {
    return "{\"seq\":" + std::to_string(seq) + ",\"sender\":\"" + sender +
           "\",\"ts\":" + std::to_string(nowNanos()) + ",\"data\":\"" + escapedData + "\"}";
}

// Minimal "--name value" / "--flag" parser. Unknown options print usage and exit.
class Args {
public:
    Args(int argc, char** argv, std::map<std::string, std::string> defaults, const std::string& usage)
        : values_(std::move(defaults)) {
        for (int i = 1; i < argc; ++i) {
            std::string key = argv[i];
            if (key.rfind("--", 0) == 0) key = key.substr(2);
            else if (key.rfind("-", 0) == 0) key = key.substr(1);
            if (key == "help" || key == "h" || !values_.count(key)) {
                std::cerr << usage << std::endl;
                std::exit(key == "help" || key == "h" ? 0 : 2);
            }
            if (values_[key] == "false" || values_[key] == "true") {
                values_[key] = "true";               // boolean flag, no value
            } else if (i + 1 < argc) {
                values_[key] = argv[++i];
            } else {
                std::cerr << "missing value for --" << key << "\n" << usage << std::endl;
                std::exit(2);
            }
        }
    }
    std::string str(const std::string& k) const { return values_.at(k); }
    long long num(const std::string& k) const {
        try {
            return std::stoll(values_.at(k));
        } catch (...) {
            std::cerr << "--" << k << " needs a number" << std::endl;
            std::exit(2);
        }
    }
    bool flag(const std::string& k) const { return values_.at(k) == "true"; }

private:
    std::map<std::string, std::string> values_;
};

// Print the NATS error and exit if a call failed.
inline void check(natsStatus s, const char* what) {
    if (s != NATS_OK) {
        std::cerr << what << ": " << natsStatus_GetText(s) << std::endl;
        std::exit(1);
    }
}

}  // namespace common
