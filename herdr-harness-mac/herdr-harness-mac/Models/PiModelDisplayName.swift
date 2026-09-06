import Foundation

enum PiModelDisplayName {
    static func short(fullID: String) -> String {
        guard let separator = fullID.firstIndex(of: "/") else {
            return short(provider: "", modelID: fullID, name: nil)
        }
        return short(
            provider: String(fullID[..<separator]),
            modelID: String(fullID[fullID.index(after: separator)...]),
            name: nil
        )
    }

    static func short(provider: String, modelID: String, name: String?) -> String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalID = modelID.split(separator: "/").last.map(String.init) ?? modelID
        let knownPrefixes = ["gpt", "claude", "gemini", "qwen", "deepseek", "glm", "llama", "mistral", "mixtral", "phi", "o1", "o3", "o4"]
        let usesCanonicalID = knownPrefixes.contains { canonicalID.lowercased().hasPrefix($0) }
        // Provider display labels frequently append dates, capabilities, or
        // marketing descriptions. A recognized model ID is the stable name.
        let base = usesCanonicalID ? canonicalID : trimmedName.flatMap { $0.isEmpty ? nil : $0 } ?? canonicalID
        var tokens = base.split(whereSeparator: { character in
            character == "-" || character == "_" || character.isWhitespace
        }).map(String.init)

        guard !tokens.isEmpty else { return modelID }

        if tokens.count >= 3,
           tokens[tokens.count - 3].count == 4,
           tokens.suffix(3).allSatisfy({ isDigits($0) }),
           Int(tokens[tokens.count - 3]).map({ (2000...2099).contains($0) }) == true,
           tokens[tokens.count - 2].count == 2, tokens[tokens.count - 1].count == 2 {
            tokens.removeLast(3)
        } else if let last = tokens.last, isDigits(last), (last.count == 4 || (6...8).contains(last.count)) {
            tokens.removeLast()
        }

        let providerSuffix = provider.split(separator: "-").last.map(String.init) ?? provider
        if let last = tokens.last, last.caseInsensitiveCompare(providerSuffix) == .orderedSame {
            tokens.removeLast()
        }

        let quantizationTokens: Set<String> = [
            "nvfp4", "fp8", "fp16", "bf16", "int4", "int8", "awq", "gptq", "gguf", "mtp", "q4", "q8"
        ]
        tokens.removeAll { quantizationTokens.contains($0.lowercased()) }
        guard !tokens.isEmpty else { return modelID }

        let collapsedTokens = collapseDigitRuns(tokens)
        let result = collapsedTokens.enumerated().map { index, token in
            let separator: String
            if index == 0 {
                separator = ""
            } else if index == 1, isVersionToken(token) {
                separator = "-"
            } else {
                separator = " "
            }
            return separator + capitalize(token)
        }.joined()

        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedResult.isEmpty ? modelID : trimmedResult
    }

    private static func collapseDigitRuns(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            guard isDigits(tokens[index]) else {
                result.append(tokens[index])
                index += 1
                continue
            }

            let start = index
            while index < tokens.count, isDigits(tokens[index]) {
                index += 1
            }
            let run = Array(tokens[start..<index])
            result.append(run.count >= 2 ? run.joined(separator: ".") : run[0])
        }
        return result
    }

    private static func capitalize(_ token: String) -> String {
        if isBillionToken(token) {
            return String(token.dropLast()) + "B"
        }
        if isVersionToken(token) {
            return token
        }

        let alphabeticPrefix = token.prefix { $0.isLetter }
        guard !alphabeticPrefix.isEmpty else { return token }
        let prefix = String(alphabeticPrefix)
        let remainder = String(token.dropFirst(prefix.count))
        let wordMap: [String: String] = [
            "gpt": "GPT", "glm": "GLM", "llm": "LLM", "qwen": "Qwen", "deepseek": "DeepSeek",
            "claude": "Claude", "sonnet": "Sonnet", "opus": "Opus", "haiku": "Haiku",
            "llama": "Llama", "mistral": "Mistral", "mixtral": "Mixtral", "gemini": "Gemini",
            "phi": "Phi", "codex": "Codex", "mini": "Mini", "flash": "Flash", "turbo": "Turbo",
            "spark": "Spark", "luna": "Luna", "sol": "Sol", "terra": "Terra", "aeon": "Aeon",
            "uncensored": "Uncensored", "instruct": "Instruct", "chat": "Chat", "coder": "Coder",
            "vision": "Vision", "preview": "Preview", "thinking": "Thinking"
        ]
        if let mapped = wordMap[prefix.lowercased()] {
            return mapped + remainder
        }
        return prefix.prefix(1).uppercased() + String(prefix.dropFirst()) + remainder
    }

    private static func isDigits(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isWholeNumber }
    }

    private static func isVersionToken(_ token: String) -> Bool {
        let groups = token.split(separator: ".", omittingEmptySubsequences: false)
        return !groups.isEmpty && groups.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isWholeNumber) }
    }

    private static func isBillionToken(_ token: String) -> Bool {
        guard let last = token.last, last == "b" || last == "B" else { return false }
        return isVersionToken(String(token.dropLast()))
    }
}
