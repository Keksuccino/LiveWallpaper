# Tests to write later

Skipped while getting the new architecture (UI + LiveWallpaperService + SceneRenderer) live.
Each entry: what to test, where, and why it was skipped.

- UI/ServiceClient: with the service not registered, the app shows the Login Items banner and no state.json write happens from the UI.
- UI/SettingsModel: rapid library edits arrive at the service as ordered `.commit`s; a pushed status with a different `muted` updates the toggle without sending `.setMuted` back.
- Service: `.commit(state)` keeps the service's `muted` and bumps state.json revision (Orchestrator.commit + StateStore). Skipped: needs a temp AppPaths.
- Service: a scene that fails to load reports the error in ServiceStatus.error, skips to the next item, and stops cleanly when only broken scenes exist.
- Service: a scene on the lock screen renders `lock-<W>x<H>.mov` once, reuses it while the stamp matches, and cancels the render when another item is chosen.
- Service: SystemAudioTap delivers moving band levels while music plays and stops when audio response is turned off.
- Service: XPC round trip — a client connection gets a reply ServiceStatus for every ServiceCommand and a statusChanged push on rotation. Skipped: needs launchd-registered mach service.
- Service: undecodable command Data returns an error string, not a crash.
- build.sh: BundleProgram in the launchd plist resolves to the bundled service executable (checked in build.sh; a CI run covers it).
- ServiceSocket: a frame split across several partial reads (header and body in separate writes) reassembles into one envelope.
- ServiceSocket: a frame header announcing more than 16 MB (or 0 bytes) closes the connection without allocating it.
- ServiceSocketServer.start: a stale service.sock with no listener is replaced; a second service exits when a live one answers.
- ServiceClient: after the service is killed and relaunched, the UI reconnects within ~3 s and shows "Service running"; after Quit Service it only watches, never relaunches.
- SettingsModel scene options: changing a per-scene or power setting sends one .commit; reopening the app shows the same values; a battery fps/scale outside range is clamped by PowerOptions.
- SceneProperty.load: project.json with bool/slider/color/text/combo/unknown properties yields the supported ones sorted by order; missing or invalid JSON yields none.
- Service scene options: change zoom/fit/pan/volume/property in state.json while a scene runs and check it updates live without restart.
- Service power: unplug the Mac with batteryMode reducedQuality/pause and check the bridge lowers scale/fps or pauses (no manual cap any more).
- Service: switching scene items re-pushes that item's SceneOptions (per-item volume, fit) and global power options once.
