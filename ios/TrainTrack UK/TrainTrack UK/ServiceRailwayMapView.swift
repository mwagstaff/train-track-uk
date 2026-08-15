import SwiftUI
import MapKit

struct ServiceRailwayMapView: View {
    let route: ServiceRailwayRoute
    let stations: [CallingPoint]
    let progress: ServiceProgressEstimate
    let estimatedTrainCoordinate: CLLocationCoordinate2D?
    let fromCRS: String
    let toCRS: String

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCenteredOnTrain = false

    var body: some View {
        Map(position: $cameraPosition, interactionModes: .all) {
            MapPolyline(coordinates: route.coordinates)
                .stroke(.secondary.opacity(0.45), lineWidth: 6)

            if selectedRouteCoordinates.count >= 2 {
                MapPolyline(coordinates: selectedRouteCoordinates)
                    .stroke(Color.accentColor, lineWidth: 6)
            }

            ForEach(stations.indices, id: \.self) { index in
                if let coordinate = route.coordinate(atStation: index) {
                    Annotation(stations[index].locationName, coordinate: coordinate) {
                        stationDot(for: index)
                            .accessibilityLabel(stationAccessibilityLabel(for: index))
                    }
                    .annotationTitles(.hidden)
                }
            }

            if let trainCoordinate {
                Annotation("Estimated train position", coordinate: trainCoordinate) {
                    estimatedTrainMarker
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .topTrailing) {
            Button {
                centerOnTrainOrFrameRoute()
            } label: {
                Label("Center on train", systemImage: "scope")
                    .labelStyle(.iconOnly)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .background(.regularMaterial, in: Circle())
            .padding(12)
            .accessibilityLabel("Center on estimated train position")
        }
        .onAppear {
            centerOnTrainOrFrameRoute()
        }
        .onChange(of: trainCoordinateKey) { _, _ in
            guard !hasCenteredOnTrain, trainCoordinate != nil else { return }
            centerOnTrainOrFrameRoute()
        }
    }

    private var selectedRouteCoordinates: [CLLocationCoordinate2D] {
        let normalizedFrom = fromCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedTo = toCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let start = stations.firstIndex(where: {
            $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedFrom
        }), let end = stations.indices.first(where: { index in
            index >= start
                && stations[index].crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedTo
        }) else {
            return route.coordinates
        }
        return route.coordinates(fromStation: start, throughStation: end)
    }

    private var trainCoordinate: CLLocationCoordinate2D? {
        if let estimatedTrainCoordinate {
            return estimatedTrainCoordinate
        }
        guard progress.isAvailable else { return nil }
        return route.coordinate(
            fromStation: progress.previousStationIndex,
            toStation: progress.nextStationIndex,
            progress: progress.fraction
        )
    }

    private var trainCoordinateKey: String {
        guard let trainCoordinate else { return "unavailable" }
        return "\(trainCoordinate.latitude),\(trainCoordinate.longitude)"
    }

    private var estimatedTrainMarker: some View {
        VStack(spacing: 3) {
            Text("Estimated position")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .foregroundStyle(.primary)
                .background(.regularMaterial, in: Capsule())
            Image(systemName: "train.side.front.car")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated train position")
    }

    @ViewBuilder
    private func stationDot(for index: Int) -> some View {
        if index == departureStationIndex {
            VStack(spacing: 3) {
                Text("Departure")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .foregroundStyle(.primary)
                    .background(.regularMaterial, in: Capsule())
                Circle()
                    .fill(.orange)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
        } else {
            let state = stationState(for: index)
            Circle()
                .fill(state.fill)
                .frame(width: state.isCurrent ? 16 : 12, height: state.isCurrent ? 16 : 12)
                .overlay(Circle().stroke(state.stroke, lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
        }
    }

    private var departureStationIndex: Int? {
        let normalizedFrom = fromCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return stations.firstIndex {
            $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedFrom
        }
    }

    private func stationState(for index: Int) -> (fill: Color, stroke: Color, isCurrent: Bool) {
        let isCurrent = progress.isAvailable
            && progress.previousStationIndex == progress.nextStationIndex
            && index == progress.previousStationIndex
        if isCurrent {
            return (.white, Color.accentColor, true)
        }
        if progress.isAvailable && index <= progress.previousStationIndex {
            return (Color.accentColor, .white, false)
        }
        return (.white, .secondary, false)
    }

    private func stationAccessibilityLabel(for index: Int) -> String {
        if index == departureStationIndex {
            return "\(stations[index].locationName), departure station"
        }
        let status: String
        if progress.isAvailable,
           progress.previousStationIndex == progress.nextStationIndex,
           index == progress.previousStationIndex {
            status = "current station"
        } else if progress.isAvailable && index <= progress.previousStationIndex {
            status = "completed"
        } else {
            status = "upcoming"
        }
        return "\(stations[index].locationName), \(status)"
    }

    private func centerOnTrainOrFrameRoute() {
        guard let trainCoordinate else {
            frameRoute()
            return
        }
        cameraPosition = .region(MKCoordinateRegion(
            center: trainCoordinate,
            latitudinalMeters: 4_500,
            longitudinalMeters: 4_500
        ))
        hasCenteredOnTrain = true
    }

    private func frameRoute() {
        guard route.coordinates.count >= 2 else { return }
        let polyline = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count)
        let rect = polyline.boundingMapRect
        let horizontalPadding = max(rect.size.width * 0.12, 800)
        let verticalPadding = max(rect.size.height * 0.12, 800)
        cameraPosition = .rect(rect.insetBy(dx: -horizontalPadding, dy: -verticalPadding))
    }
}
