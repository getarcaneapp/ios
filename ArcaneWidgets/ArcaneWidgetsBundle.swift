//
//  ArcaneWidgetsBundle.swift
//  ArcaneWidgets
//
//  Created by Kyle Mendell on 7/2/26.
//

import WidgetKit
import SwiftUI

@main
struct ArcaneWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        EnvironmentsWidget()
        UpdatesWidget()
    }
}
