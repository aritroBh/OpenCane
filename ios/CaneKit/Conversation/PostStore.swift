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
//  Threading / isolation: `@MainActor @Observable`; file writes are small and infrequent.
//  ⚠ `ConversationLogicTests.walkMarkerJSONRoundTrip` pins the on-disk shape.
//

import CaneKitLogic
import Foundation
import Observation

@MainActor
@Observable
final class PostStore {

    /// Posts across every launch, oldest first.
    private(set) var markers: [WalkMarker] = []
    /// Last load / save failure, one line, for the Mount / status card; nil when healthy.
    private(set) var lastError: String?

    @ObservationIgnored private let directory = URL.documentsDirectory.appendingPathComponent("posts", isDirectory: true)
    /// The JSON file (for a share sheet or the Files app).
    var fileURL: URL { directory.appendingPathComponent("posts.json") }

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
