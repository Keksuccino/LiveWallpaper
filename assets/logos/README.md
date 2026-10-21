# App icon

The app icon is a **corona arc** over a night horizon: one sweep of light across a star field, with a
dark ridge at the bottom.

![app icon](app-icon.svg)

## Files

- `app-icon.svg` — the source (1024 x 1024, macOS squircle). **This is the master copy.**
- `../tools/svg2png.swift` — the renderer used to export it (WebKit; no design tools needed).
- `../../Resources/AppIcon.icns` — the shipped icon, built from `app-icon.svg` and copied into the
  Settings app bundle by `build.sh` (`CFBundleIconFile` = `AppIcon` in `Resources/Info.plist`).
  The two helper apps (agent, scene host) deliberately keep the generic macOS placeholder.

Only the vector is committed; the `.icns` is a build artefact that `build.sh` copies in.

## Regenerating the icon

```sh
# render every size into an iconset
mkdir /tmp/ic.iconset
for spec in "icon_16x16:16" "icon_16x16@2x:32" "icon_32x32:32" "icon_32x32@2x:64" \
            "icon_128x128:128" "icon_128x128@2x:256" "icon_256x256:256" "icon_256x256@2x:512" \
            "icon_512x512:512" "icon_512x512@2x:1024"; do
  file="${spec%%:*}"; px="${spec##*:}"
  swiftc -O tools/svg2png.swift -o /tmp/svg2png
  /tmp/svg2png assets/logos/app-icon.svg "/tmp/ic.iconset/$file.png" "$((px/2))" "$((px/2))"
done
iconutil -c icns /tmp/ic.iconset -o Resources/AppIcon.icns
```

The renderer draws at 2x the requested points, so a 1024 px PNG is requested as `512 512`.

## Tweaking

- The arc is the `M -80 880 C …` path; the wide blurred copy behind it gives the halo, the sharp copy
  in front gives the core. Shape them together.
- `V-arc` is the gradient (mint -> blue -> violet). `V-sky` is the night sky, `V-star` the star glow.
- The squircle is a superellipse (exponent 5) inscribed in the 1024 canvas; keep the artwork inside
  it and avoid detail that disappears below 64 px.
