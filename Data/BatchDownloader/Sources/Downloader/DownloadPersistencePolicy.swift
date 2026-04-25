//
//  DownloadPersistencePolicy.swift
//
//
//  Created on 2026-04-25.
//
//  A host-supplied hook that decides, per batch, whether the BatchDownloader
//  should persist the bytes it downloads.
//
//  When `shouldPersist(_:)` returns `false` for a batch:
//   * No row is written to `downloads.db`.
//   * The temporary file produced by `URLSession` is discarded after the
//     download completes (no move to the request's destination).
//   * No retrieval rows are written/updated for the batch's lifetime.
//
//  Bytes still flow through the URLSession — the host can stream them
//  through a separate code path (e.g. `AVPlayer` reading the same URL)
//  if it needs in-flight playback. The contract here is purely about
//  on-disk persistence.
//
//  The policy is consulted **per `DownloadBatchRequest`**, so a host can
//  apply different rules to different asset types based on the request URLs
//  or destination paths (e.g. gate audio downloads on a subscription while
//  always persisting translation databases).
//

import Foundation

public protocol DownloadPersistencePolicy: Sendable {
    /// Called once when a batch is submitted to `DownloadManager.download(_:)`.
    /// Return `true` to keep the existing persistence behaviour, `false` to
    /// run the batch ephemerally (no SQLite row, no file move on completion).
    func shouldPersist(_ batch: DownloadBatchRequest) -> Bool
}

/// Back-compat default: every batch persists.
/// This is what every existing call site gets when no policy is supplied,
/// which keeps the original public `init` semantics unchanged.
public struct AlwaysPersistDownloadPolicy: DownloadPersistencePolicy {
    public init() {}
    public func shouldPersist(_ batch: DownloadBatchRequest) -> Bool { true }
}
