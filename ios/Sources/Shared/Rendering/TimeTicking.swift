import SwiftUI

/// How a view that shows a moving time is redrawn, which is not a style choice
/// but a fact about which process is drawing it.
///
/// In the app and on Apple TV, SwiftUI runs the view, so a `TimelineView` wakes
/// it and any formatter inside is free to produce whatever reads best.
///
/// Every widget and every Live Activity presentation is different: the system
/// renders it **out of process**, from an archived snapshot, and a
/// `TimelineView` there is not driven — its schedule fires about twice and then
/// stops, whatever it asked for. The only things that keep moving are the ones
/// the system animates itself, and that list is short: `Text` with a
/// `Text.DateStyle` (`.timer`, `.relative`, `.offset`), and `Text`/`ProgressView`
/// built from a `timerInterval`. The newer `.relative` *FormatStyle* is not on
/// it and does not increment, which is the trap — the two spellings look almost
/// identical at the call site and only one of them moves.
///
/// So a shared view that draws a clock takes this, and the widget target passes
/// `.systemText`. Getting it wrong is invisible in a build, in a test, and in a
/// screenshot: the first frame is correct and it simply never changes again.
public enum TimeTicking {
    /// The app and Apple TV, where a `TimelineView` drives the redraw.
    case clock
    /// Widgets and Live Activities, where only `Text`'s own date styles move.
    case systemText
}
