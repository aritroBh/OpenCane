//
//  PostStore.swift
//  CaneKit
//
//  The walker's posts: every place named by voice ("set a post called Townsend Door") or by the
//  assistant's `drop_marker` tool is kept in Documents/posts/posts.json so it survives a relaunch.
//  Before this file the markers lived only in `ConversationCoordinator.markers` and died with the
//  process. The JSON is the plain `Codable` form of `[WalkMarker]` (CaneKitLogic) — no new schema
//  type, because nothing in it is a decision with a number.
//
//  Owner: `ConversationCoordinator.store`; `append(_:)` from `ConversationCoordinator.dropPost(name:)`.
//  Mirrors `HazardLog`: Documents subfolder, whole-file atomic rewrite on each drop (a walk drops
//  a handful of posts, not thousands), `lastError` instead of a throw. Loaded once in `init`; a
//  missing or unreadable file starts empty and is reported, never fatal.
//
//  Readers: `ConversationCoordinator.markers` (the posts sent to the cloud model as
//  `savedMarkers`, and the "Marker N" default name). No view shows the posts or shares the file
//  yet; the JSON is reachable through Files → On My iPhone → OpenCane (`UIFileSharingEnabled`).
//  Nothing ever deletes a post.
//
//  Threading / isolation: `@MainActor @Observable`; file writes are small and infrequent, so they
//  run synchronously on main.
//  Tests: ⚠ `ConversationLogicTests.walkMarkerJSONRoundTrip` pins the on-disk shape (the `Codable`
//  form of `WalkMarker`: `id`, `name`, `coordinate`, `timestamp`). The store itself has no unit
//  test — say "set a post called curb", relaunch, and check the file on a device.
//

import CaneKitLogic
import Foundation
import Observation

/// Durable list of the walker's named posts (`WalkMarker`s), mirrored to Documents/posts/posts.json.
/// One instance, owned by `ConversationCoordinator`.
@MainActor
@Observable
final class PostStore {

    /// Posts across every launch, oldest first (append order). A post whose save failed is still
    /// here for this session only.
    private(set) var markers: [WalkMarker] = []
    /// Last load / save failure, one line prefixed "Posts: "; nil after a successful save. No view
    /// shows it today: `ConversationCoordinator.dropPost` copies it into the `marker_dropped`
    /// trip-log record's `error` field. A load failure stays set until the next successful save.
    private(set) var lastError: String?

    /// Documents/posts/ (created on the first save).
    @ObservationIgnored private let directory = URL.documentsDirectory.appendingPathComponent("posts", isDirectory: true)
    /// The JSON file, Documents/posts/posts.json (reachable in the Files app; no share sheet yet).
    var fileURL: URL { directory.appendingPathComponent("posts.json") }

    /// Loads posts.json synchronously on the main actor (a handful of posts). A missing file starts
    /// empty silently; an unreadable one starts empty with `lastError` set — and ⚠ the next
    /// `append` then rewrites the file with only this session's posts, so the unreadable file's
    /// contents are overwritten, not merged.
    init() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            markers = try JSONDecoder().decode([WalkMarker].self, from: Data(contentsOf: fileURL))
        } catch {
            lastError = "Posts: \(error.localizedDescription)"
        }
    }

    /// Append one post and rewrite the file atomically. The marker is kept in memory even when
    /// the write fails, so the current session still knows it. Returns the durable-write result so
    /// the voice confirmation never claims persistence that did not happen.
    /// - Parameter marker: name, coordinate ((0, 0) when there was no fix) and time since 1970.
    /// - Returns: true when posts.json was written. Caller: `ConversationCoordinator.dropPost(name:)`.
    @discardableResult
    func append(_ marker: WalkMarker) -> Bool {
        markers.append(marker)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(markers).write(to: fileURL, options: .atomic)
            lastError = nil
            return true
        } catch {
            lastError = "Posts: \(error.localizedDescription)"
            return false
        }
    }
}
