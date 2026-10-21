#pragma once

#include <filesystem>
#include <span>
#include <string>
#include <string_view>

namespace wallpaper::fs
{
class IBinaryStream;
}

namespace wallpaper::video
{

/// Makes encoded video that is not a file of its own -- a payload packed into a
/// texture, an entry of a package -- openable by path, which is how FFmpeg
/// opens media.
///
/// The file is `$TMPDIR/wallpaper-engine-video/<SHA-1 of the bytes><extension>`
/// (".mp4" when `extension` is empty) and is reused when it is already there.
/// The bytes are staged under a name unique to the attempt and only then
/// linked onto that name, so a concurrent opener sees a whole file or none.
/// Returns the path, or empty with `error` set.
std::filesystem::path PublishVideoPayload(std::string_view      debug_label,
                                          std::string_view      extension,
                                          std::span<const char> payload,
                                          std::string*          error);

/// The same for the whole of `stream`, read in bounded pieces: the video is
/// never in memory at once.
std::filesystem::path PublishVideoPayload(std::string_view   debug_label,
                                          std::string_view   extension,
                                          fs::IBinaryStream& stream,
                                          std::string*       error);

} // namespace wallpaper::video
