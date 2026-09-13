//
//  RouteSource.swift
//  CaneKit
//
//  Where routes come from: the hand-verified file in the bundle (the demo), or live MapKit
//  walking directions from the current GPS fix to a spoken / typed destination or a known
//  entrance coordinate ("Navigate to CIF from here"), converted to the same `Route` so the
//  engine never knows the difference.
//
//  Owner: module `navigation-trip` (docs/CODE_REFERENCE.md). Stateless; called only by
//  `AppModel.startDemoRoute()` (`bundled()`), `AppModel.navigateToCIFFromHere()` (`bundled()` for
//  the route's last waypoint) and `AppModel.buildRoute(to:searchLine:)` (`walking(to:from:)` for
//  the typed field, a tapped suggestion, Siri "Take me to …", the conversational fast path /
//  `navigate_to` tool, and "Navigate to CIF from here"). `DestinationSearch` reads `searchRadiusM`.
//
//  Tests: `RouteTests` (`mapKitStepsBecomeWaypoints`, `shippedRouteFileIsConsistent`),
//  `CampusPlacesTests` (`searchPicksTheNearestReasonableResult`,
//  `gazetteerEndpointsAreTheRouteFileEntrances`). The MapKit calls themselves are untested (network).
//
//  Threading / isolation: static functions, main actor by the target default. The MapKit calls
//  are async (MKLocalSearch / MKDirections suspend; results return on the main actor).
//
//  Key invariants:
//    · Both paths yield a `CaneKitLogic.Route`; the MapKit → waypoint conversion is pure logic in
//      `RouteBuilder` (Waypoint.swift). ⚠ Do not change the converter contract without
//      re-running `mapKitStepsBecomeWaypoints` (RouteTests).
//    · A destination text is resolved in this order: the campus gazetteer
//      (`CampusPlaces.match`), then MKLocalSearch in a 3 km radius around the walker
//      (`regionPriority = .required`, points of interest and addresses), choosing the nearest
//      reasonable result with `DestinationPicker` — never MapKit's first result. ⚠ Pinned by
//      `CampusPlacesTests`; keep `searchRadiusM` equal to `DestinationPicker.maxDistanceM`.
//    · Every MapKit route carries the chosen place name and walking distance (`PlannedRoute`) so
//      AppModel can say "Walking to …, N meters." before guidance starts.
//    · The bundled file is `Resources/route_isr_cif.json`; ⚠ editing it requires re-running
//      `shippedRouteFileIsConsistent` and `gazetteerEndpointsAreTheRouteFileEntrances` and a re-walk.
//

import CaneKitLogic
import CoreLocation
import Foundation
import MapKit

/// What to walk to with MapKit directions. Built by `AppModel` (typed field, Siri intents,
/// the "Navigate to CIF from here" button) and resolved by `RouteSource.walking(to:from:)`.
enum RouteDestination: Sendable, Equatable {
    /// Free text: the campus gazetteer first, then MKLocalSearch near the walker.
    case query(String)
    /// A known entrance (no search): spoken `name` and its coordinate.
    case place(name: String, coordinate: Coordinate)
}

/// A MapKit walking route plus what to say before it starts.
/// Returned by `RouteSource.walking(to:from:)`; consumed by `AppModel.buildRoute`, which logs a
/// `destination` record (`name`, `meters`, `waypoints`) and speaks `WalkingIntro.line` from it.
struct PlannedRoute {
    /// The waypoints to guide along (name "To <place>").
    let route: Route
    /// The chosen destination's spoken name ("Grainger Engineering Library").
    let placeName: String
    /// MapKit's walking distance for the whole route, metres (`MKRoute.distance`).
    let walkingMeters: Double
}

/// Namespace for the two route origins.
enum RouteSource {

    /// Search radius around the walker, metres. The request region is a square of twice this
    /// side; results outside `DestinationPicker.maxDistanceM` (the same 3 km) are rejected anyway.
    static let searchRadiusM: Double = 3000

    /// The bundled ISR → CIF route (`Resources/route_isr_cif.json`, decoded by `Route.load(from:)`).
    /// Throws `RouteError.missingBundledRoute` when absent, or the decoder's error when malformed.
    /// Reads the file on every call (no cache); synchronous, main actor.
    static func bundled() throws -> Route {
        // Step 66 automation hook (simulator stress campaign, `ios/scripts/e2e.py --scenario stress_*`):
        // `CANEKIT_ROUTE_FILE=<absolute path>` replaces the bundled file with any route JSON of the same
        // schema, so the demo-route hook can walk a non-bundled route (ISR → Grainger, CIF → Siebel …)
        // with no MapKit or network. Unset on every normal launch. Side effect to know: `AppModel`'s
        // `bundledRouteName` reads this too, so the cloud `uploadRoute` label says "bundled" for it.
        if let path = ProcessInfo.processInfo.environment["CANEKIT_ROUTE_FILE"], !path.isEmpty {
            return try Route.load(from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        guard let url = Bundle.main.url(forResource: "route_isr_cif", withExtension: "json") else {
            throw RouteError.missingBundledRoute
        }
        return try Route.load(from: Data(contentsOf: url))
    }

    /// Walking directions from `origin` to `destination` (a search text or a known entrance).
    /// Called by `AppModel.buildRoute` once a GPS fix exists (any accuracy). Needs network.
    /// Throws `RouteError.destinationNotFound` / `.noRoute`, or MapKit's own errors (their
    /// `localizedDescription` is shown and spoken). `buildRoute`'s generation check discards a
    /// result that arrives after Stop or after a newer request.
    static func walking(to destination: RouteDestination, from origin: CLLocationCoordinate2D) async throws -> PlannedRoute {
        switch destination {
        case .query(let text):
            return try await mapKit(to: text, from: origin)
        case .place(let name, let coordinate):
            return try await directions(to: mapItem(at: coordinate), name: name, from: origin)
        }
    }

    /// Walking directions from `origin` to the place the text `destination` names.
    /// 1. `CampusPlaces.match` (CIF, ISR, Grainger, Illini Union, Siebel, Main Library, ARC):
    ///    straight to that entrance, no search.
    /// 2. Otherwise MKLocalSearch restricted to a 3 km radius around `origin` (points of interest
    ///    and addresses) and `DestinationPicker.pick` — the nearest result in range, preferring
    ///    names that contain every word typed. MapKit's "no results" becomes
    ///    `RouteError.destinationNotFound`. Why never MapKit's first answer: it ranks famous
    ///    matches anywhere ("Grainger" → an industrial supply store), and the walker cannot see it
    ///    (Step 13, `DestinationPicker`).
    /// Then `directions(to:name:from:)`. A result with no `name` is spoken as the typed text.
    static func mapKit(to destination: String, from origin: CLLocationCoordinate2D) async throws -> PlannedRoute {
        if let place = CampusPlaces.match(destination) {
            return try await directions(to: mapItem(at: place.coordinate), name: place.name, from: origin)
        }
        let search = MKLocalSearch.Request()
        search.naturalLanguageQuery = destination
        search.region = MKCoordinateRegion(center: origin, latitudinalMeters: 2 * searchRadiusM,
                                           longitudinalMeters: 2 * searchRadiusM)
        search.regionPriority = .required       // nearby results, not the most famous match anywhere
        search.resultTypes = [.pointOfInterest, .address]
        let items: [MKMapItem]
        do {
            items = try await MKLocalSearch(request: search).start().mapItems
        } catch let error as MKError where error.code == .placemarkNotFound {
            throw RouteError.destinationNotFound(destination)
        }
        let candidates = items.map { item in
            PlaceCandidate(name: item.name ?? destination,
                           coordinate: Coordinate(latitude: item.location.coordinate.latitude,
                                                  longitude: item.location.coordinate.longitude))
        }
        guard let chosen = DestinationPicker.pick(candidates,
                                                  near: Coordinate(latitude: origin.latitude, longitude: origin.longitude),
                                                  query: destination) else {
            throw RouteError.destinationNotFound(destination)
        }
        return try await directions(to: items[chosen], name: candidates[chosen].name, from: origin)
    }

    /// MKDirections `.walking` from `origin` to `item`; the first route's steps become waypoints
    /// through `RouteBuilder` (arrival line "Arrived at <name>."; 15 m fences, 20 m arrival;
    /// `crossing` when the next instruction says "cross"; never `curved`). Throws `RouteError.noRoute`
    /// when MapKit returns no route or a route with no usable step (already there). The route is
    /// named "To <name>" (spoken in the "Route started. …" intro).
    private static func directions(to item: MKMapItem, name: String, from origin: CLLocationCoordinate2D) async throws -> PlannedRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = item
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        let directions = try await MKDirections(request: request).calculate()
        guard let route = directions.routes.first else { throw RouteError.noRoute }

        let steps = route.steps.map { step in
            RouteStepInput(points: step.polyline.coordinates.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) },
                           instructions: step.instructions)
        }
        let waypoints = RouteBuilder.waypoints(from: steps, destinationName: name)
        guard !waypoints.isEmpty else { throw RouteError.noRoute }
        return PlannedRoute(route: Route(name: "To \(name)", waypoints: waypoints),
                            placeName: name, walkingMeters: route.distance)
    }

    /// A map item at a bare coordinate (gazetteer entrance or the CIF waypoint): MapKit then
    /// routes to that exact point instead of a building centroid it picked itself.
    private static func mapItem(at c: Coordinate) -> MKMapItem {
        MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude), address: nil)
    }
}

/// Route-building failures. `errorDescription` is shown as `AppModel.routeError` and spoken
/// ("Could not build a route. <description>" from `buildRoute`; "Route file missing." for
/// `.missingBundledRoute` from `startDemoRoute` / `navigateToCIFFromHere`).
enum RouteError: LocalizedError {
    /// `route_isr_cif.json` is not in the app bundle.
    case missingBundledRoute
    /// Nothing within walking range matched the typed / spoken text (carried for the message).
    case destinationNotFound(String)
    /// MKDirections returned no walking route.
    case noRoute

    /// User-facing message (no trailing period: AppModel adds context around it).
    var errorDescription: String? {
        switch self {
        case .missingBundledRoute: return "The bundled route file is missing"
        case .destinationNotFound(let d): return "Could not find \"\(d)\" within walking distance"
        case .noRoute: return "No walking route found"
        }
    }
}

/// File-private MapKit helper for `RouteSource.directions`.
private extension MKPolyline {
    /// All vertices of the polyline, in order (copied out with `getCoordinates`). An empty
    /// polyline gives `[]`, which `RouteBuilder` drops as an unusable step.
    var coordinates: [CLLocationCoordinate2D] {
        var out = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&out, range: NSRange(location: 0, length: pointCount))
        return out
    }
}
