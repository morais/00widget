import WidgetKit
import SwiftUI

@main
struct ZeroZeroWidgetWidgetBundle: WidgetBundle {
    var body: some Widget {
        MetricWidget()
        StatusWidget()
        ListWidget()
        ProgressWidget()
        MetricsGridWidget()
        ZeroZeroWidgetLiveActivityWidget()
    }
}
