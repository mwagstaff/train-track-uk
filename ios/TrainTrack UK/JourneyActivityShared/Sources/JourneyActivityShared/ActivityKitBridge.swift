import Foundation
#if canImport(ActivityKit)
import ActivityKit

// Declare the ActivityKit conformance in the same module as the type
// to avoid retroactive conformance errors in app/widget targets.
extension JourneyActivityAttributes: ActivityAttributes {}
#endif

