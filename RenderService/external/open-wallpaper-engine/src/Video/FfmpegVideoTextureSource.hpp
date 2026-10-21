#pragma once

#include "Video/VideoTextureSource.hpp"

#include <filesystem>
#include <memory>
#include <string>
#include <string_view>

namespace wallpaper
{
struct Image;

namespace video
{

class FfmpegVideoTextureSource final : public VideoTextureSource {
public:
    explicit FfmpegVideoTextureSource(const Image& image);
    /// Opens a decoder directly on a media file, without an `Image`.
    ///
    /// Shared sessions open resolved media this way, including a later split
    /// after the `Image` that supplied the packed bytes is gone.
    explicit FfmpegVideoTextureSource(std::string media_path);
    ~FfmpegVideoTextureSource() override;

    bool prime(std::string* error) override;
    bool syncPlayback(const VideoPlaybackState& state, std::string* error) override;
    bool refreshFrame(std::string* error) override;
    [[nodiscard]] VideoTextureFrame currentFrame() const override;
    [[nodiscard]] bool retainCurrentFrame(VideoTextureFrame* out) const override;
    [[nodiscard]] double durationSeconds() const override;
    [[nodiscard]] double playbackSeconds() const override;
    [[nodiscard]] uint64_t loopCount() const override;
    [[nodiscard]] double frameDurationSeconds() const override;
    [[nodiscard]] VideoSourceStats sourceStats() const override;

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

/// Resolves file-backed or packed media before shared-session lookup. Packed
/// bytes go into the existing content-named cache without constructing a decoder
/// or retaining another payload copy. Returns an empty path and sets `error`
/// if the image has no video payload or extraction fails.
std::string ResolveVideoTextureMediaPath(const Image& image, std::string* error);

/// Builds the texture image for a pure-video wallpaper project.
///
/// `file_name` is the project manifest's media entry, resolved against
/// `project_directory`. The media file is not read: the returned image only
/// records where it lives, and the decoder opens it in place. Symlinks are
/// resolved before the containment test, so an entry that leaves the project
/// directory is rejected instead of followed. Returns nullptr and fills
/// `error` when the entry is empty, missing, empty on disk, outside the
/// project, or not decodable.
std::shared_ptr<Image> CreateVideoProjectImage(const std::filesystem::path& project_directory,
                                               std::string_view             file_name,
                                               std::string*                 error);

} // namespace video
} // namespace wallpaper
