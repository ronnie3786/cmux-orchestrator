import Foundation

struct GitDiffResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var diff: String?
    var error: String?
}

struct GitHubPRCommentsResponse: Decodable, Equatable, Sendable {
    var ok: Bool
    var cwd: String?
    var repository: GitHubRepository?
    var pullRequest: GitHubPullRequest?
    var includeResolved: Bool
    var threads: [GitHubPRThread]
    var files: [GitHubPRFileGroup]
    var totalThreadCount: Int
    var returnedThreadCount: Int
    var resolvedThreadCount: Int
    var hiddenResolvedCount: Int
    var error: String?
}

struct GitHubRepository: Decodable, Equatable, Sendable {
    var owner: String
    var name: String
    var url: String
}

struct GitHubPullRequest: Decodable, Equatable, Sendable {
    var number: Int
    var title: String
    var url: String
    var headRefName: String?
    var baseRefName: String?
    var state: String?
    var author: String?
}

struct GitHubPRFileGroup: Decodable, Equatable, Identifiable, Sendable {
    var path: String
    var threadCount: Int
    var threads: [GitHubPRThread]

    var id: String { path }
}

struct GitHubPRThread: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var path: String
    var line: Int?
    var originalLine: Int?
    var startLine: Int?
    var originalStartLine: Int?
    var diffSide: String
    var startDiffSide: String
    var subjectType: String
    var isResolved: Bool
    var isOutdated: Bool
    var url: String
    var codeContext: GitHubPRCodeContext?
    var comments: [GitHubPRComment]

    var lineLabel: String {
        let start = startLine ?? originalStartLine
        let end = line ?? originalLine
        if let start, let end, start != end {
            return "Lines \(start)-\(end)"
        }
        if let end {
            return "Line \(end)"
        }
        return "File"
    }
}

struct GitHubPRCodeContext: Decodable, Equatable, Sendable {
    var path: String
    var source: String
    var startLine: Int
    var endLine: Int
    var lines: [GitHubPRCodeLine]
}

struct GitHubPRCodeLine: Decodable, Equatable, Sendable {
    var number: Int
    var text: String
    var isTarget: Bool
}

struct GitHubPRComment: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var author: String
    var body: String
    var bodyText: String
    var createdAt: String
    var updatedAt: String
    var url: String
    var diffHunk: String
    var path: String
    var line: Int?
    var originalLine: Int?
}

extension GitHubPRThread {
    func promptReference(pullRequest: GitHubPullRequest?) -> String {
        var lines = [
            "Please address this GitHub PR review thread:",
            "",
            "PR: \(pullRequest.map { "#\($0.number) \($0.title)" } ?? "")".trimmingCharacters(in: .whitespaces),
        ]
        if let url = pullRequest?.url, !url.isEmpty {
            lines.append("PR URL: \(url)")
        }
        lines.append("File: \(path)")
        lines.append("Line: \(lineLabel)")
        if !url.isEmpty {
            lines.append("Thread URL: \(url)")
        }
        if let codeContext, !codeContext.lines.isEmpty {
            lines.append("")
            lines.append("Referenced code:")
            lines.append("```")
            for codeLine in codeContext.lines {
                let marker = codeLine.isTarget ? ">" : " "
                lines.append("\(marker) \(codeLine.number): \(codeLine.text)")
            }
            lines.append("```")
        }
        for (index, comment) in comments.enumerated() {
            lines.append("")
            lines.append("\(index == 0 ? "Comment" : "Reply") by \(comment.author.isEmpty ? "unknown" : comment.author):")
            lines.append(comment.body)
        }
        return lines.joined(separator: "\n")
    }
}
