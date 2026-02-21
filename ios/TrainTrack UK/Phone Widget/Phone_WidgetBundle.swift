//
//  Phone_WidgetBundle.swift
//  Phone Widget
//
//  Created by Mike Wagstaff on 05/11/2025.
//

import WidgetKit
import SwiftUI
import OSLog

@main
struct Phone_WidgetBundle: WidgetBundle {
    init() {
        os_log("[Phone_WidgetBundle] ===== BUNDLE INIT =====")
    }

    var body: some Widget {
        let _ = os_log("[Phone_WidgetBundle] ===== BODY CALLED =====")
        if #available(iOS 17.0, *) {
            let _ = os_log("[Phone_WidgetBundle] Registering CustomJourneyWidget")
            CustomJourneyWidget()
        }
        let _ = os_log("[Phone_WidgetBundle] Registering ClosestFavouriteWidget")
        ClosestFavouriteWidget()
        let _ = os_log("[Phone_WidgetBundle] Registering ClosestStationWidget")
        ClosestStationWidget()
        if #available(iOS 18.0, *) {
            let _ = os_log("[Phone_WidgetBundle] Registering Phone_WidgetControl")
            Phone_WidgetControl()
        }
    }
}
