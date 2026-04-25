import WidgetKit
import SwiftUI

@main
struct ZeroWidgetWidgetBundle: WidgetBundle {
    var body: some Widget {
        MetricWidget()
        StatusWidget()
        ListWidget()
        ProgressWidget()
        ZeroWidgetLiveActivityWidget()
    }
}
