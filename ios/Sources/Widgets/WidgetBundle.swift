import WidgetKit
import SwiftUI

@main
struct ZeroZeroWidgetWidgetBundle: WidgetBundle {
    var body: some Widget {
#if ZW_SCREENSHOTS
        // Keep private configurations first: XCUITest must traverse the picker
        // carousel for every placement, so this halves the required swipes.
        ScreenshotSolarWidget()
        ScreenshotWasherWidget()
        ScreenshotBoilerWidget()
        ScreenshotEnergyLargeWidget()
        ScreenshotEnergyWideWidget()
        ScreenshotDeploysWidget()
        ScreenshotDeviceFleetWidget()
#endif
        CardWidget()
        CardGridWidget()
        ZeroZeroWidgetLiveActivityWidget()
    }
}
