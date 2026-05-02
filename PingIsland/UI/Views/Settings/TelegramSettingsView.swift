import Combine
import SwiftUI

@MainActor
final class TelegramSettingsViewModel: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case testing
        case ok(String)
        case invalidToken
        case networkError
    }

    enum PairingState: Equatable {
        case idle
        case opening
        case open
    }

    @Published var tokenInput: String
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var pairingState: PairingState = .idle
    @Published private(set) var masterEnabled: Bool
    @Published private(set) var permissionEvents: Bool
    @Published private(set) var questionEvents: Bool
    @Published private(set) var completionEvents: Bool
    @Published private(set) var errorAndLimitEvents: Bool

    private let tokenStore: TelegramTokenStoring
    private var settings: TelegramSettings
    private let clientFactory: (String) -> TelegramGetMeClient
    private let beginPairing: () async -> Void

    init(
        tokenStore: TelegramTokenStoring = TelegramTokenStore(),
        settings: TelegramSettings = TelegramSettings(),
        clientFactory: @escaping (String) -> TelegramGetMeClient = { TelegramAPIClient(token: $0) },
        beginPairing: @escaping () async -> Void = {
            await TelegramService.shared.beginPairing()
        }
    ) {
        self.tokenStore = tokenStore
        self.settings = settings
        self.clientFactory = clientFactory
        self.beginPairing = beginPairing
        self.tokenInput = (try? tokenStore.load()) ?? ""
        self.masterEnabled = settings.masterEnabled
        self.permissionEvents = settings.permissionEvents
        self.questionEvents = settings.questionEvents
        self.completionEvents = settings.completionEvents
        self.errorAndLimitEvents = settings.errorEvents && settings.limitEvents
    }

    func saveAndTest() async {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            connectionState = .invalidToken
            return
        }

        connectionState = .testing

        do {
            try tokenStore.save(token)
        } catch {
            connectionState = .networkError
            return
        }

        switch await clientFactory(token).getMe() {
        case .success(let user):
            connectionState = .ok(user.username ?? "\(user.id)")
        case .failure(.http(status: 401, description: _)),
             .failure(.botApi(errorCode: 401, description: _)):
            connectionState = .invalidToken
        case .failure:
            connectionState = .networkError
        }
    }

    func startPairing() async {
        pairingState = .opening
        await beginPairing()
        pairingState = .open
    }

    func setMasterEnabled(_ isEnabled: Bool) {
        masterEnabled = isEnabled
        settings.masterEnabled = isEnabled
    }

    func setPermissionEvents(_ isEnabled: Bool) {
        permissionEvents = isEnabled
        settings.permissionEvents = isEnabled
    }

    func setQuestionEvents(_ isEnabled: Bool) {
        questionEvents = isEnabled
        settings.questionEvents = isEnabled
    }

    func setCompletionEvents(_ isEnabled: Bool) {
        completionEvents = isEnabled
        settings.completionEvents = isEnabled
    }

    func setErrorAndLimitEvents(_ isEnabled: Bool) {
        errorAndLimitEvents = isEnabled
        settings.errorEvents = isEnabled
        settings.limitEvents = isEnabled
    }
}

struct TelegramSettingsView: View {
    @StateObject private var viewModel = TelegramSettingsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(appLocalized: "Telegram.Settings.BotToken.Title")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)

                Text(appLocalized: "Telegram.Settings.BotToken.Description")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
            }

            HStack(spacing: 12) {
                SecureField("123456:ABC-DEF", text: $viewModel.tokenInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )

                Button {
                    Task { await viewModel.saveAndTest() }
                } label: {
                    if viewModel.connectionState == .testing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(appLocalized: "Telegram.Settings.TestConnection")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.connectionState == .testing)
            }

            statusRow

            Divider()
                .background(Color.white.opacity(0.12))
                .padding(.vertical, 4)

            notificationSection

            Divider()
                .background(Color.white.opacity(0.12))
                .padding(.vertical, 4)

            pairingSection
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.68))
        }
    }

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(appLocalized: "Telegram.Settings.Notifications.Title")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)

                Text(appLocalized: "Telegram.Settings.Notifications.Description")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
            }

            VStack(alignment: .leading, spacing: 9) {
                Toggle(isOn: Binding(
                    get: { viewModel.masterEnabled },
                    set: { viewModel.setMasterEnabled($0) }
                )) {
                    Text(appLocalized: "Telegram.Settings.Notifications.EnableTelegram")
                }
                .toggleStyle(.switch)

                eventToggle("Telegram.Settings.Notifications.PermissionRequests", isOn: Binding(
                    get: { viewModel.permissionEvents },
                    set: { viewModel.setPermissionEvents($0) }
                ))

                eventToggle("Telegram.Settings.Notifications.Questions", isOn: Binding(
                    get: { viewModel.questionEvents },
                    set: { viewModel.setQuestionEvents($0) }
                ))

                eventToggle("Telegram.Settings.Notifications.Completions", isOn: Binding(
                    get: { viewModel.completionEvents },
                    set: { viewModel.setCompletionEvents($0) }
                ))

                eventToggle("Telegram.Settings.Notifications.ErrorsAndLimits", isOn: Binding(
                    get: { viewModel.errorAndLimitEvents },
                    set: { viewModel.setErrorAndLimitEvents($0) }
                ))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white.opacity(0.82))
        }
    }

    private func eventToggle(_ titleKey: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(appLocalized: titleKey)
        }
            .toggleStyle(.switch)
            .disabled(!viewModel.masterEnabled)
            .opacity(viewModel.masterEnabled ? 1 : 0.45)
            .padding(.leading, 14)
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(appLocalized: "Telegram.Settings.Pairing.Title")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)

                Text(pairingStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
            }

            Button {
                Task { await viewModel.startPairing() }
            } label: {
                if viewModel.pairingState == .opening {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(appLocalized: "Telegram.Settings.Pairing.Start")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.pairingState == .opening)
        }
    }

    private var statusText: String {
        switch viewModel.connectionState {
        case .idle:
            return AppLocalization.string("Telegram.Settings.Connection.Idle")
        case .testing:
            return AppLocalization.string("Telegram.Settings.Connection.Testing")
        case .ok(let username):
            return AppLocalization.format("Telegram.Settings.Connection.OK", username)
        case .invalidToken:
            return AppLocalization.string("Telegram.Settings.Connection.InvalidToken")
        case .networkError:
            return AppLocalization.string("Telegram.Settings.Connection.NetworkError")
        }
    }

    private var statusColor: Color {
        switch viewModel.connectionState {
        case .idle:
            return .white.opacity(0.36)
        case .testing:
            return Color(red: 0.35, green: 0.63, blue: 1.0)
        case .ok:
            return Color(red: 0.26, green: 0.82, blue: 0.46)
        case .invalidToken, .networkError:
            return Color(red: 1.0, green: 0.36, blue: 0.34)
        }
    }

    private var pairingStatusText: String {
        switch viewModel.pairingState {
        case .idle:
            return AppLocalization.string("Telegram.Settings.Pairing.Idle")
        case .opening:
            return AppLocalization.string("Telegram.Settings.Pairing.Opening")
        case .open:
            return AppLocalization.string("Telegram.Settings.Pairing.Open")
        }
    }
}
