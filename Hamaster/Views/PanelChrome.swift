//
//  PanelChrome.swift
//  Hamaster
//

import SwiftUI

/// Shared spacing for the menu panel and its hardware-free previews.
enum Panel {
    /// Unscaled panel width, read through `@ScaledMetric` at the root so the panel widens
    /// with Accessibility ▸ Larger Text rather than truncating or wrapping its labels.
    static let width: CGFloat = 360

    static let horizontalPadding: CGFloat = 16
    static let topPadding: CGFloat = 14
    static let bottomPadding: CGFloat = 14

    static let groupSpacing: CGFloat = 18
    /// Between sibling controls inside one group.
    static let rowSpacing: CGFloat = 12
    /// Between a control and the caption that explains it — tight enough that the caption
    /// clearly belongs to the control above rather than the one below.
    static let captionSpacing: CGFloat = 5
}

/// A quiet section heading, matching the weight System Settings uses for group labels.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Lets VoiceOver users jump between groups with the rotor instead of walking
            // every control in the panel.
            .accessibilityAddTraits(.isHeader)
    }
}

/// The quiet line of explanation that sits under a control.
///
/// Purely descriptive, so it is folded into the control's accessibility description by the
/// caller rather than being another stop for VoiceOver to land on.
struct SettingCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An inline note explaining a limitation or a conflict with a system setting. Deliberately
/// low-key: it informs without turning into an alert the user has to dismiss.
struct InlineNote: View {
    let text: String
    var systemImage = "info.circle"
    var isWarning = false

    var body: some View {
        // Baseline alignment rather than a Label, so the icon sits on the first line of a
        // note that wraps instead of centring itself against the whole block.
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: systemImage)
                .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.footnote)
        // The orange and the triangle are reinforcement, not the message. Saying "Warning"
        // aloud is what carries that distinction to someone who sees neither.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isWarning ? "Warning. \(text)" : text)
    }
}

/// Explicitly fills the row so switches always share the same trailing edge.
struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            VStack(alignment: .leading, spacing: Panel.rowSpacing) {
                content
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Keep short menus compact and constrain long menus without scrolling away the footer.
struct MenuPanelLayout<Content: View, Footer: View>: View {
    var width: CGFloat = Panel.width
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                paddedContent
                ScrollView { paddedContent }
            }
            Divider()
            footer
                .padding(.horizontal, Panel.horizontalPadding)
                .padding(.vertical, Panel.bottomPadding)
        }
        .font(.body)
        .frame(width: width)
        .frame(maxHeight: 720)
    }

    private var paddedContent: some View {
        content
            .padding(.horizontal, Panel.horizontalPadding)
            .padding(.vertical, Panel.topPadding)
            .fixedSize(horizontal: false, vertical: true)
    }
}
