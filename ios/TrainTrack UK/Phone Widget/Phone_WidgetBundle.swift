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
        #if DEBUG
        os_log("[Phone_WidgetBundle] ===== BUNDLE INIT =====")
        #endif
    }

    var body: some Widget {
        #if DEBUG
        let _ = os_log("[Phone_WidgetBundle] ===== BODY CALLED =====")
        #endif
        if #available(iOS 17.0, *) {
            #if DEBUG
            let _ = os_log("[Phone_WidgetBundle] Registering CustomJourneyWidget")
            #endif
            CustomJourneyWidget()
        }
        #if DEBUG
        let _ = os_log("[Phone_WidgetBundle] Registering ClosestFavouriteWidget")
        #endif
        ClosestFavouriteWidget()
        #if DEBUG
        let _ = os_log("[Phone_WidgetBundle] Registering ClosestStationWidget")
        #endif
        ClosestStationWidget()
        if #available(iOS 18.0, *) {
            #if DEBUG
            let _ = os_log("[Phone_WidgetBundle] Registering Phone_WidgetControl")
            #endif
            Phone_WidgetControl()
        }
        #if DEBUG
        let _ = os_log("[Phone_WidgetBundle] Registering Journey Live Activity")
        #endif
        Live_ActivityLiveActivity()
    }
}
