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
