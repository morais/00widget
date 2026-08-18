import WidgetKit
import SwiftUI

@main
struct ZeroZeroWidgetWidgetBundle: WidgetBundle {
    var body: some Widget {
        CardWidget()
        CardGridWidget()
        ZeroZeroWidgetLiveActivityWidget()
#if ZW_SCREENSHOTS
        ScreenshotSolarWidget()
        ScreenshotWasherWidget()
        ScreenshotBoilerWidget()
        ScreenshotEnergyWidget()
        ScreenshotDeploysWidget()
        ScreenshotSpendingWidget()
#endif
    }
}
