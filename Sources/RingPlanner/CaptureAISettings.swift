import SwiftUI
import Security
import RingCore

@MainActor final class CaptureAISettings: ObservableObject {
    @Published private(set) var connection: LiteLLMConnection
    @Published private(set) var hasKey: Bool
    private let defaults: UserDefaults
    private let service: String
    init(demo: Bool = false) {
        service = demo ? "com.t1a.the-one-ring-planner.demo.litellm" : "com.t1a.the-one-ring-planner.litellm"
        defaults = demo ? UserDefaults(suiteName: "com.t1a.the-one-ring-planner.demo")! : .standard
        connection = LiteLLMConnection(baseURL: defaults.string(forKey: "capture.litellm.baseURL") ?? "",
                                       model: defaults.string(forKey: "capture.litellm.model") ?? "")
        var result: CFTypeRef?
        hasKey = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: "capture-key", kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result) == errSecSuccess
    }
    func apiKey() async throws -> String {
        let keyService = service
        // Keychain can wait for a security prompt. Keep that wait off the UI thread.
        let task = Task.detached {
            var result: CFTypeRef?
            let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: keyService,
                kSecAttrAccount: "capture-key", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                throw CaptureProcessingError.configuration("Add your LiteLLM key in Settings, or allow access to its macOS Keychain entry.")
            }
            return key
        }
        let key = try await task.value
        try Task.checkCancellation()
        return key
    }
    func save(_ value: LiteLLMConnection, key: String) throws {
        _ = try value.endpoint()
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "capture-key"] as CFDictionary
            let data = Data(key.utf8)
            var status = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "capture-key",
                    kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw CaptureProcessingError.configuration("The key could not be saved in macOS Keychain. Your connection was not changed.") }
            hasKey = true
        }
        defaults.set(value.baseURL, forKey: "capture.litellm.baseURL")
        defaults.set(value.model, forKey: "capture.litellm.model")
        connection = value
    }
    func removeKey() throws {
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "capture-key"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CaptureProcessingError.configuration("Could not remove the Keychain entry.") }
        hasKey = false
    }
}

struct LiteLLMSettingsSection: View {
    @ObservedObject var settings: CaptureAISettings
    @State private var baseURL = ""
    @State private var model = ""
    @State private var key = ""
    @State private var message: String?
    @State private var testing = false
    var body: some View {
        Section("Task cleanup · LiteLLM") {
            TextField("Gateway base URL", text: $baseURL, prompt: Text("https://your-gateway.example/v1"))
                .accessibilityLabel("LiteLLM gateway base URL")
            TextField("Model alias", text: $model, prompt: Text("Your gateway’s model name"))
                .accessibilityLabel("LiteLLM model alias")
            SecureField(settings.hasKey ? "Replace saved key" : "API key", text: $key, prompt: Text(settings.hasKey ? "Saved in macOS Keychain" : "Enter your LiteLLM key"))
                .accessibilityLabel("LiteLLM API key")
            HStack(spacing: 16) {
                Button("Save connection") { save() }.disabled(testing)
                Button(testing ? "Testing…" : "Test connection") {
                    guard save() else { return }
                    testing = true; message = nil
                    Task {
                        do {
                            let apiKey = try await settings.apiKey()
                            _ = try await LiteLLMClient().process("Create a task to review the project plan.", knownTags: [], connection: settings.connection, apiKey: apiKey)
                            message = "Connected. Task cleanup is ready."
                        } catch { message = error.localizedDescription }
                        testing = false
                    }
                }.disabled(testing || (!settings.hasKey && key.isEmpty))
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                if settings.hasKey { Button("Remove key") { do { try settings.removeKey(); message = "Key removed." } catch { message = error.localizedDescription } }.disabled(testing) }
            }
            if let message { Text(message).font(Theme.body(11)).textSelection(.enabled) }
            DetailNote("Processing & saved keys", "Capture text and existing project/product tag names are sent to this gateway for cleanup. Inbox audio stays on your Mac. The Eye offers separate meeting audio processing with confirmation. Keys stay in macOS Keychain, outside task files and Git. Choose Always Allow if macOS asks to remember this app; future updates use the same signing identity. Test connection sends a sample task.")
        }.onAppear { baseURL = settings.connection.baseURL; model = settings.connection.model }
    }
    @discardableResult private func save() -> Bool {
        do {
            try settings.save(LiteLLMConnection(baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), model: model.trimmingCharacters(in: .whitespacesAndNewlines)), key: key)
            key = ""; message = "Connection saved."; return true
        } catch { message = error.localizedDescription; return false }
    }
}
