#pragma once
#include <memory>
#include <string>
#include <span>

class SHA1;

namespace utils
{
constexpr size_t SHA1_LEN = 40;

/// SHA-1 of bytes that arrive in pieces, so an input never has to be in memory
/// at once. The digest equals `genSha1` of all the pieces in order.
class Sha1 {
public:
    Sha1();
    ~Sha1();
    Sha1(const Sha1&)            = delete;
    Sha1& operator=(const Sha1&) = delete;

    void        update(std::span<const char>);
    std::string final();

private:
    std::unique_ptr<::SHA1> m_state;
};

std::string genSha1(std::span<const char>);
} // namespace utils
