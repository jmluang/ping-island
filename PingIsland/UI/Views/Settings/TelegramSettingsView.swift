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

    @Published var tokenInput: String
    @Published private(set) var connectionState: ConnectionState = .idle

    private let tokenStore: TelegramTokenStoring
    private let clientFactory: (String) -> TelegramGetMeClient

    init(
        tokenStore: TelegramTokenStoring = TelegramTokenStore(),
        clientFactory: @escaping (String) -> TelegramGetMeClient = { TelegramAPIClient(token: $0) }
    ) {
        self.tokenStore = tokenStore
        self.clientFactory = clientFactory
        self.tokenInput = (try? tokenStore.load()) ?? ""
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
}

struct TelegramSettingsView: View {
    @StateObject private var viewModel = TelegramSettingsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bot Token")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)

                Text("Telegram Bot API token is stored in Keychain.")
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
                        Text("测试连接")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.connectionState == .testing)
            }

            statusRow
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

    private var statusText: String {
        switch viewModel.connectionState {
        case .idle:
            return "未测试"
        case .testing:
            return "正在测试连接..."
        case .ok(let username):
            return "已连接 @\(username)"
        case .invalidToken:
            return "Token 无效"
        case .networkError:
            return "网络连接失败"
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
}
