// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 rrzip contributors
//
import Foundation
import Observation

/// Tracks archive sessions without owning AppKit windows. A session's root is reserved while it loads.
@MainActor
@Observable
final class WindowSessionRegistry: TerminationHost {
    enum Route: Equatable {
        case focus(UUID)
        case reuse(UUID)
        case newWindow
    }

    let stash = StashStore()
    private var sessions: [UUID: ArchiveModel] = [:]
    private var focusOrder: [UUID] = []
    private var closing: [UUID: ArchiveModel] = [:]
    private var isTerminating = false
    private var finderJob: TaskJob?
    @ObservationIgnored var onWorkDrained: (() -> Void)?
    @ObservationIgnored var cancelFinderTask: (() -> Void)?

    var activeModel: ArchiveModel? { focusOrder.first.flatMap { sessions[$0] } }
    func model(_ id: UUID) -> ArchiveModel? { sessions[id] }

    func makeModel() -> ArchiveModel {
        ArchiveModel(stashStore: stash)
    }

    func register(_ model: ArchiveModel) {
        let id = model.sessionID
        guard sessions[id] == nil else { return }
        sessions[id] = model
        focusOrder.append(id)
        model.onWorkDrained = { [weak self] in self?.onWorkDrained?() }
        model.passwordFromOtherWindows = { [weak self] archive in
            self?.sessions.values.lazy.compactMap { $0.passwords[archive.path] }.first
        }
        if isTerminating { model.beginTerminationWait() }
        if activeModel === model { model.finderJob = finderJob }
    }

    func activate(_ id: UUID) {
        guard let model = sessions[id], activeModel !== model else { return }
        activeModel?.finderJob = nil
        focusOrder.removeAll { $0 == id }
        focusOrder.insert(id, at: 0)
        model.finderJob = finderJob
    }

    func unregister(_ id: UUID) {
        guard let model = sessions.removeValue(forKey: id) else { return }
        focusOrder.removeAll { $0 == id }
        model.finderJob = nil
        activeModel?.finderJob = finderJob
        closing[id] = model
        model.onClosedJobDrained = { [weak self] in self?.closing.removeValue(forKey: id) }
        model.closeWindow()
        if model.pendingJobCount == 0 { closing[id] = nil }
        onWorkDrained?()
    }

    func route(_ archive: URL, preferred: UUID? = nil, newlyCreated: Set<UUID> = []) -> Route {
        let key = ScratchUsage.canonical(archive.path)
        if let match = focusOrder.first(where: {
            sessions[$0]?.rootArchive.map { ScratchUsage.canonical($0.path) } == key
        }) {
            return .focus(match)
        }
        if let preferred, sessions[preferred]?.canReuseWindow == true { return .reuse(preferred) }
        let idle = focusOrder.filter { sessions[$0]?.canReuseWindow == true }
        if let existing = idle.first(where: { !newlyCreated.contains($0) }) { return .reuse(existing) }
        if let first = idle.first { return .reuse(first) }
        return .newWindow
    }

    func showFinderJob(_ job: TaskJob?) {
        finderJob = job
        activeModel?.finderJob = job
    }

    private var allModels: [ArchiveModel] { Array(sessions.values) + Array(closing.values) }
    var pendingJobCount: Int { allModels.reduce(0) { $0 + $1.pendingJobCount } }
    var isWritingScratch: Bool { ScratchUsage.shared.isWorking }
    var formalWrites: FormalWriteSummary { FormalWriteLedger.shared.summary() }

    func beginTerminationWait() {
        isTerminating = true
        for model in sessions.values { model.beginTerminationWait() }
    }

    func cancelWorkForTermination() {
        isTerminating = true
        for model in allModels { model.cancelWindowWork() }
        cancelFinderTask?()
    }

    func resumeAfterAbortedTermination() {
        isTerminating = false
        for model in sessions.values { model.resumeAfterAbortedTermination() }
    }
}
