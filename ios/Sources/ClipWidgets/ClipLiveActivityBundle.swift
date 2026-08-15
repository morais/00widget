import WidgetKit
import SwiftUI

/// The App Clip's widget extension, holding exactly one Live Activity and
/// nothing else.
///
/// Apple is explicit that a clip's widget extension "can only include Live
/// Activities" and that Home Screen, Lock Screen and Today View widgets are
/// reserved for the full app. That is why this bundle exists at all rather than
/// reusing `ZeroZeroWidgetWidgetBundle`, which registers the card widgets.
@main
struct ZeroZeroWidgetClipWidgetBundle: WidgetBundle {
    var body: some Widget {
        ZeroZeroWidgetLiveActivityWidget()
    }
}
