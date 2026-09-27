//
//  ToastView.swift
//  CameraStarter
//
//  Reusable toast notification component
//  Shows brief messages at top of screen, auto-dismisses
//

import SwiftUI

// MARK: - Toast Action

struct ToastAction: Equatable {
    let title: String
    let action: () -> Void

    static func == (lhs: ToastAction, rhs: ToastAction) -> Bool {
        // Compare by title only since closures can't be compared
        lhs.title == rhs.title
    }
}

// MARK: - Toast Model

struct ToastMessage: Equatable {
    let message: String
    let type: ToastType
    let action: ToastAction?
    let showCloseButton: Bool  // Show close button and disable auto-dismiss

    init(message: String, type: ToastType, action: ToastAction? = nil, showCloseButton: Bool = false) {
        self.message = message
        self.type = type
        self.action = action
        self.showCloseButton = showCloseButton
    }

    enum ToastType {
        case success
        case info
        case warning
        case error
    }

    /// Whether this toast should persist (not auto-dismiss)
    /// True if it has an action button or showCloseButton is set
    var shouldPersist: Bool {
        action != nil || showCloseButton
    }

    var icon: String {
        switch type {
        case .success:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.circle.fill"
        }
    }

    var iconColor: Color {
        switch type {
        case .success:
            return .appSuccess
        case .info:
            return .accentColor
        case .warning:
            return .orange
        case .error:
            return .appError
        }
    }
}

// MARK: - Toast View

struct ToastView: View {
    let toast: ToastMessage
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            // SF Symbol icon based on toast type
            Image(systemName: toast.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(toast.iconColor)

            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.appPrimaryText)
                .multilineTextAlignment(.leading)
                .lineLimit(3)

            // Action button (if provided)
            if let action = toast.action {
                Button(action.title) {
                    action.action()
                    onDismiss?()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }

            // Close button (shown when toast persists - has action or showCloseButton)
            if toast.shouldPersist {
                Button {
                    onDismiss?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.appSecondaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // A material, like the system's own banners, so it reads over the
        // camera preview and over plain backgrounds alike
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .onTapGesture {
            onDismiss?()
        }
    }
}

// MARK: - Toast Modifier

struct ToastModifier: ViewModifier {
    @Binding var toast: ToastMessage?
    let duration: TimeInterval

    @State private var workItem: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = toast {
                    ToastView(toast: toast) {
                        dismissToast()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
                    .padding(.top, 8)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toast)
            .onChange(of: toast) { _, newValue in
                if let newValue, !newValue.shouldPersist {
                    // Only auto-dismiss if toast doesn't need to persist
                    scheduleHide()
                } else {
                    // Cancel any pending hide if toast should persist
                    workItem?.cancel()
                }
            }
    }

    private func dismissToast() {
        workItem?.cancel()
        withAnimation {
            toast = nil
        }
    }

    private func scheduleHide() {
        workItem?.cancel()
        let task = DispatchWorkItem {
            withAnimation {
                toast = nil
            }
        }
        workItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }
}

// MARK: - View Extension

extension View {
    /// Show a toast message at the top of the view
    /// - Parameters:
    ///   - toast: Binding to the toast message (nil = hidden)
    ///   - duration: How long to show the toast (default 3 seconds)
    func toast(_ toast: Binding<ToastMessage?>, duration: TimeInterval = 2) -> some View {
        modifier(ToastModifier(toast: toast, duration: duration))
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        ToastView(toast: ToastMessage(message: "Live Photo on", type: .info))
        ToastView(toast: ToastMessage(message: "Storage is almost full", type: .warning))
        ToastView(toast: ToastMessage(message: "Couldn't save the photo", type: .error))
        ToastView(
            toast: ToastMessage(
                message: "Microphone access required",
                type: .error,
                action: ToastAction(title: "Settings") { }
            )
        )
    }
    .padding()
    .background(Color.appBackground)
}
