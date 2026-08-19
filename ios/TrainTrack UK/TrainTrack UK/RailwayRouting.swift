import Foundation
import CoreLocation

nonisolated struct ServiceRailwayRoute: Sendable {
    let coordinates: [CLLocationCoordinate2D]
    let cumulativeDistances: [CLLocationDistance]
    let stationCoordinateIndices: [Int]

    var totalLength: CLLocationDistance {
        cumulativeDistances.last ?? 0
    }

    var stationCount: Int {
        stationCoordinateIndices.count
    }

    func coordinate(atStation index: Int) -> CLLocationCoordinate2D? {
        guard stationCoordinateIndices.indices.contains(index) else { return nil }
        return coordinates[stationCoordinateIndices[index]]
    }

    func coordinate(atFloatingStationIndex index: Double) -> CLLocationCoordinate2D? {
        guard stationCount > 0, index.isFinite else { return nil }
        let clamped = min(max(index, 0), Double(stationCount - 1))
        let lowerStation = Int(floor(clamped))
        let upperStation = Int(ceil(clamped))
        if lowerStation == upperStation {
            return coordinate(atStation: lowerStation)
        }

        let lowerDistance = cumulativeDistances[stationCoordinateIndices[lowerStation]]
        let upperDistance = cumulativeDistances[stationCoordinateIndices[upperStation]]
        let progress = clamped - Double(lowerStation)
        return coordinate(atDistance: lowerDistance + ((upperDistance - lowerDistance) * progress))
    }

    func coordinate(
        fromStation start: Int,
        toStation end: Int,
        progress: Double
    ) -> CLLocationCoordinate2D? {
        guard stationCoordinateIndices.indices.contains(start),
              stationCoordinateIndices.indices.contains(end) else {
            return nil
        }
        let clampedProgress = min(max(progress, 0), 1)
        let startDistance = cumulativeDistances[stationCoordinateIndices[start]]
        let endDistance = cumulativeDistances[stationCoordinateIndices[end]]
        return coordinate(atDistance: startDistance + ((endDistance - startDistance) * clampedProgress))
    }

    func coordinates(fromStation start: Int, throughStation end: Int) -> [CLLocationCoordinate2D] {
        guard stationCount > 0 else { return [] }
        let lowerStation = min(max(min(start, end), 0), stationCount - 1)
        let upperStation = min(max(max(start, end), 0), stationCount - 1)
        let lowerCoordinate = stationCoordinateIndices[lowerStation]
        let upperCoordinate = stationCoordinateIndices[upperStation]
        guard lowerCoordinate <= upperCoordinate else { return [] }
        return Array(coordinates[lowerCoordinate...upperCoordinate])
    }

    private func coordinate(atDistance distance: CLLocationDistance) -> CLLocationCoordinate2D? {
        guard let first = coordinates.first, let last = coordinates.last else { return nil }
        if distance <= 0 { return first }
        if distance >= totalLength { return last }

        var lower = 0
        var upper = cumulativeDistances.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if cumulativeDistances[middle] < distance {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        let upperIndex = lower
        let lowerIndex = max(0, upperIndex - 1)
        let segmentStart = cumulativeDistances[lowerIndex]
        let segmentEnd = cumulativeDistances[upperIndex]
        let segmentLength = segmentEnd - segmentStart
        guard segmentLength > 0 else { return coordinates[upperIndex] }
        let progress = (distance - segmentStart) / segmentLength
        let start = coordinates[lowerIndex]
        let end = coordinates[upperIndex]
        return CLLocationCoordinate2D(
            latitude: start.latitude + ((end.latitude - start.latitude) * progress),
            longitude: start.longitude + ((end.longitude - start.longitude) * progress)
        )
    }
}

nonisolated enum RailwayRoutingError: LocalizedError {
    case resourceMissing
    case invalidResource
    case insufficientCallingPoints
    case stationOutsideCoverage(String)
    case routeUnavailable(String, String)

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            return "The railway map data is unavailable."
        case .invalidResource:
            return "The railway map data couldn't be loaded."
        case .insufficientCallingPoints:
            return "At least two calling points are needed to map this service."
        case .stationOutsideCoverage(let crs):
            return "Station \(crs) is outside the selected railway map coverage."
        case .routeUnavailable(let start, let end):
            return "No mainline route could be found between \(start) and \(end)."
        }
    }
}

actor RailwayRoutingService {
    static let shared = RailwayRoutingService()

    private let bundle: Bundle
    private var graph: RailwayGraph?
    private var graphLoadTask: Task<RailwayGraph, Error>?
    private var pathCache: [PathKey: GraphPath] = [:]
    private var unreachablePaths: Set<PathKey> = []
    private let adjacentBacktrackFactor = 4.0

    init(
        bundle: Bundle = Bundle(for: RailwayRoutingBundleToken.self)
    ) {
        self.bundle = bundle
    }

    func prepare() async throws {
        try Task.checkCancellation()
        _ = try await loadGraph()
    }

    func route(forStationCRSs stationCRSs: [String]) async throws -> ServiceRailwayRoute {
        let normalizedCRSs = stationCRSs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        guard normalizedCRSs.count >= 2 else {
            throw RailwayRoutingError.insufficientCallingPoints
        }
        try Task.checkCancellation()

        let graph = try await loadGraph()
        try Task.checkCancellation()
        let candidates = try normalizedCRSs.map { crs -> [RailwayAnchor] in
            guard let anchors = graph.stationAnchors[crs], !anchors.isEmpty else {
                throw RailwayRoutingError.stationOutsideCoverage(crs)
            }
            return anchors
        }

        var layers = [[RouteChoice?]]()
        layers.append(candidates[0].map {
            RouteChoice(score: $0.distance * 2, previousCandidate: nil, incomingPath: nil)
        })

        for stationIndex in 1..<candidates.count {
            try Task.checkCancellation()
            var nextLayer = Array<RouteChoice?>(repeating: nil, count: candidates[stationIndex].count)
            for (nextCandidateIndex, nextCandidate) in candidates[stationIndex].enumerated() {
                var bestChoice: RouteChoice?
                for (previousCandidateIndex, previousCandidate) in candidates[stationIndex - 1].enumerated() {
                    guard let previousChoice = layers[stationIndex - 1][previousCandidateIndex] else {
                        continue
                    }
                    guard let path = try shortestPath(
                        in: graph,
                        from: previousCandidate.node,
                        to: nextCandidate.node
                    ) else {
                        continue
                    }

                    let backtrackLength = sharedPathLength(
                        previousChoice.incomingPath,
                        path,
                        graph: graph
                    )
                    let score = previousChoice.score
                        + path.cost
                        + (nextCandidate.distance * 2)
                        + (backtrackLength * adjacentBacktrackFactor)
                    if bestChoice == nil || score < bestChoice!.score {
                        bestChoice = RouteChoice(
                            score: score,
                            previousCandidate: previousCandidateIndex,
                            incomingPath: path
                        )
                    }
                }
                nextLayer[nextCandidateIndex] = bestChoice
            }

            guard nextLayer.contains(where: { $0 != nil }) else {
                throw RailwayRoutingError.routeUnavailable(
                    normalizedCRSs[stationIndex - 1],
                    normalizedCRSs[stationIndex]
                )
            }
            layers.append(nextLayer)
        }

        guard let finalCandidate = layers.last?.enumerated().compactMap({ index, choice in
            choice.map { (index, $0.score) }
        }).min(by: { $0.1 < $1.1 })?.0 else {
            throw RailwayRoutingError.invalidResource
        }

        var segmentPaths = Array<GraphPath?>(repeating: nil, count: normalizedCRSs.count - 1)
        var candidateIndex = finalCandidate
        for stationIndex in stride(from: normalizedCRSs.count - 1, through: 1, by: -1) {
            guard let choice = layers[stationIndex][candidateIndex],
                  let previousCandidate = choice.previousCandidate,
                  let incomingPath = choice.incomingPath else {
                throw RailwayRoutingError.invalidResource
            }
            segmentPaths[stationIndex - 1] = incomingPath
            candidateIndex = previousCandidate
        }

        return try merge(segmentPaths.compactMap { $0 }, graph: graph)
    }

    private func sharedPathLength(
        _ first: GraphPath?,
        _ second: GraphPath,
        graph: RailwayGraph
    ) -> CLLocationDistance {
        guard let first else { return 0 }
        let firstEdges = Set(first.traversals.map(\.edge))
        let secondEdges = Set(second.traversals.map(\.edge))
        return firstEdges.intersection(secondEdges).reduce(0) { result, edge in
            result + graph.edges[edge].length
        }
    }

    private func loadGraph() async throws -> RailwayGraph {
        if let graph { return graph }
        if let graphLoadTask {
            let loaded = try await graphLoadTask.value
            graph = loaded
            self.graphLoadTask = nil
            return loaded
        }

        let bundle = bundle
        // A refreshed service can cancel and replace its route request while the graph is
        // loading. Keep that reusable work independent so the replacement awaits the same load.
        let loadTask = Task.detached {
            try RailwayGraphLoader.load(bundle: bundle)
        }
        graphLoadTask = loadTask
        let loaded = try await loadTask.value
        graph = loaded
        graphLoadTask = nil
        return loaded
    }

    private func shortestPath(in graph: RailwayGraph, from start: Int, to end: Int) throws -> GraphPath? {
        if start == end { return GraphPath(length: 0, cost: 0, traversals: []) }
        let key = PathKey(start: start, end: end)
        if let cached = pathCache[key] { return cached }
        if unreachablePaths.contains(key) { return nil }

        guard graph.components[start] == graph.components[end] else {
            unreachablePaths.insert(key)
            return nil
        }

        let heuristicPath = try search(in: graph, from: start, to: end, usesHeuristic: true)
        let path = try heuristicPath
            ?? search(in: graph, from: start, to: end, usesHeuristic: false)
        guard let path else {
            unreachablePaths.insert(key)
            return nil
        }

        pathCache[key] = path
        let reverseKey = PathKey(start: end, end: start)
        pathCache[reverseKey] = GraphPath(
            length: path.length,
            cost: path.cost,
            traversals: path.traversals.reversed().map {
                RailwayTraversal(edge: $0.edge, from: $0.to, to: $0.from)
            }
        )
        return path
    }

    private func search(
        in graph: RailwayGraph,
        from start: Int,
        to end: Int,
        usesHeuristic: Bool
    ) throws -> GraphPath? {
        func heuristic(for node: Int) -> CLLocationDistance {
            usesHeuristic ? straightLineDistance(graph.nodes[node], graph.nodes[end]) : 0
        }

        var distances = Array(repeating: Double.infinity, count: graph.nodes.count)
        var previousNodes = Array(repeating: -1, count: graph.nodes.count)
        var previousEdges = Array(repeating: -1, count: graph.nodes.count)
        var queue = RailwayMinHeap()
        distances[start] = 0
        queue.push(RailwayHeapItem(
            node: start,
            cost: 0,
            priority: heuristic(for: start)
        ))

        var visitedCount = 0
        while let item = queue.pop() {
            visitedCount += 1
            if visitedCount.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let current = item.node
            if current == end { break }
            if item.cost > distances[current] + 0.001 { continue }

            for adjacency in graph.adjacency[current] {
                let edge = graph.edges[adjacency.edge]
                let candidateDistance = distances[current] + edge.cost
                if candidateDistance < distances[adjacency.neighbour] {
                    distances[adjacency.neighbour] = candidateDistance
                    previousNodes[adjacency.neighbour] = current
                    previousEdges[adjacency.neighbour] = adjacency.edge
                    queue.push(RailwayHeapItem(
                        node: adjacency.neighbour,
                        cost: candidateDistance,
                        priority: candidateDistance + heuristic(for: adjacency.neighbour)
                    ))
                }
            }
        }

        guard distances[end].isFinite else { return nil }

        var traversals = [RailwayTraversal]()
        var current = end
        while current != start {
            let previous = previousNodes[current]
            let edge = previousEdges[current]
            guard previous >= 0, edge >= 0 else { return nil }
            traversals.append(RailwayTraversal(edge: edge, from: previous, to: current))
            current = previous
        }
        traversals.reverse()
        let length = traversals.reduce(0.0) { partialResult, traversal in
            partialResult + graph.edges[traversal.edge].length
        }
        return GraphPath(length: length, cost: distances[end], traversals: traversals)
    }

    private func merge(_ paths: [GraphPath], graph: RailwayGraph) throws -> ServiceRailwayRoute {
        guard !paths.isEmpty else { throw RailwayRoutingError.insufficientCallingPoints }
        var coordinates = [CLLocationCoordinate2D]()
        var stationCoordinateIndices = [0]

        for path in paths {
            for traversal in path.traversals {
                let edge = graph.edges[traversal.edge]
                let edgeCoordinates: [CLLocationCoordinate2D]
                if traversal.from == edge.start && traversal.to == edge.end {
                    edgeCoordinates = edge.coordinates
                } else if traversal.from == edge.end && traversal.to == edge.start {
                    edgeCoordinates = Array(edge.coordinates.reversed())
                } else {
                    throw RailwayRoutingError.invalidResource
                }

                if coordinates.isEmpty {
                    coordinates.append(contentsOf: edgeCoordinates)
                } else {
                    guard let existingEnd = coordinates.last,
                          let incomingStart = edgeCoordinates.first,
                          straightLineDistance(existingEnd, incomingStart) < 0.5 else {
                        throw RailwayRoutingError.invalidResource
                    }
                    coordinates.append(contentsOf: edgeCoordinates.dropFirst())
                }
            }
            stationCoordinateIndices.append(max(0, coordinates.count - 1))
        }

        guard coordinates.count >= 2,
              stationCoordinateIndices.count == paths.count + 1 else {
            throw RailwayRoutingError.invalidResource
        }
        var cumulativeDistances = Array(repeating: 0.0, count: coordinates.count)
        for index in 1..<coordinates.count {
            cumulativeDistances[index] = cumulativeDistances[index - 1]
                + straightLineDistance(coordinates[index - 1], coordinates[index])
        }
        return ServiceRailwayRoute(
            coordinates: coordinates,
            cumulativeDistances: cumulativeDistances,
            stationCoordinateIndices: stationCoordinateIndices
        )
    }
}

private nonisolated enum RailwayGraphLoader {
    static func load(bundle: Bundle) throws -> RailwayGraph {
        let resourceURL = bundle.url(
            forResource: "railway-routing-great-britain-osm",
            withExtension: "json",
            subdirectory: "Resources"
        ) ?? bundle.url(
            forResource: "railway-routing-great-britain-osm",
            withExtension: "json"
        )
        guard let resourceURL else { throw RailwayRoutingError.resourceMissing }

        try Task.checkCancellation()
        let data = try Data(contentsOf: resourceURL, options: .mappedIfSafe)
        try Task.checkCancellation()
        let asset: RailwayRoutingAsset
        do {
            asset = try JSONDecoder().decode(RailwayRoutingAsset.self, from: data)
        } catch {
            throw RailwayRoutingError.invalidResource
        }
        try Task.checkCancellation()
        guard asset.metadata.schemaVersion == 1 else {
            throw RailwayRoutingError.invalidResource
        }

        let nodes = asset.nodes
        try Task.checkCancellation()

        let edges = asset.edges
        var adjacency = Array(repeating: [RailwayAdjacency](), count: nodes.count)
        for (edgeIndex, edge) in edges.enumerated() {
            if edgeIndex.isMultiple(of: 2_048) {
                try Task.checkCancellation()
            }
            guard nodes.indices.contains(edge.start),
                  nodes.indices.contains(edge.end),
                  edge.length > 0,
                  edge.length.isFinite,
                  edge.cost > 0,
                  edge.cost.isFinite,
                  edge.coordinates.count >= 2 else {
                throw RailwayRoutingError.invalidResource
            }
            adjacency[edge.start].append(RailwayAdjacency(
                neighbour: edge.end,
                edge: edgeIndex
            ))
            adjacency[edge.end].append(RailwayAdjacency(
                neighbour: edge.start,
                edge: edgeIndex
            ))
        }
        try Task.checkCancellation()

        let anchors: [String: [RailwayAnchor]] = asset.stationAnchors.mapValues { values -> [RailwayAnchor] in
            values.compactMap { anchor -> RailwayAnchor? in
                guard nodes.indices.contains(anchor.node), anchor.distance >= 0 else { return nil }
                return RailwayAnchor(node: anchor.node, distance: anchor.distance)
            }
        }
        let loaded = RailwayGraph(
            nodes: nodes,
            edges: edges,
            adjacency: adjacency,
            stationAnchors: anchors,
            components: railwayConnectedComponents(adjacency: adjacency)
        )
        return loaded
    }
}

private nonisolated final class RailwayRoutingBundleToken {}

private nonisolated struct RailwayRoutingAsset: Decodable {
    let metadata: RailwayRoutingMetadata
    let nodes: [CLLocationCoordinate2D]
    let edges: [RailwayGraphEdge]
    let stationAnchors: [String: [RailwayAnchor]]

    private enum CodingKeys: String, CodingKey {
        case metadata
        case nodes
        case edges
        case stationAnchors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(RailwayRoutingMetadata.self, forKey: .metadata)
        // Decode coordinate pairs straight into their runtime representation. Retaining the
        // JSON's hundreds of thousands of tiny [Double] arrays caused a large cold-load spike.
        nodes = try container.decode([RailwayCoordinate].self, forKey: .nodes).map(\.value)
        edges = try container.decode([RailwayGraphEdge].self, forKey: .edges)
        stationAnchors = try container.decode(
            [String: [RailwayAnchor]].self,
            forKey: .stationAnchors
        )
    }
}

private nonisolated struct RailwayRoutingMetadata: Decodable {
    let schemaVersion: Int
}

private nonisolated struct RailwayCoordinate: Decodable {
    let value: CLLocationCoordinate2D

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let longitude = try container.decode(Double.self)
        let latitude = try container.decode(Double.self)
        guard container.isAtEnd,
              longitude.isFinite,
              latitude.isFinite,
              (-180...180).contains(longitude),
              (-90...90).contains(latitude) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a valid longitude/latitude pair."
            )
        }
        value = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension RailwayGraphEdge: Decodable {
    enum CodingKeys: String, CodingKey {
        case start = "s"
        case end = "e"
        case length = "l"
        case cost = "c"
        case coordinates = "p"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Int.self, forKey: .start)
        end = try container.decode(Int.self, forKey: .end)
        length = try container.decode(Double.self, forKey: .length)
        cost = try container.decodeIfPresent(Double.self, forKey: .cost) ?? length
        coordinates = try container.decode(
            [RailwayCoordinate].self,
            forKey: .coordinates
        ).map(\.value)
    }
}

private nonisolated struct RailwayGraph {
    let nodes: [CLLocationCoordinate2D]
    let edges: [RailwayGraphEdge]
    let adjacency: [[RailwayAdjacency]]
    let stationAnchors: [String: [RailwayAnchor]]
    let components: [Int]
}

private nonisolated struct RailwayGraphEdge {
    let start: Int
    let end: Int
    let length: Double
    let cost: Double
    let coordinates: [CLLocationCoordinate2D]
}

private nonisolated struct RailwayAdjacency {
    let neighbour: Int
    let edge: Int
}

private nonisolated struct RailwayAnchor {
    let node: Int
    let distance: Double
}

extension RailwayAnchor: Decodable {
    enum CodingKeys: String, CodingKey {
        case node = "n"
        case distance = "d"
    }
}

private nonisolated struct RailwayTraversal {
    let edge: Int
    let from: Int
    let to: Int
}

private nonisolated struct GraphPath {
    let length: Double
    let cost: Double
    let traversals: [RailwayTraversal]
}

private nonisolated struct RouteChoice {
    let score: Double
    let previousCandidate: Int?
    let incomingPath: GraphPath?
}

private nonisolated struct PathKey: Hashable {
    let start: Int
    let end: Int
}

private nonisolated struct RailwayHeapItem {
    let node: Int
    let cost: Double
    let priority: Double
}

private nonisolated struct RailwayMinHeap {
    private var items = [RailwayHeapItem]()

    mutating func push(_ item: RailwayHeapItem) {
        items.append(item)
        var index = items.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard items[index].priority < items[parent].priority else { break }
            items.swapAt(index, parent)
            index = parent
        }
    }

    mutating func pop() -> RailwayHeapItem? {
        guard !items.isEmpty else { return nil }
        if items.count == 1 { return items.removeLast() }
        let result = items[0]
        items[0] = items.removeLast()
        var index = 0
        while true {
            let left = (index * 2) + 1
            let right = left + 1
            var smallest = index
            if left < items.count && items[left].priority < items[smallest].priority {
                smallest = left
            }
            if right < items.count && items[right].priority < items[smallest].priority {
                smallest = right
            }
            guard smallest != index else { break }
            items.swapAt(index, smallest)
            index = smallest
        }
        return result
    }
}

private nonisolated func straightLineDistance(
    _ first: CLLocationCoordinate2D,
    _ second: CLLocationCoordinate2D
) -> CLLocationDistance {
    CLLocation(latitude: first.latitude, longitude: first.longitude).distance(
        from: CLLocation(latitude: second.latitude, longitude: second.longitude)
    )
}

private nonisolated func railwayConnectedComponents(
    adjacency: [[RailwayAdjacency]]
) -> [Int] {
    var components = Array(repeating: -1, count: adjacency.count)
    var component = 0
    for start in adjacency.indices where components[start] == -1 {
        var pending = [start]
        components[start] = component
        while let node = pending.popLast() {
            for edge in adjacency[node] where components[edge.neighbour] == -1 {
                components[edge.neighbour] = component
                pending.append(edge.neighbour)
            }
        }
        component += 1
    }
    return components
}
