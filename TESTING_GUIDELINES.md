# Testing guidelines

## Unit tests

```bash
scripts/macos-sdk.sh swift test
```

`WallpaperMageTests` covers the Settings app's model (library order and filters, playlist editing, wallpaper info, the Workshop browser's sorts, filters and QueryFiles request). The model is never bootstrapped there, so nothing reaches the service or `~/Library`.

## Running the Settings app off-screen

UI changes are checked in the real app without it covering the screen or taking focus:

1. Build the bundle: `./build.sh` (release) or `CONFIG=debug ./build.sh`.
2. Quit a Settings app that is already running: a second copy hands over to the first and quits (`AppDelegate.yieldToRunningSettings`). The wallpaper service can keep running.
3. Launch it in the background with `WM_OFFSCREEN=1`:

   ```bash
   open -g -n --env WM_OFFSCREEN=1 build/WallpaperMage.app
   ```

   `OffscreenTesting` (Sources/WallpaperMage/OffscreenTesting.swift) then moves every titled window past the right edge of the rightmost display, all but a one-point column: the window server neither draws nor lets anyone capture a window that is on no display at all. It also lets AppKit place windows off-screen and stops the moved window from saving its frame, so the next normal launch opens where the user left it. Nothing else changes: the app connects to the service and reads its preferences as usual.
4. Drive and capture the window with tools that work on background windows: per-window screenshots (ScreenCaptureKit, `screencapture -l <window id>`) and accessibility actions (Claude's background `app_*` computer-use tools do both; they cannot open menus such as the sort menus, which would bring the app to the front).
5. Quit it when done: `osascript -e 'tell application id "com.noob3301.WallpaperMage" to quit'`.

Popovers (the Workshop's filters) are the exception: AppKit slides a popover onto the display next to its anchor, so it shows at the right edge of the rightmost display while it is open. Capture it with `screencapture -l <its window id>` (CGWindowListCopyWindowInfo lists it under the app's process id) and close it right away by pressing its capsule again.

Preferences the test run changes (the Workshop's sort and filters, the library's order) are the real app's: put them back afterwards.
