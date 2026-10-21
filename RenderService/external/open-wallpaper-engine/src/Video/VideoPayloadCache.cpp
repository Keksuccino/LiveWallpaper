#include "VideoPayloadCache.hpp"

#include "Fs/IBinaryStream.h"
#include "Utils/Logging.h"
#include "Utils/Sha.hpp"

#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <fstream>
#include <vector>

namespace wallpaper::video
{
namespace
{

constexpr std::size_t kStreamChunkBytes = 1024 * 1024;

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

/// Publishes the `size` bytes that `write` puts into a stream as the cache
/// entry named `digest`. A losing publisher keeps the winner's file and its
/// modification time, which the shared-session registry counts as part of the
/// file's identity.
template <typename Write>
std::filesystem::path Publish(std::string_view   debug_label,
                              std::string_view   extension,
                              const std::string& digest,
                              uintmax_t          size,
                              Write&&            write,
                              std::string*       error)
{
    std::error_code ec;
    const auto temp_dir = std::filesystem::temp_directory_path(ec) / "wallpaper-engine-video";
    if (! ec) std::filesystem::create_directories(temp_dir, ec);
    if (ec) {
        SetError(error, "failed to create temporary video cache directory");
        return {};
    }

    const auto media_path =
        temp_dir / (digest + (extension.empty() ? std::string(".mp4") : std::string(extension)));
    if (std::filesystem::exists(media_path, ec) && ! ec &&
        std::filesystem::file_size(media_path, ec) == size) {
        return media_path;
    }

    static std::atomic<uint64_t> staging_serial { 0 };
    const auto staging_path =
        temp_dir / (digest + "." + std::to_string(static_cast<long long>(getpid())) + "." +
                    std::to_string(staging_serial.fetch_add(1, std::memory_order_relaxed)) + ".part");
    std::ofstream output(staging_path, std::ios::binary | std::ios::trunc);
    if (! output.good()) {
        SetError(error, "failed to open temporary video cache file");
        return {};
    }

    const bool written = write(output);
    output.close();
    // The size on disk is the completion check: a short write is discarded
    // instead of reaching the published name.
    if (! written || ! output.good() || std::filesystem::file_size(staging_path, ec) != size || ec) {
        std::filesystem::remove(staging_path, ec);
        SetError(error, "failed to write temporary video cache file");
        return {};
    }

    std::filesystem::create_hard_link(staging_path, media_path, ec);
    if (ec) {
        if (std::filesystem::file_size(media_path, ec) == size && ! ec) {
            std::filesystem::remove(staging_path, ec);
            return media_path;
        }
        // Replaces an incomplete entry, or publishes on a file system without
        // hard links.
        std::filesystem::rename(staging_path, media_path, ec);
    }
    std::error_code remove_ec;
    std::filesystem::remove(staging_path, remove_ec);
    if (ec) {
        SetError(error, "failed to write temporary video cache file");
        return {};
    }

    LOG_INFO("prepared FFmpeg video payload cache for \"%s\": %s",
             std::string(debug_label).c_str(),
             media_path.string().c_str());
    return media_path;
}

} // namespace

std::filesystem::path PublishVideoPayload(std::string_view      debug_label,
                                          std::string_view      extension,
                                          std::span<const char> payload,
                                          std::string*          error)
{
    if (payload.empty()) {
        SetError(error, "video texture payload is empty");
        return {};
    }
    return Publish(
        debug_label,
        extension,
        utils::genSha1(payload),
        payload.size(),
        [&](std::ofstream& output) {
            output.write(payload.data(), static_cast<std::streamsize>(payload.size()));
            return output.good();
        },
        error);
}

std::filesystem::path PublishVideoPayload(std::string_view   debug_label,
                                          std::string_view   extension,
                                          fs::IBinaryStream& stream,
                                          std::string*       error)
{
    const isize size = stream.Size();
    if (size <= 0) {
        SetError(error, "video texture payload is empty");
        return {};
    }

    std::vector<char> chunk(std::min(static_cast<usize>(size), kStreamChunkBytes));
    // One pass over the stream, from its start to its end, a chunk at a time.
    const auto each_chunk = [&](auto&& consume) {
        if (! stream.SeekSet(0)) return false;
        for (isize left = size; left > 0;) {
            const usize wanted = std::min(chunk.size(), static_cast<usize>(left));
            if (stream.Read(chunk.data(), wanted) != wanted) return false;
            if (! consume(std::span<const char>(chunk.data(), wanted))) return false;
            left -= static_cast<isize>(wanted);
        }
        return true;
    };

    // The name is the content's digest, so the bytes are read once to name
    // them and a second time only when no file of that name exists yet: a
    // video loaded before costs a read, not a write.
    utils::Sha1 digest;
    if (! each_chunk([&](std::span<const char> bytes) {
            digest.update(bytes);
            return true;
        })) {
        SetError(error, "failed to read video payload");
        return {};
    }

    bool read_failed = false;
    auto published = Publish(
        debug_label,
        extension,
        digest.final(),
        static_cast<uintmax_t>(size),
        [&](std::ofstream& output) {
            const bool copied = each_chunk([&](std::span<const char> bytes) {
                output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
                return output.good();
            });
            read_failed = ! copied && output.good();
            return copied;
        },
        error);
    if (published.empty() && read_failed) SetError(error, "failed to read video payload");
    return published;
}

} // namespace wallpaper::video
