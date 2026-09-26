import SwiftUI

/// Small native-style lock dialog.
/// The protected app is hidden before this view is presented.
struct LockOverlayView: View {
    let appName: String
    let bundleIdentifier: String
    let onDismiss: () -> Void
    let onCancel: () -> Void

    @State private var showPasswordInput = false
    @State private var authState: AuthState = .waitingForUser
    @State private var errorMessage: String?

    private enum AuthState {
        case waitingForUser
        case authenticating
    }

    var body: some View {
        Group {
            if showPasswordInput {
                VStack(spacing: 12) {
                    PasswordInputView(
                        onSuccess: {
                            onDismiss()
                        },
                        onCancel: {
                            showPasswordInput = false
                            authState = .waitingForUser
                        }
                    )

                    SecondaryButton("Cancel") {
                        onCancel()
                    }
                }
            } else {
                VStack(spacing: 16) {
                    AppIconView(
                        bundleIdentifier: bundleIdentifier,
                        size: 56
                    )

                    Text("\(appName) is Locked")
                        .font(MakLockTypography.largeTitle)
                        .foregroundColor(
                            MakLockColors.textPrimary
                        )
                        .multilineTextAlignment(.center)

                    Text("Authenticate to continue")
                        .font(MakLockTypography.body)
                        .foregroundColor(
                            MakLockColors.textSecondary
                        )

                    if let errorMessage {
                        Text(errorMessage)
                            .font(MakLockTypography.caption)
                            .foregroundColor(
                                MakLockColors.error
                            )
                            .multilineTextAlignment(.center)
                    }

                    if authState == .authenticating {
                        ProgressView()
                            .controlSize(.regular)

                        Text("Authenticating...")
                            .font(MakLockTypography.body)
                            .foregroundColor(
                                MakLockColors.textSecondary
                            )
                    } else {
                        PrimaryButton(
                            "Unlock with Touch ID",
                            icon: "touchid"
                        ) {
                            attemptTouchID()
                        }

                        SecondaryButton("Use Password Instead") {
                            OverlayWindowService.shared.enableKeyboardInput()

                            withAnimation(
                                MakLockAnimations.standard
                            ) {
                                showPasswordInput = true
                            }
                        }

                        SecondaryButton("Cancel") {
                            onCancel()
                        }
                    }

                    #if DEBUG
                    Button("Skip (Dev)") {
                        onDismiss()
                    }
                    .font(MakLockTypography.caption)
                    .foregroundColor(MakLockColors.error)
                    #endif
                }
            }
        }
        .padding(28)
        .frame(width: 420)
        .background(
            RoundedRectangle(
                cornerRadius: 18,
                style: .continuous
            )
            .fill(MakLockColors.cardDark)
            .shadow(
                color: .black.opacity(0.35),
                radius: 22,
                y: 10
            )
        )
    }

    private func attemptTouchID() {
        authState = .authenticating
        errorMessage = nil

        AuthenticationService.shared.authenticateWithTouchID(
            reason: "Unlock \(appName)"
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    authState = .waitingForUser
                    onDismiss()

                case .failure(let error):
                    authState = .waitingForUser
                    errorMessage = error.localizedDescription

                case .cancelled:
                    authState = .waitingForUser
                }
            }
        }
    }
}
