import Foundation
import Testing
import JourneyActivityShared

struct LiveActivityNextChangeTests {
    @Test func boardOnlyPushCannotHideTheInitialChangeOrEraseRegistrationMetadata() throws {
        var initial = state()
        initial.deepLinkToCRS = "KTH"
        let attributes = JourneyActivityAttributes(displayName: "Blackfriars → Kent House", initialState: initial)
        let restored = try JSONDecoder().decode(JourneyActivityAttributes.self, from: JSONEncoder().encode(attributes))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as? [String: Any])
        for missing in [true, false] {
            if missing { json.removeValue(forKey: "nextChangeStationName") }
            else { json["nextChangeStationName"] = NSNull() }
            let pushed = try JSONDecoder().decode(JourneyActivityAttributes.ContentState.self,
                                                  from: JSONSerialization.data(withJSONObject: json))
            #expect(pushed.nextChangeLabel == nil)
            #expect(restored.nextChangeStation(for: pushed) == "Herne Hill")
        }
    }

    @Test func initialChangeNeverLeaksToAnotherLegRouteOrCompletedJourney() {
        var content = state()
        content.deepLinkToCRS = "KTH"
        let attributes = JourneyActivityAttributes(displayName: "Blackfriars → Kent House", initialState: content)
        content.nextChangeStationName = nil
        content.fromCRS = "HNH"
        content.toCRS = "KTH"
        #expect(attributes.nextChangeStation(for: content) == nil)
        content.fromCRS = "BFR"
        content.toCRS = "HNH"
        content.deepLinkToCRS = "HNH"
        #expect(attributes.nextChangeStation(for: content) == nil)
        content.deepLinkToCRS = "KTH"
        content.journeyPhase = .arrived
        #expect(attributes.nextChangeStation(for: content) == nil)
    }

    @Test func newerInterchangeWinsAndOlderActivitiesStillDecode() throws {
        var content = state()
        let attributes = JourneyActivityAttributes(displayName: "Route", initialState: content)
        content.nextChangeStationName = "Brixton"
        #expect(attributes.nextChangeStation(for: content) == "Brixton")
        let older = try JSONDecoder().decode(JourneyActivityAttributes.self,
                                            from: Data(#"{"displayName":"Route"}"#.utf8))
        #expect(older.initialChange == nil)
        content.nextChangeStationName = nil
        content.connectionStationName = "Herne Hill"
        #expect(older.nextChangeStation(for: content) == "Herne Hill")
    }

    private func state() -> JourneyActivityAttributes.ContentState {
        .init(fromCRS: "BFR", toCRS: "HNH", destinationTitle: "Sutton (London)",
              arrivalLabel: "Arr 11:46", length: 8, platform: "1", estimated: "11:25",
              statusText: "4 minutes late", delayMinutes: 4, nextChangeStationName: "Herne Hill")
    }

    @Test func nextChangeSurvivesEncodingAndRemainsVisibleUntilArrival() throws {
        var content = state()
        for phase in [JourneyActivityAttributes.JourneyPhase.pendingStart, .atStart, .enRoute] {
            content.journeyPhase = phase
            let decoded = try JSONDecoder().decode(JourneyActivityAttributes.ContentState.self,
                                                   from: JSONEncoder().encode(content))
            #expect(decoded.nextChangeLabel == "Herne Hill")
            #expect(decoded.arrivalLabel == "Arr 11:46")
        }
        content.journeyPhase = .arrived
        #expect(content.nextChangeLabel == nil)
    }

    @Test func olderPushesAndFinalLegsDoNotInventAChange() throws {
        var content = state()
        let data = try JSONEncoder().encode(content)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "nextChangeStationName")
        let older = try JSONDecoder().decode(JourneyActivityAttributes.ContentState.self,
                                             from: JSONSerialization.data(withJSONObject: json))
        #expect(older.nextChangeLabel == nil)
        content.nextChangeStationName = nil
        #expect(content.nextChangeLabel == nil)
        content.nextChangeStationName = " \n "
        #expect(content.nextChangeLabel == nil)
    }
}
