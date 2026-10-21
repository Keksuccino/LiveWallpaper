// What a pure-video wallpaper is allowed to do with the user's media file.
//
// A plain local file is decode input, not a payload: it must be opened where it
// lies, never read into the process and never copied into the shared cache.
// Media that only exists inside a package still has to be extracted, and that
// extraction must be published whole so a second opener cannot observe a
// half-written file. Everything below drives the production construction path -
// `CreateVideoProjectImage` followed by `CreateVideoTextureSource` - over media
// the test encodes for itself.
//
// The last group is the clock a consumer gives a source: a source opened when
// the scene is already some way into the clip, and what a jump of that clock
// costs the decoder.

#include "Fs/PhysicalFs.h"
#include "Fs/VFS.h"
#include "Image.hpp"
#include "Scene/Parse/WPTexImageParser.hpp"
#include "Scene/WPPkgFs.hpp"
#include "Video/FfmpegVideoTextureSource.hpp"
#include "Video/VideoSeekPolicy.hpp"
#include "Video/VideoTextureSource.hpp"
#include "Video/VideoMetadata.hpp"
#include "Scene/SceneWallpaper.hpp"
#include "synthetic_video.hpp"
#include "video_orientation_cases.hpp"

#include <gtest/gtest.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/frame.h>
}

#include <CoreVideo/CoreVideo.h>
#include <mach/mach.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace wallpaper::video
{
namespace
{

using testing_media::kFrameHeight;
using testing_media::kFrameWidth;
using testing_media::SharedGop;
using testing_media::WriteSyntheticVideo;

std::vector<char> ReadWholeFile(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input.good()) return {};
    const auto size = static_cast<size_t>(input.tellg());
    input.seekg(0, std::ios::beg);
    std::vector<char> bytes(size);
    input.read(bytes.data(), static_cast<std::streamsize>(size));
    return bytes;
}

/// Builds the in-package shape: the media bytes ride inside the image itself,
/// exactly as `WPTexImageParser` hands them over for a packaged asset.
std::shared_ptr<Image> MakeInlinePayloadImage(const std::string& key,
                                              const std::vector<char>& payload) {
    auto image                      = std::make_shared<Image>();
    image->key                      = key;
    image->header.isVideo           = true;
    image->header.count             = 1;
    image->header.width             = kFrameWidth;
    image->header.height            = kFrameHeight;

    Image::Slot slot;
    slot.width  = kFrameWidth;
    slot.height = kFrameHeight;

    ImageData mip;
    mip.width  = kFrameWidth;
    mip.height = kFrameHeight;
    mip.size   = static_cast<isize>(payload.size());
    mip.data   = ImageDataPtr(new uint8_t[payload.size()], [](uint8_t* data) { delete[] data; });
    std::memcpy(mip.data.get(), payload.data(), payload.size());
    slot.mipmaps.push_back(std::move(mip));
    image->slots.push_back(std::move(slot));
    return image;
}

std::filesystem::path VideoCacheDirectory() {
    return std::filesystem::temp_directory_path() / "wallpaper-engine-video";
}

/// TMPDIR is private to this test process; production's cache path therefore
/// remains realistic without touching another renderer's cache.
std::set<std::filesystem::path> VideoCacheEntries() {
    std::set<std::filesystem::path> entries;
    std::error_code                 ec;
    for (const auto& entry : std::filesystem::directory_iterator(VideoCacheDirectory(), ec)) {
        entries.insert(entry.path());
    }
    return entries;
}

uint64_t PhysicalFootprintBytes() {
    task_vm_info_data_t    info {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) !=
        KERN_SUCCESS) {
        return 0;
    }
    return info.phys_footprint;
}

class VideoSourceInput : public ::testing::Test {
protected:
    void SetUp() override {
        ASSERT_FALSE(SharedGop().packets.empty())
            << "VideoToolbox H.264 encoding is unavailable, so no synthetic media can be made";
        static std::atomic<uint64_t> serial { 0 };
        project_dir = std::filesystem::temp_directory_path() /
                      ("owe-video-source-" + std::to_string(::getpid()) + "-" +
                       std::to_string(serial.fetch_add(1)));
        std::filesystem::create_directories(project_dir);
        if (const char* previous = std::getenv("TMPDIR")) previous_tmpdir = previous;
        const auto temp = project_dir / "tmp";
        std::filesystem::create_directories(temp);
        ASSERT_EQ(setenv("TMPDIR", temp.c_str(), 1), 0);
        tmpdir_overridden = true;
    }

    void TearDown() override {
        if (tmpdir_overridden) {
            if (previous_tmpdir) setenv("TMPDIR", previous_tmpdir->c_str(), 1);
            else unsetenv("TMPDIR");
        }
        std::error_code ec;
        std::filesystem::remove_all(project_dir, ec);
        std::filesystem::remove_all(outside_dir, ec);
    }

    /// A directory deliberately outside the project, for containment cases.
    const std::filesystem::path& OutsideDir() {
        if (outside_dir.empty()) {
            outside_dir = project_dir.parent_path() / (project_dir.filename().string() + "-outside");
            std::filesystem::create_directories(outside_dir);
        }
        return outside_dir;
    }

    /// Only the private cache is inspected; cleanup owns the whole test root.
    std::set<std::filesystem::path> CacheEntriesAddedSince(
        const std::set<std::filesystem::path>& before) {
        std::set<std::filesystem::path> added;
        for (const auto& path : VideoCacheEntries()) {
            if (before.count(path) == 0) added.insert(path);
        }
        return added;
    }

    std::filesystem::path           project_dir;
    std::filesystem::path           outside_dir;
    std::optional<std::string> previous_tmpdir;
    bool tmpdir_overridden { false };
};

TEST_F(VideoSourceInput, DisplayMatrixSurvivesMetadataProbeAndFrameExtraction) {
    for (const auto& orientation : testing_media::kOrientations) {
        SCOPED_TRACE(orientation.name);
        const std::string name = std::string(orientation.name) + ".mp4";
        ASSERT_TRUE(WriteSyntheticVideo(project_dir / name, 1, name, orientation.matrix()));
        std::string error;
        auto image = CreateVideoProjectImage(project_dir, name, &error);
        ASSERT_NE(image, nullptr) << error;
        auto source = CreateVideoTextureSource(*image, &error);
        ASSERT_NE(source, nullptr) << error;
        ASSERT_TRUE(source->prime(&error)) << error;
        const auto frame = source->currentFrame();
        ASSERT_TRUE(frame.valid());
        EXPECT_EQ(frame.width, kFrameWidth); EXPECT_EQ(frame.height, kFrameHeight);
        EXPECT_EQ(frame.displayWidth(), orientation.swaps_axes ? kFrameHeight : kFrameWidth);
        EXPECT_EQ(frame.displayHeight(), orientation.swaps_axes ? kFrameWidth : kFrameHeight);
        EXPECT_EQ(image->header.width, frame.displayWidth());
        EXPECT_EQ(image->header.height, frame.displayHeight());
        const auto expected = ResolveVideoDisplayTransform(orientation.matrix(), kFrameWidth, kFrameHeight);
        ASSERT_TRUE(expected.has_value());
        EXPECT_EQ(frame.display_transform.matrix, expected->matrix);
        EXPECT_EQ(frame.display_transform.offset, expected->offset);
    }
}

TEST_F(VideoSourceInput, PlainLocalFileIsDecodedWhereItLies) {
    const auto media = project_dir / "media.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "plain-local"));
    const auto original_size  = std::filesystem::file_size(media);
    const auto original_write = std::filesystem::last_write_time(media);
    const auto cache_before   = VideoCacheEntries();

    std::string error;
    auto        image = CreateVideoProjectImage(project_dir, "media.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    // No slots is the whole point: there is no second copy of the media to own.
    EXPECT_TRUE(image->slots.empty());
    EXPECT_EQ(image->videoFilePath, std::filesystem::canonical(media).string());
    EXPECT_EQ(image->header.width, kFrameWidth);
    EXPECT_EQ(image->header.height, kFrameHeight);

    auto source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_TRUE(source->currentFrame().valid());
    EXPECT_GT(source->durationSeconds(), 0.0);

    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
    EXPECT_EQ(std::filesystem::file_size(media), original_size);
    EXPECT_EQ(std::filesystem::last_write_time(media), original_write);
}

TEST_F(VideoSourceInput, LargeLocalFileIsNeverResident) {
    const auto media = project_dir / "large.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 96, "large-local"));
    const auto media_size = std::filesystem::file_size(media);
    ASSERT_GT(media_size, 48u * 1024u * 1024u);
    const auto cache_before = VideoCacheEntries();

    const uint64_t before = PhysicalFootprintBytes();
    ASSERT_GT(before, 0u);

    std::string error;
    auto        image = CreateVideoProjectImage(project_dir, "large.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    auto source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    ASSERT_TRUE(source->currentFrame().valid());

    const uint64_t after  = PhysicalFootprintBytes();
    const uint64_t growth = after > before ? after - before : 0;
    // Decoded 640x360 frames and FFmpeg's own buffers are megabytes; a copy of
    // the media would be tens of them, twice over.
    EXPECT_LT(growth, 16u * 1024u * 1024u)
        << "opening a " << media_size << " byte file grew the footprint by " << growth << " bytes";
    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
}

TEST_F(VideoSourceInput, ConcurrentOpensOfOneFileEachGetTheirOwnDecoder) {
    const auto media = project_dir / "shared.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "concurrent-local"));
    const auto cache_before = VideoCacheEntries();

    constexpr int              kOpeners = 4;
    std::vector<std::thread>   threads;
    std::vector<std::string>   errors(kOpeners);
    std::vector<uint64_t>      instance_ids(kOpeners, 0);
    std::atomic<int>           primed { 0 };
    for (int index = 0; index < kOpeners; ++index) {
        threads.emplace_back([&, index]() {
            auto image = CreateVideoProjectImage(project_dir, "shared.mp4", &errors[index]);
            if (image == nullptr) return;
            auto source = CreateVideoTextureSource(*image, &errors[index]);
            if (source == nullptr) return;
            if (!source->prime(&errors[index])) return;
            instance_ids[index] = source->sourceStats().instance_id;
            primed.fetch_add(1);
        });
    }
    for (auto& thread : threads) thread.join();

    EXPECT_EQ(primed.load(), kOpeners) << errors[0] << "|" << errors[1] << "|" << errors[2] << "|"
                                       << errors[3];
    const std::set<uint64_t> distinct(instance_ids.begin(), instance_ids.end());
    EXPECT_EQ(distinct.size(), static_cast<size_t>(kOpeners));
    EXPECT_EQ(distinct.count(0), 0u);
    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
}

TEST_F(VideoSourceInput, MissingMediaIsReportedAndNotOpened) {
    std::string error;
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "absent.mp4", &error), nullptr);
    EXPECT_NE(error.find("failed to open video project media file"), std::string::npos) << error;

    error.clear();
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "", &error), nullptr);
    EXPECT_EQ(error, "video project file entry must not be empty");

    // A file that disappears between resolution and decode fails on prime
    // rather than at construction, and still reports rather than crashing.
    const auto media = project_dir / "vanishing.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 1, "vanishing"));
    error.clear();
    auto image = CreateVideoProjectImage(project_dir, "vanishing.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    std::filesystem::remove(media);
    auto source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    error.clear();
    EXPECT_FALSE(source->prime(&error));
    EXPECT_FALSE(error.empty());
}

TEST_F(VideoSourceInput, EmptyMediaIsReported) {
    const auto media = project_dir / "empty.mp4";
    std::ofstream(media, std::ios::binary).close();
    ASSERT_TRUE(std::filesystem::exists(media));

    std::string error;
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "empty.mp4", &error), nullptr);
    EXPECT_NE(error.find("video project media file is empty"), std::string::npos) << error;
}

TEST_F(VideoSourceInput, CorruptMediaFailsWithoutTouchingTheCache) {
    const auto media = project_dir / "corrupt.mp4";
    {
        std::ofstream output(media, std::ios::binary);
        std::vector<char> noise(64 * 1024);
        for (size_t i = 0; i < noise.size(); ++i) noise[i] = static_cast<char>(i * 31 + 7);
        output.write(noise.data(), static_cast<std::streamsize>(noise.size()));
    }
    const auto cache_before = VideoCacheEntries();

    std::string error;
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "corrupt.mp4", &error), nullptr);
    EXPECT_FALSE(error.empty());

    // The same bytes offered as a packaged payload must fail on prime, not on
    // an unchecked decode.
    auto image  = MakeInlinePayloadImage("corrupt-inline", ReadWholeFile(media));
    error.clear();
    auto source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    error.clear();
    EXPECT_FALSE(source->prime(&error));
    EXPECT_FALSE(error.empty());
    source.reset();

    // A rejected payload may leave its extraction behind, but never a partial
    // one: nothing staged is allowed to survive under the ".part" name.
    for (const auto& path : CacheEntriesAddedSince(cache_before)) {
        EXPECT_NE(path.extension(), ".part") << path;
    }
}

TEST_F(VideoSourceInput, MediaOutsideTheProjectIsRejected) {
    const auto outside = OutsideDir() / "outside.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(outside, 1, "outside"));
    const auto inside = project_dir / "inside.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(inside, 1, "inside"));

    std::string error;
    const auto  traversal =
        std::filesystem::path("..") / OutsideDir().filename() / "outside.mp4";
    EXPECT_EQ(CreateVideoProjectImage(project_dir, traversal.string(), &error), nullptr);
    EXPECT_NE(error.find("escapes the project directory"), std::string::npos) << error;

    error.clear();
    EXPECT_EQ(CreateVideoProjectImage(project_dir, outside.string(), &error), nullptr);
    EXPECT_NE(error.find("escapes the project directory"), std::string::npos) << error;

    // A symlink is resolved before the containment test, so pointing out of the
    // project is rejected even though the link itself lives inside it.
    std::error_code ec;
    std::filesystem::create_symlink(outside, project_dir / "escape.mp4", ec);
    ASSERT_FALSE(ec);
    error.clear();
    EXPECT_EQ(CreateVideoProjectImage(project_dir, "escape.mp4", &error), nullptr);
    EXPECT_NE(error.find("escapes the project directory"), std::string::npos) << error;

    // A link that stays inside the project is still ordinary media.
    std::filesystem::create_symlink(inside, project_dir / "alias.mp4", ec);
    ASSERT_FALSE(ec);
    error.clear();
    auto image = CreateVideoProjectImage(project_dir, "alias.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    EXPECT_EQ(image->videoFilePath, std::filesystem::canonical(inside).string());
}

TEST_F(VideoSourceInput, InPackagePayloadIsPublishedWhole) {
    const auto media = project_dir / "packaged.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "packaged-" + std::to_string(::getpid())));
    const auto payload = ReadWholeFile(media);
    ASSERT_FALSE(payload.empty());
    const auto cache_before = VideoCacheEntries();

    auto        image = MakeInlinePayloadImage("packaged.mp4", payload);
    std::string error;
    auto        source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_TRUE(source->currentFrame().valid());

    const auto added = CacheEntriesAddedSince(cache_before);
    ASSERT_EQ(added.size(), 1u);
    const auto& published = *added.begin();
    EXPECT_EQ(published.extension(), ".mp4");
    EXPECT_EQ(std::filesystem::file_size(published), payload.size());
}

TEST_F(VideoSourceInput, ConcurrentPackagedOpensPublishExactlyOneFile) {
    const auto media = project_dir / "packaged-race.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "race-" + std::to_string(::getpid())));
    const auto payload = ReadWholeFile(media);
    ASSERT_FALSE(payload.empty());
    const auto cache_before = VideoCacheEntries();

    constexpr int            kOpeners = 4;
    std::vector<std::thread> threads;
    std::vector<std::string> errors(kOpeners);
    std::atomic<int>         primed { 0 };
    for (int index = 0; index < kOpeners; ++index) {
        threads.emplace_back([&, index]() {
            auto image  = MakeInlinePayloadImage("packaged-race.mp4", payload);
            auto source = CreateVideoTextureSource(*image, &errors[index]);
            if (source == nullptr) return;
            if (!source->prime(&errors[index])) return;
            if (!source->currentFrame().valid()) return;
            primed.fetch_add(1);
        });
    }
    for (auto& thread : threads) thread.join();

    EXPECT_EQ(primed.load(), kOpeners) << errors[0] << "|" << errors[1] << "|" << errors[2] << "|"
                                       << errors[3];
    const auto added = CacheEntriesAddedSince(cache_before);
    ASSERT_EQ(added.size(), 1u) << "racing extractions must converge on one published file";
    EXPECT_EQ(std::filesystem::file_size(*added.begin()), payload.size());
}

TEST_F(VideoSourceInput, EvictingTheCacheDoesNotDisturbAnOpenSource) {
    const auto media = project_dir / "evicted.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 2, "evicted-" + std::to_string(::getpid())));
    const auto payload = ReadWholeFile(media);
    ASSERT_FALSE(payload.empty());
    const auto cache_before = VideoCacheEntries();

    auto        image = MakeInlinePayloadImage("evicted.mp4", payload);
    std::string error;
    auto        source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;

    const auto added = CacheEntriesAddedSince(cache_before);
    ASSERT_EQ(added.size(), 1u);
    const auto published = *added.begin();
    ASSERT_TRUE(std::filesystem::remove(published));

    // The decoder holds the file open, so deleting the cache entry underneath it
    // must not interrupt playback.
    VideoPlaybackState state;
    state.scene_elapsed_seconds = 0.5;
    error.clear();
    EXPECT_TRUE(source->syncPlayback(state, &error)) << error;
    error.clear();
    EXPECT_TRUE(source->refreshFrame(&error)) << error;
    EXPECT_TRUE(source->currentFrame().valid());

    // A later opener of the same payload re-publishes it rather than inheriting
    // the hole left by the eviction.
    auto second_image  = MakeInlinePayloadImage("evicted.mp4", payload);
    error.clear();
    auto second_source = CreateVideoTextureSource(*second_image, &error);
    ASSERT_NE(second_source, nullptr) << error;
    ASSERT_TRUE(second_source->prime(&error)) << error;
    ASSERT_TRUE(std::filesystem::exists(published));
    EXPECT_EQ(std::filesystem::file_size(published), payload.size());
}

TEST_F(VideoSourceInput, DestroyingASourceMidDecodeCancelsPromptly) {
    const auto media = project_dir / "cancelled.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(media, 96, "cancelled"));
    const auto cache_before = VideoCacheEntries();

    std::string error;
    auto        image = CreateVideoProjectImage(project_dir, "cancelled.mp4", &error);
    ASSERT_NE(image, nullptr) << error;
    auto source = CreateVideoTextureSource(*image, &error);
    ASSERT_NE(source, nullptr) << error;
    ASSERT_TRUE(source->prime(&error)) << error;

    // The decode thread is reading a large file; tearing the source down has to
    // abort that read instead of waiting for it.
    const auto start = std::chrono::steady_clock::now();
    source.reset();
    const auto elapsed = std::chrono::steady_clock::now() - start;
    EXPECT_LT(elapsed, std::chrono::seconds(2));

    // A source that is dropped before it is ever primed opens nothing at all.
    auto unprimed_image  = CreateVideoProjectImage(project_dir, "cancelled.mp4", &error);
    ASSERT_NE(unprimed_image, nullptr) << error;
    auto unprimed_source = CreateVideoTextureSource(*unprimed_image, &error);
    ASSERT_NE(unprimed_source, nullptr) << error;
    unprimed_source.reset();

    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
}

/// A source on a clip of `seconds` seconds, with nothing yet asked of it.
class VideoSourceClock : public VideoSourceInput {
protected:
    std::shared_ptr<VideoTextureSource> Open(const std::string& name, int seconds) {
        EXPECT_TRUE(WriteSyntheticVideo(project_dir / name, seconds, name));
        std::string error;
        auto        image = CreateVideoProjectImage(project_dir, name, &error);
        EXPECT_NE(image, nullptr) << error;
        if (image == nullptr) return nullptr;
        auto source = CreateVideoTextureSource(*image, &error);
        EXPECT_NE(source, nullptr) << error;
        return source;
    }

    /// Plays on from `start_seconds` at the pace of a wall clock, as a scene
    /// does when it is drawn in real time, and returns whether the frame on
    /// offer is within `tolerance` of that clock: as soon as it is, or, with
    /// `until_arrival` off, once `budget` has run out. Each step is one call of
    /// a draw -- the clock is handed over, then a frame is asked for -- and a
    /// step is far shorter than a seek.
    static bool FollowsTheClock(VideoTextureSource& source, double start_seconds,
                                double tolerance, std::chrono::milliseconds budget,
                                bool until_arrival = true) {
        std::string error;
        const auto  begin = std::chrono::steady_clock::now();
        bool        near  = false;
        while (std::chrono::steady_clock::now() - begin < budget) {
            const double clock =
                start_seconds +
                std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
            if (! source.syncPlayback(VideoPlaybackState { false, 1.0f, clock }, &error)) return false;
            if (! source.refreshFrame(&error)) return false;
            near = std::abs(source.currentFrame().pts_seconds - clock) <= tolerance;
            if (near && until_arrival) return true;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return near;
    }
};

// A scene whose graph is rebuilt keeps its videos open, but one that is opened
// while its clock is already some way into the clip still happens: a scene that
// falls back to the other renderer, a surface split off a shared decoder. The open
// costs what opening at the head costs, however far in the clock is: it waits for
// no seek, and the seek to the clock is asked for once, on the first call that
// gives the source that clock after it has opened, and left to land. A source that
// waited for the seek would hold the render thread for as long as the seek takes,
// which on a clip of any size is more than a frame, and fail the open outright when
// it takes more than a few seconds.
TEST_F(VideoSourceClock, AReopenedSourceIsSoughtToTheClockOnceAndLeftToLand) {
    auto source = Open("reopened.mp4", 10);
    ASSERT_NE(source, nullptr);
    std::string error;
    // Even a clock handed over before the open is not one the open seeks to.
    ASSERT_TRUE(source->syncPlayback(VideoPlaybackState { false, 1.0f, 6.5 }, &error)) << error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_NEAR(source->currentFrame().pts_seconds, 0.0, 0.1) << "the open waited for a seek";
    EXPECT_EQ(source->sourceStats().seek_requests, 0u);

    ASSERT_TRUE(source->syncPlayback(VideoPlaybackState { false, 1.0f, 6.5 }, &error)) << error;
    ASSERT_TRUE(source->refreshFrame(&error)) << error;
    // The call that gives the clock returns with the head still on offer: it asked
    // for the seek and did not wait for it.
    EXPECT_NEAR(source->currentFrame().pts_seconds, 0.0, 0.1)
        << "the first call with the clock waited for the seek";
    EXPECT_EQ(source->sourceStats().seek_requests, 1u)
        << "the seek was not asked for as soon as the source had the clock";
    // A frame lasts a thirtieth of a second, and the first one at or after the
    // clock may be the one that started just before it.
    EXPECT_TRUE(FollowsTheClock(*source, 6.5, 0.15, std::chrono::seconds(2)))
        << "the frame on offer stayed at " << source->currentFrame().pts_seconds
        << " s with the clock at 6.5 s and after";
    EXPECT_EQ(source->sourceStats().seek_requests, 1u);

    // Past the end of a clip the clock wraps, as it does while playing: a 3 second
    // clip at 7.2 seconds is in its third pass, 1.2 seconds in.
    auto looping = Open("reopened-looping.mp4", 3);
    ASSERT_NE(looping, nullptr);
    ASSERT_TRUE(looping->prime(&error)) << error;
    EXPECT_TRUE(FollowsTheClock(*looping, 7.2, 0.15, std::chrono::seconds(2)))
        << "the frame on offer stayed at " << looping->currentFrame().pts_seconds
        << " s with the clock at 7.2 s and after";
    EXPECT_EQ(looping->sourceStats().seek_requests, 1u);
}

// The picture of a jump of the clock has to arrive even when frames are asked for
// faster than a seek takes. A seek asked for again on every call restarts the
// decode from the keyframe each time, so the display never leaves the frame it had.
TEST_F(VideoSourceClock, AJumpOfTheClockLandsWhileFramesAreAskedForFasterThanASeekTakes) {
    auto source = Open("jumped.mp4", 10);
    ASSERT_NE(source, nullptr);
    std::string error;
    ASSERT_TRUE(source->prime(&error)) << error;
    ASSERT_NEAR(source->currentFrame().pts_seconds, 0.0, 0.1);

    // A seek of a few frames' decode lands in well under a second; the two are for a
    // busy machine. The number of seeks is not: one that takes longer is waited for.
    EXPECT_TRUE(FollowsTheClock(*source, 7.5, 0.15, std::chrono::seconds(2)))
        << "the frame on offer stayed at " << source->currentFrame().pts_seconds
        << " s with the clock at 7.5 s and after";
    EXPECT_EQ(source->sourceStats().seek_requests, 1u)
        << "the decoder was sent back to the keyframe again on call after call";
}

// What a jump costs is a seek, and a source that is kept up with needs none.
TEST_F(VideoSourceClock, ASourceThatIsKeptUpWithNeverSeeks) {
    auto source = Open("kept-up.mp4", 10);
    ASSERT_NE(source, nullptr);
    std::string error;
    ASSERT_TRUE(source->prime(&error)) << error;
    EXPECT_TRUE(FollowsTheClock(*source, 0.0, 0.15, std::chrono::seconds(2), false));
    EXPECT_EQ(source->sourceStats().seek_requests, 0u) << "playing on from the start asked for a seek";
}

// A seek that is on its way is waited for only while the clock still wants what it
// is fetching. A clock that goes back before it, or runs on past it by more than a
// second, is a new jump and gets its own seek.
TEST_F(VideoSourceClock, AClockThatLeavesASeekBehindAsksForAnother) {
    auto source = Open("left-behind.mp4", 10);
    ASSERT_NE(source, nullptr);
    std::string error;
    ASSERT_TRUE(source->prime(&error)) << error;

    ASSERT_TRUE(source->syncPlayback(VideoPlaybackState { false, 1.0f, 8.0 }, &error)) << error;
    ASSERT_TRUE(source->refreshFrame(&error)) << error;
    const auto after_first = source->sourceStats().seek_requests;
    EXPECT_EQ(after_first, 1u);

    // Back to 2 seconds before the first seek can have delivered.
    ASSERT_TRUE(source->syncPlayback(VideoPlaybackState { false, 1.0f, 2.0 }, &error)) << error;
    ASSERT_TRUE(source->refreshFrame(&error)) << error;
    EXPECT_GT(source->sourceStats().seek_requests, after_first);
    EXPECT_TRUE(FollowsTheClock(*source, 2.0, 0.15, std::chrono::seconds(5)))
        << "the frame on offer stayed at " << source->currentFrame().pts_seconds << " s";
}

// The arithmetic behind that wait. A clip small enough to test is seeked in a few
// milliseconds, so what a seek of seconds is waited for, and not asked for again,
// is shown here.
TEST(VideoSeekPolicy, ASeekIsWaitedForAsLongAsItTakesWhileTheClockOnlyRunsOn) {
    constexpr double kBack = 0.067, kForward = 1.0;
    // The clock still stands where the seek was sent.
    EXPECT_TRUE(SeekOnItsWayCoversClock(8.2, 8.2, 0.0, 1.0, kBack, kForward));
    // Four seconds on, the clock has run four seconds, which waiting explains.
    EXPECT_TRUE(SeekOnItsWayCoversClock(8.2, 12.2, 4.0, 1.0, kBack, kForward));
    EXPECT_TRUE(SeekOnItsWayCoversClock(8.2, 16.2, 4.0, 2.0, kBack, kForward))
        << "a clock at twice the pace runs twice as far in the same wait";
    EXPECT_FALSE(SeekOnItsWayCoversClock(8.2, 16.2, 4.0, 1.0, kBack, kForward));
    // A clock that has run on further than that, by more than the slack, has jumped.
    EXPECT_FALSE(SeekOnItsWayCoversClock(8.2, 20.0, 4.0, 1.0, kBack, kForward));
    EXPECT_FALSE(SeekOnItsWayCoversClock(8.2, 13.3, 4.0, 1.0, kBack, kForward));
    // So has one that has gone back before the target by more than the slack.
    EXPECT_TRUE(SeekOnItsWayCoversClock(8.2, 8.15, 0.5, 1.0, kBack, kForward));
    EXPECT_FALSE(SeekOnItsWayCoversClock(8.2, 2.0, 0.5, 1.0, kBack, kForward));
    // A clock slower than real time, or a wait that reads as negative, is not given credit.
    EXPECT_EQ(ClockRunOnSeconds(4.0, 0.5), 4.0);
    EXPECT_EQ(ClockRunOnSeconds(4.0, 0.0), 4.0);
    EXPECT_EQ(ClockRunOnSeconds(-1.0, 1.0), 0.0);
}

TEST(VideoSeekPolicy, ALandingThatCameLateIsCaughtUpWithByDecodingOn) {
    // A source that has not seeked leaves a frame a second behind the clock alone.
    EXPECT_EQ(ForwardResyncSeconds(1.0 / 30.0, 8.0, 0.0), 1.0);
    // The span of a long queue at a slow frame rate is longer than that.
    EXPECT_DOUBLE_EQ(ForwardResyncSeconds(0.25, 8.0, 0.0), 4.0);
    // A seek that took 3.6 seconds landed 3.6 seconds behind the clock; asking for
    // another because of that would land as late again.
    EXPECT_DOUBLE_EQ(ForwardResyncSeconds(1.0 / 30.0, 8.0, ClockRunOnSeconds(3.6, 1.0)), 4.6);
}

// A plain video wallpaper has no material, particle, uniform or script that
// could read system audio, so it must never ask for the system-audio tap.
TEST_F(VideoSourceInput, PlainVideoProjectNeverReportsAnAudioRequirement) {
    ASSERT_TRUE(WriteSyntheticVideo(project_dir / "media.mp4", 2, "audio-requirement"));
    const auto project_json = project_dir / "project.json";
    std::ofstream(project_json) << R"({"type":"video","file":"media.mp4","title":"clip"})";

    std::string error;
    auto        scene = SceneWallpaperInputTestAccess::CreateVideoProjectScene(
        project_json.string(), &error);
    ASSERT_NE(scene, nullptr) << error;

    std::mutex              mutex;
    std::condition_variable changed;
    std::vector<bool>       audio;
    int                     commits = 0;
    SceneWallpaper          wallpaper;
    ASSERT_TRUE(wallpaper.init());
    wallpaper.setPropertyObject(PROPERTY_AUDIO_REQUIREMENT_CALLBACK,
        std::make_shared<AudioRequirementCallback>([&](bool requires_audio) {
            std::lock_guard lock(mutex);
            audio.push_back(requires_audio);
            changed.notify_all();
        }));
    // The pointer report follows the audio report of the same commit on the
    // same looper, so seeing it means the audio report has been handled.
    wallpaper.setPropertyObject(PROPERTY_POINTER_INPUT_CALLBACK,
        std::make_shared<PointerInputCallback>([&](bool) {
            std::lock_guard lock(mutex);
            ++commits;
            changed.notify_all();
        }));
    SceneWallpaperInputTestAccess::PostScene(wallpaper, scene);
    {
        std::unique_lock lock(mutex);
        ASSERT_TRUE(changed.wait_for(lock, std::chrono::seconds(5), [&] { return commits >= 2; }));
    }
    wallpaper.shutdown();
    std::lock_guard lock(mutex);
    EXPECT_EQ(audio, (std::vector<bool> { false }));
}

// A video a scene names as a texture comes in three shapes: a loose file next
// to the scene, an entry of the scene's package, and a payload packed into a
// `.tex`. Each one must reach the decoder with the metadata and the first frame
// that decoding the media file itself gives, and only the packed-in one may be
// held in memory: a loose file is opened where it lies, and a package entry is
// streamed into the cache rather than read whole.

/// Forwards a stream and records the largest single read asked of it.
class ObservedStream final : public fs::IBinaryStream {
public:
    ObservedStream(std::shared_ptr<fs::IBinaryStream> inner, std::shared_ptr<usize> largest_read)
        : m_inner(std::move(inner)), m_largestRead(std::move(largest_read)) {}

    usize Read(void* buffer, usize size) override {
        *m_largestRead = std::max(*m_largestRead, size);
        return m_inner->Read(buffer, size);
    }
    char* Gets(char* buffer, usize size) override { return m_inner->Gets(buffer, size); }
    idx   Tell() const override { return m_inner->Tell(); }
    bool  SeekSet(idx offset) override { return m_inner->SeekSet(offset); }
    bool  SeekCur(idx offset) override { return m_inner->SeekCur(offset); }
    bool  SeekEnd(idx offset) override { return m_inner->SeekEnd(offset); }
    isize Size() const override { return m_inner->Size(); }

protected:
    usize Write_impl(const void*, usize) override { return 0; }

private:
    std::shared_ptr<fs::IBinaryStream> m_inner;
    std::shared_ptr<usize>             m_largestRead;
};

/// Forwards to a real file system and records what was read through it.
class ObservedFs final : public fs::Fs {
public:
    explicit ObservedFs(std::unique_ptr<fs::Fs> inner): m_inner(std::move(inner)) {}

    bool Contains(std::string_view path) const override { return m_inner->Contains(path); }
    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        opened.emplace_back(path);
        auto stream = m_inner->Open(path);
        if (stream == nullptr) return nullptr;
        return std::make_shared<ObservedStream>(std::move(stream), largest_read);
    }
    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }
    std::string HostPath(std::string_view path) const override { return m_inner->HostPath(path); }

    std::vector<std::string> opened;
    std::shared_ptr<usize>   largest_read { std::make_shared<usize>(0) };

private:
    std::unique_ptr<fs::Fs> m_inner;
};

/// What a consumer gets from a video: its first picture and its timing.
struct FirstPicture {
    uint32_t width { 0 };
    uint32_t height { 0 };
    double   pts_seconds { 0.0 };
    uint64_t content { 0 };
    double   duration_seconds { 0.0 };
    double   frame_duration_seconds { 0.0 };

    bool operator==(const FirstPicture&) const = default;
};

/// FNV-1a over the first plane, so two decodes can be told to show one picture.
uint64_t PictureContent(const VideoTextureFrame& frame) {
    auto* buffer = static_cast<CVPixelBufferRef>(frame.pixel_buffer);
    if (buffer == nullptr) return 0;
    if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return 0;
    const bool planar = CVPixelBufferIsPlanar(buffer);
    const auto* base = static_cast<const uint8_t*>(
        planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer));
    const size_t stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                                 : CVPixelBufferGetBytesPerRow(buffer);
    const size_t rows = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer);
    const size_t row_bytes = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0)
                                    : CVPixelBufferGetWidth(buffer) * 4;
    uint64_t content = 1469598103934665603ull;
    for (size_t row = 0; base != nullptr && row < rows; ++row) {
        for (size_t column = 0; column < row_bytes; ++column) {
            content = (content ^ base[row * stride + column]) * 1099511628211ull;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return content;
}

std::optional<FirstPicture> Decode(const Image& image, std::string* error) {
    auto source = CreateVideoTextureSource(image, error);
    if (source == nullptr || ! source->prime(error)) return std::nullopt;
    const auto frame = source->currentFrame();
    if (! frame.valid() || frame.pixel_buffer == nullptr) return std::nullopt;
    return FirstPicture {
        frame.displayWidth(),         frame.displayHeight(),     frame.pts_seconds,
        PictureContent(frame),        source->durationSeconds(), source->frameDurationSeconds(),
    };
}

class SceneVideoInput : public VideoSourceInput {
protected:
    void SetUp() override {
        VideoSourceInput::SetUp();
        scene_dir = project_dir / "scene";
        std::filesystem::create_directories(scene_dir / "materials");
    }

    /// Encodes a clip outside the scene and records what decoding that file
    /// itself gives: the result every scene shape has to reproduce.
    std::vector<char> Clip(const std::string& label, int seconds) {
        const auto media = project_dir / (label + ".mp4");
        EXPECT_TRUE(WriteSyntheticVideo(media, seconds, label));
        std::string error;
        EXPECT_TRUE(ProbeVideoFileMetadata(media.string(), &expected_metadata, &error)) << error;
        auto image = CreateVideoProjectImage(project_dir, media.filename().string(), &error);
        EXPECT_NE(image, nullptr) << error;
        if (image != nullptr) {
            auto picture = Decode(*image, &error);
            EXPECT_TRUE(picture.has_value()) << error;
            if (picture.has_value()) expected_picture = *picture;
        }
        return ReadWholeFile(media);
    }

    void ExpectClipHeader(const ImageHeader& header) const {
        EXPECT_TRUE(header.isVideo);
        EXPECT_EQ(header.durationSeconds, expected_metadata.duration_seconds);
        EXPECT_GT(header.durationSeconds, 0.0);
    }

    void ExpectLooseClipHeader(const ImageHeader& header) const {
        ExpectClipHeader(header);
        EXPECT_EQ(header.width, static_cast<i32>(expected_metadata.width));
        EXPECT_EQ(header.height, static_cast<i32>(expected_metadata.height));
    }

    void ExpectClipPicture(const Image& image) const {
        std::string error;
        const auto  picture = Decode(image, &error);
        ASSERT_TRUE(picture.has_value()) << error;
        EXPECT_EQ(*picture, expected_picture);
    }

    ObservedFs& Mount(fs::VFS& vfs, std::unique_ptr<fs::Fs> inner) {
        auto  observed = std::make_unique<ObservedFs>(std::move(inner));
        auto& handle   = *observed;
        EXPECT_TRUE(vfs.Mount("/assets", std::move(observed)));
        return handle;
    }

    std::filesystem::path WritePackage(const std::string& entry, const std::vector<char>& payload) {
        const auto path = project_dir / "scene.pkg";
        std::ofstream out(path, std::ios::binary | std::ios::trunc);
        auto write_i32 = [&](int32_t value) { out.write(reinterpret_cast<const char*>(&value), sizeof(value)); };
        const std::string version = "PKGV0001";
        write_i32(static_cast<int32_t>(version.size()));
        out.write(version.data(), static_cast<std::streamsize>(version.size()));
        write_i32(1);
        write_i32(static_cast<int32_t>(entry.size()));
        out.write(entry.data(), static_cast<std::streamsize>(entry.size()));
        write_i32(0);
        write_i32(static_cast<int32_t>(payload.size()));
        out.write(payload.data(), static_cast<std::streamsize>(payload.size()));
        return path;
    }

    /// A `.tex` carrying `payload` as its one mip: flagged as a video (texb 2),
    /// or recognised as one from its bytes (texb 3 of unknown type).
    void WriteVideoTex(const std::string& name, const std::vector<char>& payload, bool flagged) {
        std::vector<char> tex;
        auto raw = [&](const void* data, size_t size) {
            tex.insert(tex.end(), static_cast<const char*>(data), static_cast<const char*>(data) + size);
        };
        auto i32_ = [&](int32_t value) { raw(&value, sizeof(value)); };
        auto stamp = [&](char kind, int version) {
            char text[9] {};
            std::snprintf(text, sizeof(text), "TEX%c%04d", kind, version);
            raw(text, sizeof(text));
        };
        stamp('V', 5);
        stamp('I', 1);
        i32_(0);
        i32_(flagged ? 1 << 5 : 0);
        for (const int32_t size : { kFrameWidth, kFrameHeight, kFrameWidth, kFrameHeight }) i32_(size);
        i32_(0);
        stamp('B', flagged ? 2 : 3);
        i32_(1);
        if (! flagged) i32_(static_cast<int32_t>(ImageType::UNKNOWN));
        i32_(1);
        i32_(kFrameWidth);
        i32_(kFrameHeight);
        i32_(0);
        i32_(0);
        i32_(static_cast<int32_t>(payload.size()));
        raw(payload.data(), payload.size());
        std::ofstream(scene_dir / "materials" / (name + ".tex"), std::ios::binary)
            .write(tex.data(), static_cast<std::streamsize>(tex.size()));
    }

    std::filesystem::path scene_dir;
    VideoMetadata         expected_metadata;
    FirstPicture          expected_picture;
};

TEST_F(SceneVideoInput, ALooseVideoIsOpenedWhereItLies) {
    const auto payload = Clip("loose", 2);
    const auto media   = scene_dir / "materials" / "clip.mp4";
    std::ofstream(media, std::ios::binary).write(payload.data(), static_cast<std::streamsize>(payload.size()));
    const auto cache_before = VideoCacheEntries();

    fs::VFS          vfs;
    auto&            observed = Mount(vfs, fs::CreatePhysicalFs(scene_dir.string()));
    WPTexImageParser parser(&vfs);
    ExpectLooseClipHeader(parser.ParseHeader("clip"));
    auto image = parser.Parse("clip");
    ASSERT_NE(image, nullptr);
    ExpectLooseClipHeader(image->header);
    EXPECT_EQ(image->videoFilePath, media.string());
    EXPECT_TRUE(image->slots.empty());
    ExpectClipPicture(*image);

    // Never read: the parser and the decoder both open the file by its path.
    EXPECT_TRUE(observed.opened.empty()) << observed.opened.front();
    EXPECT_TRUE(CacheEntriesAddedSince(cache_before).empty());
}

TEST_F(SceneVideoInput, APackagedVideoIsStreamedIntoTheCache) {
    const auto payload = Clip("packaged-scene-" + std::to_string(::getpid()), 8);
    ASSERT_GT(payload.size(), 2u * 1024u * 1024u);
    const auto cache_before = VideoCacheEntries();

    fs::VFS vfs;
    auto&   observed = Mount(vfs, fs::WPPkgFs::CreatePkgFs(WritePackage("materials/clip.mp4", payload).string()));
    WPTexImageParser parser(&vfs);
    ExpectLooseClipHeader(parser.ParseHeader("clip"));
    auto image = parser.Parse("clip");
    ASSERT_NE(image, nullptr);
    ExpectLooseClipHeader(image->header);
    EXPECT_TRUE(image->slots.empty());
    ExpectClipPicture(*image);

    const std::filesystem::path published = image->videoFilePath;
    EXPECT_EQ(published.parent_path(), VideoCacheDirectory());
    EXPECT_EQ(published.extension(), ".mp4");
    EXPECT_EQ(ReadWholeFile(published), payload);
    EXPECT_EQ(CacheEntriesAddedSince(cache_before), (std::set<std::filesystem::path> { published }));
    // Read in pieces, never as one allocation the size of the video.
    EXPECT_LT(*observed.largest_read, payload.size() / 2);

    // The cache file is named by its content: a second load finds it.
    auto again = parser.Parse("clip");
    ASSERT_NE(again, nullptr);
    EXPECT_EQ(again->videoFilePath, image->videoFilePath);
}

TEST_F(SceneVideoInput, APackedInVideoKeepsItsMetadataAndFirstFrame) {
    const auto payload = Clip("packed-in", 2);
    for (const bool flagged : { true, false }) {
        SCOPED_TRACE(flagged ? "flagged" : "recognised");
        WriteVideoTex("clip", payload, flagged);

        fs::VFS          vfs;
        Mount(vfs, fs::CreatePhysicalFs(scene_dir.string()));
        WPTexImageParser parser(&vfs);
        ExpectClipHeader(parser.ParseHeader("clip"));
        auto image = parser.Parse("clip");
        ASSERT_NE(image, nullptr);
        ExpectClipHeader(image->header);
        EXPECT_TRUE(image->videoFilePath.empty());
        ASSERT_EQ(image->slots.size(), 1u);
        ASSERT_EQ(image->slots.front().mipmaps.size(), 1u);
        const auto& mip = image->slots.front().mipmaps.front();
        ASSERT_EQ(mip.size, static_cast<isize>(payload.size()));
        EXPECT_EQ(std::memcmp(mip.data.get(), payload.data(), payload.size()), 0);
        ExpectClipPicture(*image);
    }
}

TEST_F(SceneVideoInput, ABrokenVideoFailsInEveryShape) {
    const auto clip = Clip("broken", 2);
    std::vector<char> noise(64 * 1024);
    for (size_t i = 0; i < noise.size(); ++i) noise[i] = static_cast<char>(i * 31 + 7);
    const std::vector<std::pair<const char*, std::vector<char>>> payloads {
        { "truncated", std::vector<char>(clip.begin(), clip.begin() + static_cast<long>(clip.size() / 2)) },
        { "noise", noise },
        { "empty", {} },
    };
    for (const auto& [label, payload] : payloads) {
        SCOPED_TRACE(label);
        std::filesystem::remove_all(scene_dir / "materials");
        std::filesystem::create_directories(scene_dir / "materials");
        std::ofstream(scene_dir / "materials" / "bad.mp4", std::ios::binary)
            .write(payload.data(), static_cast<std::streamsize>(payload.size()));
        {
            SCOPED_TRACE("loose");
            fs::VFS          vfs;
            Mount(vfs, fs::CreatePhysicalFs(scene_dir.string()));
            WPTexImageParser parser(&vfs);
            EXPECT_FALSE(parser.ParseHeader("bad").isVideo);
            EXPECT_EQ(parser.Parse("bad"), nullptr);
        }
        {
            SCOPED_TRACE("packaged");
            fs::VFS          vfs;
            Mount(vfs, fs::WPPkgFs::CreatePkgFs(WritePackage("materials/bad.mp4", payload).string()));
            WPTexImageParser parser(&vfs);
            EXPECT_FALSE(parser.ParseHeader("bad").isVideo);
            EXPECT_EQ(parser.Parse("bad"), nullptr);
        }
        if (payload.empty()) continue;
        {
            SCOPED_TRACE("packed in");
            WriteVideoTex("bad", payload, true);
            fs::VFS          vfs;
            Mount(vfs, fs::CreatePhysicalFs(scene_dir.string()));
            WPTexImageParser parser(&vfs);
            EXPECT_EQ(parser.ParseHeader("bad").durationSeconds, 0.0);
            auto image = parser.Parse("bad");
            ASSERT_NE(image, nullptr);
            EXPECT_TRUE(image->header.isVideo);
            EXPECT_EQ(image->header.durationSeconds, 0.0);
            std::string error;
            EXPECT_FALSE(Decode(*image, &error).has_value());
            EXPECT_FALSE(error.empty());
        }
    }
}

} // namespace
} // namespace wallpaper::video
