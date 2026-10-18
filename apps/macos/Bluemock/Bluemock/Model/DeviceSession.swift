import Foundation
import Observation

@MainActor @Observable
final class DeviceSession {
    enum Feedback: Equatable {
        case error(String)
        case success
    }

    private(set) var formValues: [String: [String: JSONValue]] = [:]
    private(set) var feedback: [String: Feedback] = [:]
    private(set) var pendingCommands: [UUID: String] = [:]
    private(set) var eventLogClearSequence = 0
    private var eventSequence = 0
    private var pendingCommandByWireAction: [String: UUID] = [:]
    private var feedbackTokens: [String: UUID] = [:]

    func ensureValues(actionID: String, params: [(String, JSONValue?)]) {
        let names = Set(params.map { $0.0 })
        var values = (formValues[actionID] ?? [:]).filter { names.contains($0.key) }
        for (name, defaultValue) in params where values[name] == nil {
            if let defaultValue { values[name] = defaultValue }
        }
        formValues[actionID] = values
    }

    func reconcileActions(_ actions: [JSONValue]) {
        let ids = Set(actions.compactMap { $0.objectValue?["id"]?.stringValue })
        formValues = formValues.filter { ids.contains($0.key) }
        feedback = feedback.filter { ids.contains($0.key) }
        feedbackTokens = feedbackTokens.filter { ids.contains($0.key) }
        for action in actions {
            guard let fields = action.objectValue, let id = fields["id"]?.stringValue else { continue }
            let params = (fields["params"]?.arrayValue ?? []).compactMap { value -> (String, JSONValue?)? in
                guard let data = value.objectValue, let name = data["name"]?.stringValue else { return nil }
                return (name, data["default"])
            }
            ensureValues(actionID: id, params: params)
        }
    }

    func value(actionID: String, name: String) -> JSONValue? { formValues[actionID]?[name] }

    func setValue(_ value: JSONValue, actionID: String, name: String) {
        formValues[actionID, default: [:]][name] = value
    }

    func recordEvent(_ event: IPCEvent) -> IPCEvent {
        eventSequence += 1
        var copy = event
        copy.sequence = eventSequence
        return copy
    }

    func clearEventLog() { eventLogClearSequence = eventSequence }

    func isPending(_ actionID: String) -> Bool { pendingCommandByWireAction[actionID] != nil }

    // IPC v1 uses the action id itself as its reply_to correlation value.
    // Keep a unique local command token while mapping protocol replies to the action.
    @discardableResult
    func beginAction(_ actionID: String) -> UUID? {
        guard pendingCommandByWireAction[actionID] == nil else { return nil }
        let commandID = UUID()
        pendingCommands[commandID] = actionID
        pendingCommandByWireAction[actionID] = commandID
        feedback[actionID] = nil
        return commandID
    }

    func receiveError(replyTo: String, message: String) {
        guard finishAction(replyTo) else { return }
        show(.error(message), actionID: replyTo, duration: 4)
    }

    func receiveTransmission(actionID: String) {
        guard finishAction(actionID) else { return }
        show(.success, actionID: actionID, duration: 1.5)
    }

    func expire(commandID: UUID) {
        guard let actionID = pendingCommands[commandID],
              pendingCommandByWireAction[actionID] == commandID else { return }
        pendingCommands.removeValue(forKey: commandID)
        pendingCommandByWireAction.removeValue(forKey: actionID)
    }

    func clearPendingCommands() {
        pendingCommands.removeAll()
        pendingCommandByWireAction.removeAll()
    }

    private func finishAction(_ actionID: String) -> Bool {
        guard let commandID = pendingCommandByWireAction.removeValue(forKey: actionID) else { return false }
        pendingCommands.removeValue(forKey: commandID)
        return true
    }

    private func show(_ result: Feedback, actionID: String, duration: Double) {
        let token = UUID()
        feedbackTokens[actionID] = token
        feedback[actionID] = result
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard self?.feedbackTokens[actionID] == token else { return }
            self?.feedback[actionID] = nil
            self?.feedbackTokens[actionID] = nil
        }
    }
}
