import Foundation

/// Minimal client for a local Ollama server.
final class LLMClient {
    private var settings: AppSettings { SettingsStore.shared.s }

    struct Message { var role: String; var content: String }

    private var lastUse = Date.distantPast
    private static let keepAlive = "12h"

    func chat(_ messages: [Message], timeout: TimeInterval = 30, maxTokens: Int? = nil,
              completion: @escaping (Result<String, Error>) -> Void) {
        lastUse = Date()
        guard let url = URL(string: settings.ollamaURL)?.appendingPathComponent("api/chat") else {
            completion(.failure(NSError(domain: "LocalFlow", code: 3, userInfo: [NSLocalizedDescriptionKey: "Ollama URL"])))
            return
        }
        var options: [String: Any] = ["temperature": 0.1, "num_ctx": 4096]
        if let maxTokens { options["num_predict"] = maxTokens }
        let payload: [String: Any] = [
            "model": settings.ollamaModel,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": false,
            "keep_alive": LLMClient.keepAlive,
            "options": options,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { data, _, error in
            let result: Result<String, Error>
            if let error {
                result = .failure(error)
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let message = json["message"] as? [String: Any],
                      let content = message["content"] as? String {
                result = .success(LLMClient.stripWrapping(content))
            } else {
                let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                result = .failure(NSError(domain: "LocalFlow", code: 4, userInfo: [NSLocalizedDescriptionKey: "Ollama: \(raw.prefix(200))"]))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Loads the model into memory so the first dictation is fast.
    func warmup() {
        chat([Message(role: "user", content: "ok")], timeout: 120) { _ in }
    }

    /// Reloads the model in the background if it may have been evicted, so loading overlaps with speaking.
    func ensureLoaded() {
        guard Date().timeIntervalSince(lastUse) > 20 * 60,
              let url = URL(string: settings.ollamaURL)?.appendingPathComponent("api/chat") else { return }
        lastUse = Date()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": settings.ollamaModel, "messages": [], "keep_alive": LLMClient.keepAlive,
        ] as [String: Any])
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    func availableModels(completion: @escaping ([String]?) -> Void) {
        guard let url = URL(string: settings.ollamaURL)?.appendingPathComponent("api/tags") else { return completion(nil) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let names = data
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["models"] as? [[String: Any]] }?
                .compactMap { $0["name"] as? String }
            DispatchQueue.main.async { completion(names) }
        }.resume()
    }

    /// Removes reasoning blocks, code fences and wrapping tags a model may add.
    static func stripWrapping(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"</?(transcript|text|output|result|selected_text)>"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: #"^```[a-zA-Z]*\n?|\n?```$"#, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
