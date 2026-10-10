//
//  ArcaneWidgetsBundle.swift
//  ArcaneWidgets
//
//  Created by Kyle Mendell on 7/2/26.
//

import SwiftUI
import WidgetKit

@main
struct ArcaneWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        EnvironmentsWidget()
        UpdatesWidget()
        DeployLiveActivity()
    }
}
