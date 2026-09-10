# Live Activity previews

Run:

```sh
ios/scripts/render-live-activity-previews.sh
```

The command renders every canonical Lock Screen fixture at 364×170 and
321×148 points and writes the PNGs plus a manifest here. The generated files
are ignored; this note is not.

Dynamic Island previews use ActivityKit's native Xcode preview host because
the system applies the island's final width after SwiftUI layout. Open
`ios/Sources/Widgets/LiveActivityWidget.swift`, resume the canvas, and select
one of the `Compact · …` previews. The four fixtures cover countdown, progress
ring, item count, and short value token — every compact-trailing branch.

For final device evidence, use `marketing/screenshots/capture-ios.sh --only
island`. It is slower because it captures the real system surface; the native
canvas previews are the normal edit loop.

To include that real system evidence in the same batch, run:

```sh
ios/scripts/render-live-activity-previews.sh --include-island
```

With Xcode 27 and an iOS 27 simulator installed, this adds `system-island/`
with all four compact-trailing types — countdown, progress ring, item count,
and value token — in portrait and landscape, plus the expanded capture and
zoomed crops. In the vertical, width-limited Island the count and value token
remain visible, while countdowns use two complete lines instead of an
ellipsis. The default command deliberately stays the cheap Lock Screen-only
loop. Override the defaults with `--island-device` or
`ZW_ISLAND_DEVELOPER_DIR` when needed.
