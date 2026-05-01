import Foundation

enum HarnessSettingsStore {
    private static let serverURLKey = "cmuxHarnessServerURL"
    private static let tailscaleHostKey = "cmuxHarnessTailscaleHost"
    private static let lastSelectedWorkspaceIDKey = "cmuxHarnessLastSelectedWorkspaceID"
    private static let detailDraftsKey = "cmuxHarnessDetailDrafts"

    static var serverURL: String? {
        get {
            guard let value = UserDefaults.standard.string(forKey: serverURLKey) else {
                return nil
            }
            let normalized = HarnessAPI.normalizedBaseURL(value)
            return normalized.isEmpty ? nil : normalized
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: serverURLKey)
                return
            }
            let normalized = HarnessAPI.normalizedBaseURL(newValue)
            if normalized.isEmpty {
                UserDefaults.standard.removeObject(forKey: serverURLKey)
            } else {
                UserDefaults.standard.set(normalized, forKey: serverURLKey)
            }
        }
    }

    static var tailscaleHost: String {
        get {
            UserDefaults.standard.string(forKey: tailscaleHostKey) ?? ""
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                UserDefaults.standard.removeObject(forKey: tailscaleHostKey)
            } else {
                UserDefaults.standard.set(value, forKey: tailscaleHostKey)
            }
        }
    }

    static var lastSelectedWorkspaceID: String? {
        get {
            guard let value = UserDefaults.standard.string(forKey: lastSelectedWorkspaceIDKey),
                  !value.isEmpty else {
                return nil
            }
            return value
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: lastSelectedWorkspaceIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastSelectedWorkspaceIDKey)
            }
        }
    }

    static var detailDrafts: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: detailDraftsKey),
                  let drafts = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return drafts
        }
        set {
            let drafts = newValue.filter { !$0.value.isEmpty }
            guard !drafts.isEmpty else {
                UserDefaults.standard.removeObject(forKey: detailDraftsKey)
                return
            }
            guard let data = try? JSONEncoder().encode(drafts) else { return }
            UserDefaults.standard.set(data, forKey: detailDraftsKey)
        }
    }

    static func detailDraft(for workspaceID: String?) -> String {
        guard let workspaceID else { return "" }
        return detailDrafts[workspaceID] ?? ""
    }
}
