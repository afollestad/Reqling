import Foundation

/// The run's report and each row's status, kept as steps finish.
extension BatchRunner {
    // MARK: - Report

    func record(_ exchange: RequestExchange, request: RequestNodeID, iteration: Int) {
        let result: BatchStepResult = switch exchange.outcomeKind {
        case .succeeded: .passed
        case .failed: .failed
        case .notSent: .skipped
        }
        let message = result == .failed ? exchange.failure?.message ?? exchange.scriptReport?.phases.lazy.compactMap(\.failureSummary).first : nil
        add(BatchRunStep(
            iteration: iteration,
            requestID: request,
            requestName: requestNames[request] ?? "",
            summary: RunSummary(exchange),
            result: result,
            message: message
        ))
    }

    func record(interrupted request: RequestNodeID, iteration: Int, message: String, summary: RunSummary? = nil) {
        add(BatchRunStep(
            iteration: iteration,
            requestID: request,
            requestName: requestNames[request] ?? "",
            summary: summary,
            result: .interrupted,
            message: message
        ))
    }

    func add(_ step: BatchRunStep) {
        run?.add(step)
        refreshStatus(of: step.requestID)
        if step.result == .failed, failures.insert(step.requestID).inserted {
            failureRevision += 1
        }
    }

    func note(_ text: String) {
        if run?.notes.contains(text) == false {
            run?.notes.append(text)
        }
    }

    // MARK: - Row statuses

    func prepareStatuses(for requests: [RequestNodeID], scope: BatchRunScope, in document: ProjectDocument) {
        var cells: [RequestNodeID: BatchStatusCell] = [:]
        var folderMembers: [RequestNodeID: [RequestNodeID]] = [:]
        var requestFolders: [RequestNodeID: [RequestNodeID]] = [:]
        for request in requests {
            cells[request] = BatchStatusCell()
            var folders = document.ancestors(of: request).map(\.id)
            if let scopeFolder = scope.folderID {
                folders = folders.firstIndex(of: scopeFolder).map { Array(folders[$0...]) } ?? []
            }
            requestFolders[request] = folders
            for folder in folders {
                folderMembers[folder, default: []].append(request)
                cells[folder] = cells[folder] ?? BatchStatusCell()
            }
        }
        replaceStatuses(cells: cells, folderMembers: folderMembers, requestFolders: requestFolders)
    }

    func replaceStatuses(
        cells: [RequestNodeID: BatchStatusCell],
        folderMembers: [RequestNodeID: [RequestNodeID]],
        requestFolders: [RequestNodeID: [RequestNodeID]]
    ) {
        self.cells = cells
        self.folderMembers = folderMembers
        self.requestFolders = requestFolders
        if cells.isEmpty {
            failures = []
            failureRevision += 1
        }
        // After the swap, so a badge that re-reads finds the new cells.
        generation += 1
    }

    func refreshStatus(of request: RequestNodeID) {
        guard let run else {
            return
        }
        let tally = run.tallies[request] ?? BatchRequestTally()
        update(request, to: BatchItemStatus(tally, isRunning: run.currentRequest == request))
        for folder in requestFolders[request] ?? [] {
            let members = (folderMembers[folder] ?? []).compactMap { cells[$0]?.status }
            update(folder, to: BatchItemStatus(rollingUp: members))
        }
    }

    func update(_ item: RequestNodeID, to status: BatchItemStatus) {
        if let cell = cells[item], cell.status != status {
            cell.status = status
        }
    }
}
