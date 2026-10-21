#include "Utils/Sha.hpp"
#include <vog/sha1.hpp>

#include <algorithm>

namespace
{
// vog's SHA1 hashes a string through a stream over a copy of it, so it is fed
// bounded pieces rather than a whole input at once.
constexpr std::size_t kPieceBytes = 64 * 1024;
} // namespace

utils::Sha1::Sha1(): m_state(std::make_unique<::SHA1>()) {}

utils::Sha1::~Sha1() = default;

void utils::Sha1::update(std::span<const char> in) {
    while (! in.empty()) {
        const auto piece = in.first(std::min(in.size(), kPieceBytes));
        m_state->update(std::string(piece.data(), piece.size()));
        in = in.subspan(piece.size());
    }
}

std::string utils::Sha1::final() { return m_state->final(); }

std::string utils::genSha1(std::span<const char> in) {
    Sha1 sha1;
    sha1.update(in);
    return sha1.final();
}
