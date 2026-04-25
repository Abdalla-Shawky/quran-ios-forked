//
//  DownloadBatchDataController.swift
//  Quran
//
//  Created by Mohamed Afifi on 4/29/17.
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

import Crashing
import Foundation
import NetworkSupport
import Utilities
import VLogging

func describe(_ task: NetworkSessionTask) -> String {
    "\(type(of: task))(\(task.taskIdentifier): " + ((task.originalRequest?.url?.absoluteString ?? task.currentRequest?.url?.absoluteString) ?? "") + ")"
}

struct SingleTaskResponse {
    let request: DownloadRequest
    let response: DownloadBatchResponse
    /// `false` when the batch was submitted under a policy that opted out
    /// of persistence — the session delegate uses this to discard the temp
    /// file rather than moving it to the request's destination.
    let isPersistent: Bool
}

actor DownloadBatchDataController {
    // MARK: Lifecycle

    init(
        maxSimultaneousDownloads: Int,
        persistence: DownloadsPersistence,
        policy: DownloadPersistencePolicy = AlwaysPersistDownloadPolicy()
    ) {
        self.maxSimultaneousDownloads = maxSimultaneousDownloads
        self.persistence = persistence
        self.policy = policy
    }

    // MARK: Internal

    func start(with session: NetworkSession) async {
        await bootstrapPersistence()

        self.session = session
        let (_, _, downloadTasks) = await session.tasks()
        for batch in batches {
            await batch.associateTasks(downloadTasks)
        }

        initialRunningTasks.initialize()

        // start pending tasks if needed
        await startPendingTasksIfNeeded()
    }

    func getOnGoingDownloads() async -> [DownloadBatchResponse] {
        await initialRunningTasks.awaitInitialization()
        return Array(batches)
    }

    func downloadRequestResponse(for task: NetworkSessionTask) async -> SingleTaskResponse? {
        for batch in batches {
            if let request = await batch.downloadRequest(for: task) {
                let isPersistent = !ephemeralBatchIds.contains(batch.batchId)
                return SingleTaskResponse(request: request, response: batch, isPersistent: isPersistent)
            }
        }
        return nil
    }

    func download(_ batchRequest: DownloadBatchRequest) async throws -> DownloadBatchResponse {
        logger.info("Batching \(batchRequest.requests.count) to download.")

        let batch: DownloadBatch
        if policy.shouldPersist(batchRequest) {
            // save to persistence
            batch = try await persistence.insert(batch: batchRequest)
            logger.info("Batch assigned Id = \(batch.id).")
        } else {
            // ephemeral: synthesize an in-memory batch with a guaranteed-unique
            // negative id (SQLite auto-increment never produces negatives, so
            // there is no collision with persisted batches).
            let id = nextEphemeralBatchId()
            let downloads = batchRequest.requests.map { request in
                Download(taskId: nil, request: request, status: .downloading, batchId: id)
            }
            batch = DownloadBatch(id: id, downloads: downloads)
            ephemeralBatchIds.insert(id)
            logger.info("Batch assigned ephemeral Id = \(batch.id).")
        }

        // create the response
        let response = await createResponse(forBatch: batch)

        // start pending downloads if needed
        await startPendingTasksIfNeeded()

        return response
    }

    /// Wipes every persisted batch and download row through the persistence
    /// layer. Surfaced via `DownloadManager.purgePersistedDownloads()` for
    /// host-side "subscription expired, drop offline assets" flows.
    func purgePersistedDownloads() async throws {
        try await persistence.deleteAll()
    }

    /// Snapshot of every destination + resume path currently persisted.
    /// The host removes these files from disk before wiping the SQLite rows.
    func persistedDownloadPaths() async throws -> [RelativeFilePath] {
        let batches = try await persistence.retrieveAll()
        var paths: [RelativeFilePath] = []
        for batch in batches {
            for download in batch.downloads {
                paths.append(download.request.destination)
                paths.append(download.request.resumePath)
            }
        }
        return paths
    }

    func downloadCompleted(_ response: SingleTaskResponse) async {
        await response.response.complete(response.request, result: .success(()))
        await updateDownloadPersistence(response)

        // start pending tasks if needed
        await startPendingTasksIfNeeded()
    }

    func downloadFailed(_ response: SingleTaskResponse, with error: Error) async {
        await response.response.complete(response.request, result: .failure(error))

        // start pending tasks if needed
        await startPendingTasksIfNeeded()
    }

    func waitUntilBatchesRemoved(batchIds: Set<Int64>) async {
        guard !batchIds.isEmpty else {
            return
        }

        while batches.contains(where: { batchIds.contains($0.batchId) }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: Private

    private let maxSimultaneousDownloads: Int
    private let persistence: DownloadsPersistence
    private let policy: DownloadPersistencePolicy
    private weak var session: NetworkSession?

    private var batches: Set<DownloadBatchResponse> = []

    /// Tracks batches that bypassed `persistence.insert` because the policy
    /// denied persistence. Update / delete persistence calls are skipped for
    /// these ids; the session delegate also uses this set (via
    /// `SingleTaskResponse.isPersistent`) to discard temp files.
    private var ephemeralBatchIds: Set<Int64> = []

    /// Monotonic source of negative ids for ephemeral batches. Decrements on
    /// every read; SQLite auto-increment never produces negatives so there
    /// is no risk of collision with persisted batches.
    private var nextEphemeralId: Int64 = -1

    private func nextEphemeralBatchId() -> Int64 {
        defer { nextEphemeralId -= 1 }
        return nextEphemeralId
    }

    private var initialRunningTasks = AsyncInitializer()

    private var runningTasks: Int {
        get async {
            var count = 0
            for batch in batches {
                count += await batch.runningTasks
            }
            return count
        }
    }

    private static func completeBatch(_ response: DownloadBatchResponse) async {
        do {
            // Wait until sequence completes
            for try await _ in response.progress { }
        } catch {
            logger.error("Batch \(response.batchId) failed to download with error: \(error)")
        }
    }

    private func bootstrapPersistence() async {
        do {
            try await attempt(times: 3) {
                try await loadBatchesFromPersistence()
            }
        } catch {
            crasher.recordError(error, reason: "Failed to retrieve initial download batches from persistence.")
        }
    }

    private func loadBatchesFromPersistence() async throws {
        let batches = try await persistence.retrieveAll()
        logger.info("Loading \(batches.count) from persistence")
        for batch in batches {
            _ = await createResponse(forBatch: batch)
        }
    }

    private func createResponse(forBatch batch: DownloadBatch) async -> DownloadBatchResponse {
        let response = await DownloadBatchResponse(batch: batch)
        batches.insert(response)

        Task { [weak self] in
            await Self.completeBatch(response)
            guard let self else {
                return
            }
            await cleanUpForCompletedBatch(response)
        }

        return response
    }

    private func cleanUpForCompletedBatch(_ response: DownloadBatchResponse) async {
        // delete the completed response
        batches.remove(response)
        if ephemeralBatchIds.remove(response.batchId) == nil {
            // Persisted batches need their SQLite row removed; ephemeral
            // batches were never inserted in the first place.
            await run("DeleteBatch") { try await $0.delete(batchIds: [response.batchId]) }
        }

        // Start pending tasks
        await startPendingTasksIfNeeded()
    }

    private func startPendingTasksIfNeeded() async {
        if !initialRunningTasks.initialized {
            logger.warning("startPendingTasksIfNeeded not initialized")
            return
        }

        // if we have a session
        guard let session else {
            logger.warning("startPendingTasksIfNeeded no session")
            return
        }
        // and there are empty slots to use for downloading
        let runningTasks = await runningTasks
        guard runningTasks < maxSimultaneousDownloads else {
            logger.info("startPendingTasksIfNeeded no empty slots for download")
            return
        }
        // and there are things to download
        guard !batches.isEmpty else {
            logger.info("startPendingTasksIfNeeded no batches to download")
            return
        }

        await startDownloadTasks(
            session: session,
            maxNumberOfDownloads: maxSimultaneousDownloads - runningTasks
        )
    }

    private func startDownloadTasks(session: NetworkSession, maxNumberOfDownloads: Int) async {
        // Sort the batches by id.
        let batches = batches.sorted { $0.batchId < $1.batchId }

        var downloadTasks: [(task: NetworkSessionDownloadTask, response: SingleTaskResponse)] = []
        for batch in batches {
            while downloadTasks.count < maxNumberOfDownloads { // Max download channels?
                guard let (request, task) = await batch.startDownloadIfNeeded(session: session) else {
                    break
                }

                let isPersistent = !ephemeralBatchIds.contains(batch.batchId)
                let response = SingleTaskResponse(request: request, response: batch, isPersistent: isPersistent)
                await updateDownloadPersistence(response)
                downloadTasks.append((task, response))
            }
        }

        logger.info("startDownloadTasks \(downloadTasks.count) to download on empty channels.")

        // start the tasks
        for download in downloadTasks {
            download.task.resume()
        }
    }

    private func updateDownloadPersistence(_ response: SingleTaskResponse) async {
        // Ephemeral batches have no SQLite rows to update.
        guard response.isPersistent else { return }
        await run("UpdateDownload") {
            try await $0.update(downloads: [await response.response.download(of: response.request)])
        }
    }

    private func run(_ operation: String, _ body: (DownloadsPersistence) async throws -> Void) async {
        do {
            try await body(persistence)
        } catch {
            crasher.recordError(error, reason: "DownloadPersistence." + operation)
        }
    }
}
