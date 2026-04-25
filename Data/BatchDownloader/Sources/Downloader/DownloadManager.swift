//
//  DownloadManager.swift
//  Quran
//
//  Created by Mohamed Afifi on 5/14/16.
//
//  Quran for iOS is a Quran reading application for iOS.
//  Copyright (C) 2017  Quran.com
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//

import Foundation
import NetworkSupport
import SystemDependencies
import VLogging

public final class DownloadManager: Sendable {
    typealias SessionFactory = @Sendable (NetworkSessionDelegate, OperationQueue) -> NetworkSession

    // MARK: Lifecycle

    public convenience init(
        maxSimultaneousDownloads: Int,
        configuration: URLSessionConfiguration,
        downloadsURL: URL
    ) {
        self.init(
            maxSimultaneousDownloads: maxSimultaneousDownloads,
            configuration: configuration,
            downloadsURL: downloadsURL,
            policy: AlwaysPersistDownloadPolicy()
        )
    }

    /// Convenience init that lets the host inject a `DownloadPersistencePolicy`
    /// so individual batches can opt out of on-disk persistence (for example,
    /// to gate offline audio behind a paid subscription while still letting
    /// translation databases persist as usual).
    public convenience init(
        maxSimultaneousDownloads: Int,
        configuration: URLSessionConfiguration,
        downloadsURL: URL,
        policy: DownloadPersistencePolicy
    ) {
        self.init(
            maxSimultaneousDownloads: maxSimultaneousDownloads,
            sessionFactory: {
                URLSession(
                    configuration: configuration,
                    delegate: NetworkSessionToURLSessionDelegate(networkSessionDelegate: $0),
                    delegateQueue: $1
                )
            },
            persistence: GRDBDownloadsPersistence(fileURL: downloadsURL),
            policy: policy
        )
    }

    init(
        maxSimultaneousDownloads: Int,
        sessionFactory: @escaping SessionFactory,
        persistence: DownloadsPersistence,
        fileManager: FileSystem = DefaultFileSystem(),
        policy: DownloadPersistencePolicy = AlwaysPersistDownloadPolicy()
    ) {
        let dataController = DownloadBatchDataController(
            maxSimultaneousDownloads: maxSimultaneousDownloads,
            persistence: persistence,
            policy: policy
        )
        self.dataController = dataController
        self.sessionFactory = sessionFactory
        handler = DownloadSessionDelegate(dataController: dataController, fileManager: fileManager)
    }

    // MARK: Public

    public func start() async {
        logger.info("Starting download manager")
        let session = createSession()
        await dataController.start(with: session)
        logger.info("Download manager started")
    }

    @MainActor
    public func setBackgroundSessionCompletion(_ backgroundSessionCompletion: @MainActor @escaping () -> Void) {
        handler.setBackgroundSessionCompletion(backgroundSessionCompletion)
    }

    public func getOnGoingDownloads() async -> [DownloadBatchResponse] {
        logger.info("getOnGoingDownloads requested")
        let downloads = await dataController.getOnGoingDownloads()
        logger.debug("Found \(downloads.count) ongoing downloads")
        return downloads
    }

    public func download(_ batch: DownloadBatchRequest) async throws -> DownloadBatchResponse {
        logger.debug("Requested to download \(batch.requests.map(\.url.absoluteString))")
        let result = try await dataController.download(batch)
        return result
    }

    /// Wipes every persisted batch and the on-disk files those batches
    /// produced. Intended for host-side flows that need to drop offline
    /// assets when an entitlement (e.g. a paid subscription) is lost.
    ///
    /// Files at request destinations are read out of the persistence layer
    /// before the SQLite rows are deleted, so paths the package owns are
    /// removed without the host having to know them.
    public func purgePersistedDownloads() async throws {
        // Read paths first so that even if file deletion partially fails we
        // still wipe the SQLite rows below — leaving orphaned files is far
        // less damaging than leaving stale rows pointing to deleted files.
        let paths = try await dataController.persistedDownloadPaths()
        let fileSystem: FileSystem = DefaultFileSystem()
        for path in paths {
            try? fileSystem.removeItem(at: path)
        }
        try await dataController.purgePersistedDownloads()
    }

    public func cancel(downloads: [DownloadBatchResponse]) async {
        guard !downloads.isEmpty else {
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for download in downloads {
                group.addTask {
                    await download.cancel()
                    await Self.waitForCompletion(of: download)
                }
            }
        }

        let batchIds = Set(downloads.map(\.batchId))
        await dataController.waitUntilBatchesRemoved(batchIds: batchIds)
    }

    // MARK: Private

    private let sessionFactory: SessionFactory
    private nonisolated(unsafe) var session: NetworkSession?
    private let handler: DownloadSessionDelegate
    private let dataController: DownloadBatchDataController

    private static func waitForCompletion(of download: DownloadBatchResponse) async {
        do {
            for try await _ in download.progress { }
        } catch { }
    }

    private func createSession() -> NetworkSession {
        let operationQueue = OperationQueue()
        operationQueue.name = "com.quran.downloads"
        operationQueue.maxConcurrentOperationCount = 1

        let dispatchQueue = DispatchQueue(label: "com.quran.downloads.dispatch")
        operationQueue.underlyingQueue = dispatchQueue

        let session = sessionFactory(handler, operationQueue)
        self.session = session

        return session
    }
}
