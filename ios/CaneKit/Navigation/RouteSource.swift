//
//  RouteSource.swift
//  CaneKit
//
//  Where routes come from: the hand-verified file in the bundle (the demo), or live MapKit
//  walking directions to any typed destination (the "any destination" fallback), converted to
//  the same `Route` so the engine never knows the difference.
//
//  Owner: module `navigation-trip` (docs/CODE_REFERENCE.md). Stateless; called only by
//  `AppModel.startDemoRoute()` and `AppModel.startMapKitRoute()`.
//
//  Threading / isolation: static functions, main actor by the target default. `mapKit(to:from:)`
//  is async (MKLocalSearch / MKDirections suspend; results return on the main actor).
//
//  Key invariants:
//    · Both paths yield a `CaneKitLogic.Route`; the MapKit → waypoint conversion is pure logic in
//      `RouteBuilder` (Waypoint.swift). ⚠ Do not change the search region, result types or the
//      converter contract without re-running `mapKitStepsBecomeWaypoints` (RouteTests).
//    · The bundled file is `Resources/route_isr_cif.json`; ⚠ editing it requires re-running
//      `shippedRouteFileIsConsistent` (RouteTests) and a re-walk.
//

import CaneKitLogic
import CoreLocation
import Foundation
import MapKit

/// Namespace for the two route origins.
enum RouteSource {

    /// The bundled ISR → CIF route. Throws if the file is missing or malformed.
    /// Throws `RouteError.missingBundledRoute` when absent, or the decoder's error when malformed.
    static func bundled() throws -> Route {
        guard let url = Bundle.main.url(forResource: "route_isr_cif", withExtension: "json") else {
            throw RouteError.missingBundledRoute
        }
        return try Route.load(from: Data(contentsOf: url))
    }

    /// Walking directions from `origin` to the best `MKLocalSearch` match for `destination`.
    /// Searches a 3 km × 3 km region around `origin` (points of interest and addresses), takes
    /// the first match and the first walking route, and converts each MapKit step to
    /// `RouteStepInput` for `RouteBuilder`. Needs network. Throws `RouteError.destinationNotFound`
    /// / `.noRoute`, or MapKit's own errors.
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

/// Route-building failures. `errorDescription` is shown as `AppModel.routeError` and spoken.
enum RouteError: LocalizedError {
    /// `route_isr_cif.json` is not in the app bundle.
    case missingBundledRoute
    /// MKLocalSearch found nothing for the typed text (carried for the message).
    case destinationNotFound(String)
    /// MKDirections returned no walking route.
    case noRoute

    /// User-facing message (no trailing period: AppModel adds context around it).
    var errorDescription: String? {
        switch self {
        case .missingBundledRoute: return "The bundled route file is missing"
        case .destinationNotFound(let d): return "Could not find \"\(d)\""
        case .noRoute: return "No walking route found"
        }
    }
}

private extension MKPolyline {
    /// All vertices of the polyline, in order (copied out with `getCoordinates`).
    var coordinates: [CLLocationCoordinate2D] {
        var out = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&out, range: NSRange(location: 0, length: pointCount))
        return out
    }
}
