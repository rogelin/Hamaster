//
//  PermissionCard.swift
//  Hamaster
//

import SwiftUI

/// Explains a missing permission in terms of what the user loses, and offers the one
/// button that helps. Both grants are one-way trips through System Settings, so the card
/// stays until the app observes the grant rather than assuming the button worked.
struct PermissionCard: View {
    let title: String
    let message: String
    let isRequired: Bool
    var action: (() -> Void)? = nil
    var actionTitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Panel.captionSpacing) {
            Label(title, systemImage: isRequired ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(isRequired ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityAddTraits(.isHeader)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let action, let actionTitle {
                Button(actionTitle, action: action)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.5))
        )
        // Read as one passage — heading, explanation, then the button — instead of three
        // fragments a VoiceOver user has to reassemble.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isRequired ? "\(title). Required." : title)
    }
}
