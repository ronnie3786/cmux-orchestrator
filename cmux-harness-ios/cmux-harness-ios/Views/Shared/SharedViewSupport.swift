import AVFoundation
import Combine
import ComposableArchitecture
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SessionTitleView: View {
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(workspace.cardTitle)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitle = workspace.cardSubtitle {
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct MetaLine: View {
    let workspace: Workspace
    var showsPath = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsPath, let cwd = workspace.cwd, !cwd.isEmpty {
                Label(cwd, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            HStack(spacing: 12) {
                if let branch = workspace.branch, !branch.isEmpty {
                    Label(branch, systemImage: "point.3.connected.trianglepath.dotted")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let lastCheck = workspace.lastCheck, !lastCheck.isEmpty {
                    Label(formatTimestamp(lastCheck), systemImage: "clock")
                }
                if let surfaceTitle = workspace.surfaceTitle, !surfaceTitle.isEmpty {
                    Label(surfaceTitle, systemImage: "square.split.2x1")
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct SessionBadge: View {
    let state: WorkspaceSessionState

    var body: some View {
        Text(state.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor, in: Capsule())
            .overlay {
                Capsule().strokeBorder(foregroundColor.opacity(0.35), lineWidth: 1)
            }
            .accessibilityLabel(state.label)
    }

    private var foregroundColor: Color {
        switch state {
        case .session:
            return .green
        case .waiting:
            return .orange
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .session:
            return Color.green.opacity(0.14)
        case .waiting:
            return Color.orange.opacity(0.14)
        }
    }
}

struct AutoExpirationText: View {
    let workspace: Workspace

    var body: some View {
        if let autoExpiresAt = workspace.autoExpiresAt, autoExpiresAt > 0 {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                Label(
                    autoExpirationLabel(
                        expiresAt: autoExpiresAt,
                        now: timeline.date,
                        mode: workspace.resolvedAutoMode
                    ),
                    systemImage: "timer"
                )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct ConnectionDot: View {
    enum State {
        case demo
        case connected
        case reconnecting
        case offline
    }

    let state: State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 11, height: 11)
            .shadow(color: color.opacity(0.4), radius: 4)
    }

    private var color: Color {
        switch state {
        case .demo:
            return .orange
        case .connected:
            return .green
        case .reconnecting:
            return .orange
        case .offline:
            return .red
        }
    }
}

struct StatPill: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ErrorBanner: View {
    let message: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: action)
                .font(.caption)
        }
    }
}

func formatTimestamp(_ value: String) -> String {
    if let date = ISO8601DateFormatter().date(from: value) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    return value
}

extension Workspace {
    var cardTitle: String {
        if let pathTail = displayName.pathTail(componentCount: 2) {
            return pathTail
        }
        return displayName
    }

    var cardSubtitle: String? {
        if let cwd = cwd?.nonEmptyTrimmed {
            return cwd
        }
        if displayName != cardTitle, displayName.contains("/") {
            return displayName
        }
        if let surfaceTitle = surfaceTitle?.nonEmptyTrimmed, surfaceTitle != cardTitle {
            return surfaceTitle
        }
        return nil
    }
}

extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func abbreviatedPath(componentCount: Int) -> String {
        guard let tail = pathTail(componentCount: componentCount) else { return self }
        return ".../\(tail)"
    }

    func pathTail(componentCount: Int) -> String? {
        let components = replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { component in
                let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && trimmed != "..." && trimmed != "…"
            }

        guard components.count > 1 else { return nil }
        return components.suffix(max(1, componentCount)).joined(separator: "/")
    }
}

extension DetailTab {
    var sessionLabel: String {
        switch self {
        case .terminal:
            return "Session"
        case .git:
            return "Git"
        case .activity:
            return "Activity"
        case .skills:
            return "Skills"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal:
            return "terminal"
        case .git:
            return "point.3.connected.trianglepath.dotted"
        case .activity:
            return "waveform.path.ecg"
        case .skills:
            return "wand.and.stars"
        }
    }
}

func costColor(_ value: String) -> Color {
    let number = Double(value.replacingOccurrences(of: "$", with: "")) ?? 0
    if number >= 5 {
        return .red
    }
    if number >= 2 {
        return .orange
    }
    return .secondary
}

func autoExpirationLabel(expiresAt: Double, now: Date, mode: WorkspaceAutoMode) -> String {
    let remaining = expiresAt - now.timeIntervalSince1970
    if remaining <= 0 {
        return "\(mode.label) expired"
    }
    return "\(mode.label) \(formatRemainingDuration(remaining))"
}

func formatRemainingDuration(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(Int(seconds.rounded(.up)), 0)
    if totalSeconds >= 3_600 {
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
    if totalSeconds >= 60 {
        return "\(max(1, totalSeconds / 60))m"
    }
    return "\(totalSeconds)s"
}

func diffColor(for line: String) -> Color {
    if line.hasPrefix("+") && !line.hasPrefix("+++") {
        return .green
    }
    if line.hasPrefix("-") && !line.hasPrefix("---") {
        return .red
    }
    if line.hasPrefix("@@") {
        return .blue
    }
    return .primary
}

func diffBackground(for line: String) -> Color {
    if line.hasPrefix("+") && !line.hasPrefix("+++") {
        return Color.green.opacity(0.08)
    }
    if line.hasPrefix("-") && !line.hasPrefix("---") {
        return Color.red.opacity(0.08)
    }
    if line.hasPrefix("@@") {
        return Color.blue.opacity(0.08)
    }
    return Color.clear
}
