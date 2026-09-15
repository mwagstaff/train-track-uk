import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct SiriRouteStoreTests {
    @Test func readsExistingJourneyJSONWithoutChoosingADefaultOrWriting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let journey = leg()
        let data = try JSONEncoder().encode([journey])
        fixture.defaults.set(data, forKey: "saved_journeys")
        let before = fixture.defaults.persistentDomain(forName: fixture.suiteName) as NSDictionary?
        var updates = 0
        let store = SiriRouteStore(defaults: fixture.defaults, updateSuggestions: { updates += 1 })

        #expect(store.routes.map(\.id) == [journey.groupId])
        #expect(store.route(id: journey.groupId)?.origin.crs == "KTH")
        #expect(store.defaultRoute == nil)
        #expect(store.defaultRouteID == nil)
        #expect(updates == 0)
        #expect(before == fixture.defaults.persistentDomain(forName: fixture.suiteName) as NSDictionary?)
    }

    @Test func defaultAndRenameSurviveRelaunchWithoutChangingJourneyOrEntityIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let journey = leg()
        let data = try JSONEncoder().encode([journey])
        fixture.defaults.set(data, forKey: "saved_journeys")
        var updates = 0
        let store = SiriRouteStore(defaults: fixture.defaults, updateSuggestions: { updates += 1 })

        store.setDefaultRoute(id: journey.groupId)
        store.setName("  Work  ", for: journey.groupId)
        let restored = SiriRouteStore(defaults: fixture.defaults)

        #expect(restored.defaultRouteID == journey.groupId)
        #expect(restored.defaultRoute?.id == journey.groupId)
        #expect(restored.defaultRoute?.displayName == "Work")
        #expect(restored.route(id: journey.groupId)?.destination.crs == "VIC")
        #expect(fixture.defaults.data(forKey: "saved_journeys") == data)
        #expect(updates == 2)
    }

    @Test func deletedDefaultDoesNotResolveToAnotherFavourite() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = leg()
        let second = leg(from: "ECR", to: "BTN")
        var journeys = [first, second]
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { journeys })
        store.setDefaultRoute(id: first.groupId)
        journeys = [second]
        store.refresh()

        #expect(store.defaultRouteID == first.groupId)
        #expect(store.defaultRoute == nil)
        #expect(store.route(id: first.groupId) == nil)
        #expect(store.routes.map(\.id) == [second.groupId])
    }

    @Test func unfavouritingPreservesShortcutSuggestionsAndDefault() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = leg()
        var journeys = [original]
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { journeys })
        store.setDefaultRoute(id: original.groupId)
        store.setName("Work", for: original.groupId)
        journeys = [Journey(
            id: original.id, groupId: original.groupId, legIndex: original.legIndex,
            fromStation: original.fromStation, toStation: original.toStation,
            createdAt: original.createdAt, favorite: false
        )]

        #expect(store.routes.map(\.id) == [original.groupId])
        #expect(store.defaultRoute?.id == original.groupId)
        #expect(store.defaultRoute?.isFavourite == false)
        #expect(store.defaultRouteID == original.groupId)
        #expect(store.route(id: original.groupId)?.displayName == "Work")
    }

    @Test func multiLegGroupsCannotBeDefaultSuggestedOrResolvedAsDirect() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let groupID = UUID()
        let journeys = [
            leg(groupID: groupID),
            leg(groupID: groupID, legIndex: 1, from: "VIC", to: "BTN")
        ]
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { journeys })
        store.setDefaultRoute(id: groupID)

        #expect(store.routes.isEmpty)
        #expect(store.route(id: groupID) == nil)
        #expect(store.defaultRouteID == nil)
    }

    @Test func legacyUngroupedJourneysKeepOriginalUUID() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = leg()
        let encoded = try JSONEncoder().encode([original])
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        json[0].removeValue(forKey: "groupId")
        json[0].removeValue(forKey: "legIndex")
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "saved_journeys")

        let store = SiriRouteStore(defaults: fixture.defaults)
        #expect(store.routes.map(\.id) == [original.id])
        #expect(store.route(id: original.id)?.origin.crs == "KTH")
    }

    @Test func duplicateNamesRetainDistinctRoutesAndBlankNameRestoresStations() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = leg()
        let second = leg(from: "ECR", to: "BTN")
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { [first, second] })
        store.setName("Work", for: first.groupId)
        store.setName("Work", for: second.groupId)

        #expect(store.routes.count == 2)
        #expect(Set(store.routes.map(\.id)) == Set([first.groupId, second.groupId]))
        #expect(store.routes.allSatisfy { $0.displayName == "Work" })
        #expect(Set(store.routes.map(\.stationSummary)).count == 2)

        store.setName(" \n ", for: first.groupId)
        #expect(store.name(for: first.groupId).isEmpty)
        #expect(store.route(id: first.groupId)?.displayName == "KTH → VIC")
    }

    @Test func malformedSavedJourneysDoNotBecomeAnInventedRoute() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(Data("not valid JSON".utf8), forKey: "saved_journeys")
        let store = SiriRouteStore(defaults: fixture.defaults)

        #expect(store.routes.isEmpty)
        #expect(store.defaultRoute == nil)
        #expect(store.route(id: UUID()) == nil)
    }

    @Test func myJourneysRoutesCanBeNamedSuggestedAndDefaulted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let favourite = leg()
        let other = leg(from: "PAD", to: "OXF", favorite: false)
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { [favourite, other] })

        store.setName("Oxford", for: other.groupId)
        store.setDefaultRoute(id: other.groupId)

        #expect(Set(store.routes.map(\.id)) == Set([favourite.groupId, other.groupId]))
        #expect(store.route(id: favourite.groupId)?.isFavourite == true)
        #expect(store.defaultRoute?.isFavourite == false)
        #expect(store.defaultRoute?.displayName == "Oxford")
        #expect(store.namedExampleRoute?.id == other.groupId)
    }

    @Test func savedReversePairHasOneStableEntryButResolvesBothOriginalDirections() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outwardID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let returnID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let outward = leg(groupID: outwardID, favorite: false)
        let returning = leg(groupID: returnID, from: "vic", to: "kth")
        var journeys = [outward, returning]
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { journeys })

        #expect(store.routes.map(\.id) == [returnID])
        #expect(store.routes.first?.isBidirectional == true)
        #expect(store.routes.first?.isFavourite == true)
        #expect(store.routes.first?.stationSummary == "vic ↔ kth")
        #expect(store.route(id: outwardID)?.origin.crs == "KTH")
        #expect(store.route(id: returnID)?.origin.crs == "vic")
        #expect(store.directions(for: outwardID).map(\.id) == [outwardID, returnID])
        #expect(store.directions(for: returnID).map(\.id) == [returnID, outwardID])
        #expect(store.route(id: outwardID)?.pairKey == store.route(id: returnID)?.pairKey)
        journeys.reverse()
        #expect(store.routes.map(\.id) == [returnID])
        store.setDefaultRoute(id: outwardID)
        #expect(store.defaultRouteID == outwardID)
        #expect(store.defaultRoute?.origin.crs == "KTH")
        #expect(store.defaultRoute?.pairKey == store.routes.first?.pairKey)
    }

    @Test func routeNamesApplyToBothDirectionsAndPersistWithoutChangingJourneyData() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outward = leg()
        let returning = leg(from: "VIC", to: "KTH", favorite: false)
        let data = try JSONEncoder().encode([outward, returning])
        fixture.defaults.set(data, forKey: "saved_journeys")
        let store = SiriRouteStore(defaults: fixture.defaults)
        store.setName("  Commute ", for: returning.groupId)
        store.setDefaultRoute(id: returning.groupId)
        let restored = SiriRouteStore(defaults: fixture.defaults)

        #expect(restored.routes.count == 1)
        #expect(restored.route(id: outward.groupId)?.displayName == "Commute")
        #expect(restored.route(id: returning.groupId)?.displayName == "Commute")
        #expect(restored.defaultRouteID == returning.groupId)
        #expect(restored.defaultRoute?.origin.crs == "VIC")
        #expect(fixture.defaults.data(forKey: "saved_journeys") == data)
        #expect(fixture.defaults.dictionary(forKey: "siri_route_names_v2") as? [String: String] == ["KTH|VIC": "Commute"])
    }

    @Test func legacyNamesReadThroughPrefersDefaultDirectionWithoutWriting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outward = leg(groupID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let returning = leg(groupID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, from: "VIC", to: "KTH")
        fixture.defaults.set([outward.groupId.uuidString: "Work", returning.groupId.uuidString: "Home"], forKey: "siri_route_names_v1")
        fixture.defaults.set(returning.groupId.uuidString, forKey: "siri_default_route_id_v1")
        let before = fixture.defaults.persistentDomain(forName: fixture.suiteName) as NSDictionary?
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { [outward, returning] })

        #expect(store.routes.first?.displayName == "Home")
        #expect(store.name(for: outward.groupId) == "Home")
        #expect(store.name(for: returning.groupId) == "Home")
        #expect(store.defaultRouteID == returning.groupId)
        #expect(before == fixture.defaults.persistentDomain(forName: fixture.suiteName) as NSDictionary?)
    }

    @Test func switchingAndClearingDefaultPreservesBothPairsResolvedLegacyNames() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outward = leg(groupID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let returning = leg(groupID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, from: "VIC", to: "KTH")
        let oxfordReturn = leg(groupID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, from: "OXF", to: "PAD")
        let oxfordOutward = leg(groupID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, from: "PAD", to: "OXF")
        let legacyNames = [outward.groupId.uuidString: "Work", returning.groupId.uuidString: "Home",
                           oxfordReturn.groupId.uuidString: "Oxford trips", oxfordOutward.groupId.uuidString: "Oxford outward"]
        fixture.defaults.set(legacyNames, forKey: "siri_route_names_v1")
        fixture.defaults.set(returning.groupId.uuidString, forKey: "siri_default_route_id_v1")
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { [outward, returning, oxfordReturn, oxfordOutward] })
        #expect(store.name(for: outward.groupId) == "Home")
        #expect(store.name(for: oxfordOutward.groupId) == "Oxford trips")

        store.setDefaultRoute(id: oxfordOutward.groupId)
        #expect(store.name(for: outward.groupId) == "Home")
        #expect(store.defaultRoute?.displayName == "Oxford trips")
        store.setDefaultRoute(id: nil)
        #expect(store.name(for: returning.groupId) == "Home")
        #expect(store.name(for: oxfordReturn.groupId) == "Oxford trips")
        #expect(store.defaultRoute == nil)
        #expect(fixture.defaults.dictionary(forKey: "siri_route_names_v2") as? [String: String]
                == ["KTH|VIC": "Home", "OXF|PAD": "Oxford trips"])
        #expect(fixture.defaults.dictionary(forKey: "siri_route_names_v1") as? [String: String] == legacyNames)
    }

    @Test func legacyNameConflictWithoutDefaultUsesDeterministicExistingUUID() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outward = leg(groupID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let returning = leg(groupID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, from: "VIC", to: "KTH")
        fixture.defaults.set([outward.groupId.uuidString: "Work", returning.groupId.uuidString: "Home"], forKey: "siri_route_names_v1")
        var journeys = [returning, outward]
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { journeys })

        #expect(store.routes.first?.displayName == "Work")
        journeys.reverse()
        #expect(store.routes.first?.displayName == "Work")
        #expect(fixture.defaults.object(forKey: "siri_route_names_v2") == nil)
    }

    @Test func clearingSharedNamePreventsEitherLegacyNameFromReturning() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outward = leg()
        let returning = leg(from: "VIC", to: "KTH")
        fixture.defaults.set([outward.groupId.uuidString: "Work", returning.groupId.uuidString: "Home"], forKey: "siri_route_names_v1")
        var journeys = [outward, returning]
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { journeys })
        store.setName(" \n ", for: outward.groupId)
        store.setDefaultRoute(id: returning.groupId)

        #expect(store.name(for: outward.groupId).isEmpty)
        #expect(store.name(for: returning.groupId).isEmpty)
        #expect(store.route(id: outward.groupId)?.displayName == "KTH ↔ VIC")
        #expect(fixture.defaults.dictionary(forKey: "siri_route_names_v2") as? [String: String] == ["KTH|VIC": ""])
        journeys = [returning]
        let restored = SiriRouteStore(defaults: fixture.defaults, readJourneys: { journeys })
        #expect(restored.defaultRoute?.displayName == "VIC → KTH")
        #expect(restored.name(for: returning.groupId).isEmpty)
        #expect(restored.namedExampleRoute == nil)
    }

    @Test func preservingLegacyNamesBeforeDeletionKeepsNameOnRemainingDirection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outward = leg()
        let returning = leg(from: "VIC", to: "KTH")
        let originalData = try JSONEncoder().encode([outward, returning])
        fixture.defaults.set(originalData, forKey: "saved_journeys")
        fixture.defaults.set([outward.groupId.uuidString: "Commute"], forKey: "siri_route_names_v1")
        var suggestionsUpdated = 0
        let store = SiriRouteStore(defaults: fixture.defaults, updateSuggestions: { suggestionsUpdated += 1 })
        #expect(store.name(for: returning.groupId) == "Commute")
        #expect(fixture.defaults.object(forKey: "siri_route_names_v2") == nil)

        // JourneyStore performs this migration before overwriting saved_journeys.
        store.preserveLegacyNames()
        #expect(fixture.defaults.data(forKey: "saved_journeys") == originalData)
        #expect(suggestionsUpdated == 0)
        fixture.defaults.set(try JSONEncoder().encode([returning]), forKey: "saved_journeys")
        store.refresh()

        #expect(store.route(id: outward.groupId) == nil)
        #expect(store.routes.map(\.id) == [returning.groupId])
        #expect(store.routes.first?.displayName == "Commute")
        #expect(store.routes.first?.isBidirectional == false)
        #expect(store.defaultRouteID == nil)
        #expect(suggestionsUpdated == 1)
        #expect(fixture.defaults.dictionary(forKey: "siri_route_names_v1") as? [String: String]
                == [outward.groupId.uuidString: "Commute"])
    }

    @Test func deletingOneDirectionNeverRebindsItsShortcutOrDefaultToTheReverse() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outward = leg()
        let returning = leg(from: "VIC", to: "KTH")
        var journeys = [outward, returning]
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { journeys })
        store.setName("Commute", for: outward.groupId)
        store.setDefaultRoute(id: returning.groupId)
        journeys = [outward]

        #expect(store.defaultRouteID == returning.groupId)
        #expect(store.defaultRoute == nil)
        #expect(store.route(id: returning.groupId) == nil)
        #expect(store.directions(for: returning.groupId).isEmpty)
        #expect(store.routes.map(\.id) == [outward.groupId])
        #expect(store.routes.first?.isBidirectional == false)
        #expect(store.routes.first?.displayName == "Commute")
        #expect(store.directions(for: outward.groupId).map(\.id) == [outward.groupId])
    }

    @Test func connectingLegsAndUnsavedReturnsAreNeverAddedAsDirections() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let direct = leg()
        let connectingID = UUID()
        let journeys = [direct, leg(groupID: connectingID, from: "VIC", to: "KTH"),
                        leg(groupID: connectingID, legIndex: 1, from: "KTH", to: "BTN")]
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { journeys })

        #expect(store.routes.map(\.id) == [direct.groupId])
        #expect(store.routes.first?.isBidirectional == false)
        #expect(store.directions(for: direct.groupId).map(\.id) == [direct.groupId])
        #expect(store.directions(for: connectingID).isEmpty)
    }

    @Test func favouritingEitherDirectionChangesPairCategoryWithoutChangingIdentityOrDefault() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outward = leg(favorite: false)
        let returning = leg(from: "VIC", to: "KTH", favorite: false)
        var journeys = [outward, returning]
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { journeys })
        let originalID = store.routes.first?.id
        store.setDefaultRoute(id: returning.groupId)
        #expect(store.routes.first?.isFavourite == false)
        journeys = [outward, leg(groupID: returning.groupId, from: "VIC", to: "KTH", favorite: true)]
        #expect(store.routes.first?.id == originalID)
        #expect(store.routes.first?.isFavourite == true)
        #expect(store.defaultRouteID == returning.groupId)
        journeys = [outward, returning]
        #expect(store.routes.first?.isFavourite == false)
        #expect(store.defaultRoute?.id == returning.groupId)
    }

    @Test func namedExampleDoesNotRequireADefaultAndPrefersANamedDefault() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let favourite = leg()
        let other = leg(from: "PAD", to: "OXF", favorite: false)
        let store = SiriRouteStore(defaults: fixture.defaults, readJourneys: { [favourite, other] })
        #expect(store.namedExampleRoute == nil)
        store.setName("Oxford", for: other.groupId)
        #expect(store.namedExampleRoute?.id == other.groupId)
        store.setDefaultRoute(id: favourite.groupId)
        #expect(store.namedExampleRoute?.id == other.groupId)
        store.setName("Work", for: favourite.groupId)
        #expect(store.namedExampleRoute?.id == favourite.groupId)
    }

    private func leg(
        groupID: UUID = UUID(),
        legIndex: Int = 0,
        from: String = "KTH",
        to: String = "VIC",
        favorite: Bool = true
    ) -> Journey {
        Journey(
            id: UUID(), groupId: groupID, legIndex: legIndex,
            fromStation: Station(crs: from, name: from, longitude: "0", latitude: "0"),
            toStation: Station(crs: to, name: to, longitude: "0", latitude: "0"),
            createdAt: Date(timeIntervalSince1970: 1_000_000), favorite: favorite
        )
    }

    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults

        init() throws {
            suiteName = "SiriRouteStoreTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
