//
//  RouteSource.swift
//  CaneKit
//
//  Where routes come from: the hand-verified file in the bundle (the demo), or live MapKit
//  walking directions to any typed destination (the "any destination" fallback), converted to
//  the same `Route` so the engine never knows the difference.
//

import CaneKitLogic
import CoreLocation
import Foundation
import MapKit

enum RouteSource {

    /// The bundled ISR → CIF route. Throws if the file is missing or malformed.
    static func bundled() throws -> Route {
        guard let url = Bundle.main.url(forResource: "route_isr_cif", withExtension: "json") else {
            throw RouteError.missingBundledRoute
        }
        return try Route.load(from: Data(contentsOf: url))
    }

    /// Walking directions from `origin` to the best `MKLocalSearch` match for `destination`.
    static func mapKit(to destination: String, from origin: CLLocationCoordinate2D) async throws -> Route {
        let search = MKLocalSearch.Request()
        search.naturalLanguageQuery = destination
        search.region = MKCoordinateRegion(center: origin, latitudinalMeters: 3000, longitudinalMeters: 3000)
        search.resultTypes = [.pointOfInterest, .address]
        let found = try await MKLocalSearch(request: search).start()
        guard let item = found.mapItems.first else { throw RouteError.destinationNotFound(destination) }

        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = item
        request.transportType = .walking
        let directions = try await MKDirections(request: request).calculate()
        guard let route = directions.routes.first else { throw RouteError.noRoute }

        let steps = route.steps.map { step in
            RouteStepInput(points: step.polyline.coordinates.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) },
                           instructions: step.instructions)
        }
        let name = item.name ?? destination
        return Route(name: "To \(name)", waypoints: RouteBuilder.waypoints(from: steps, destinationName: name))
    }
}

enum RouteError: LocalizedError {
    case missingBundledRoute
    case destinationNotFound(String)
    case noRoute

    var errorDescription: String? {
        switch self {
        case .missingBundledRoute: return "The bundled route file is missing"
        case .destinationNotFound(let d): return "Could not find \"\(d)\""
        case .noRoute: return "No walking route found"
        }
    }
}

private extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var out = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&out, range: NSRange(location: 0, length: pointCount))
        return out
    }
}
