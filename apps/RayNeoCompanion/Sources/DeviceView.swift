import SwiftUI

struct DeviceView: View {
    @EnvironmentObject private var store: CompanionStore
    @EnvironmentObject private var runtime: CompanionVoiceRuntime
    @EnvironmentObject private var automaticWeather: AutomaticWeather
    @EnvironmentObject private var qweather: QWeatherDashboard
    @State private var showSettings = false
    @State private var showConnection = false

    var body: some View {
        Screen(title: "マイグラス", eyebrow: "Turbo IO · あなたのローカルスマートグラスアシスタント", headerIcon: "gearshape", headerAction: { showSettings = true }) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("RayNeo iO").font(.system(size: 25, weight: .semibold))
                    Spacer()
                    if store.demoMode { Badge(text: "デモ画面", active: true) }
                }
                Text(runtime.ready ? "認証済み・接続中" : "未接続").font(.system(size: 15, weight: .medium))
                GlassesIllustration().padding(.horizontal, 15).padding(.vertical, 28)
                Text("グラスの輪郭イメージ · デバイスのリアルタイム状態ではありません").font(.system(size: 9)).foregroundStyle(Palette.mint.opacity(0.5))
            }
            .padding(22).foregroundStyle(.white)
            .background(LinearGradient(colors: [Palette.ink, Color(red: 0.10, green: 0.24, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))

            if runtime.supportsDevice {
                PrimaryButton(title: "ペアリング中のグラスを探す", icon: "antenna.radiowaves.left.and.right", enabled: !runtime.enabled) { runtime.discover() }
                Button("見つかった唯一のグラスに接続") { runtime.connect() }.disabled(runtime.enabled)
                Button("この App に紐づいたグラスに再接続") { runtime.reconnectBonded() }
                    .accessibilityIdentifier("reconnect-bonded")
                Text(runtime.latestEvent).font(.caption).foregroundStyle(Palette.muted)
            } else {
                PrimaryButton(title: "シミュレータではグラスに接続しません", icon: "link", enabled: false) {}
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                Button { store.selectedTab = 1 } label: { shortcut("mic", title: "音声アシスタント", subtitle: "音声認識と会話") }.buttonStyle(.plain)
                Button { store.selectedTab = 2 } label: { shortcut("folder", title: "録音アーカイブ", subtitle: "ローカル音声を管理") }.buttonStyle(.plain)
                NavigationLink { PrompterView() } label: { shortcut("text.alignleft", title: "プロンプター", subtitle: "編集とスマホプレビュー") }.buttonStyle(.plain)
                NavigationLink { TodoView() } label: { shortcut("checkmark.circle", title: "ToDoリスト", subtitle: "タスクを記録・管理") }.buttonStyle(.plain)
            }
            NavigationLink { QWeatherDashboardView() } label: {
                Label(qweather.status, systemImage: "cloud.sun")
                    .font(.caption).foregroundStyle(Palette.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("device-weather-status")
            Button { showConnection = true } label: {
                Label("ローカル機能は利用可能、グラス操作は要検証", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(Palette.green).padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading).background(Palette.mint.opacity(0.18), in: RoundedRectangle(cornerRadius: 15))
            }.buttonStyle(.plain)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear { runtime.prepare() }
        .sheet(isPresented: $showConnection) { ConnectionBoundaryView() }
    }

    private func shortcut(_ icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.system(size: 25, weight: .light)).foregroundStyle(Palette.ink)
                .frame(width: 34, height: 38).background(Palette.mint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Palette.line.opacity(0.6), lineWidth: 0.75))
    }
}

struct ConnectionBoundaryView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "link.badge.plus").font(.system(size: 35, weight: .light)).foregroundStyle(Palette.green)
                    Text("接続には、明確な境界があります。").font(.title2.bold()).foregroundStyle(Palette.ink)
                    Text("Turbo IOは独立した Bundle とサンドボックスを使います。実機ビルドにはプロトタイプの通信コアと音声チェーンが組み込まれていますが、シミュレータビルドはベンダーライブラリを読み込まず、Bluetooth コマンドも送信しません。新しい App のペアリング、バックグラウンド動作、レンズ表示の効果は、実機での再検証が必要です。")
                        .font(.subheadline).foregroundStyle(Palette.muted).lineSpacing(5)
                    Card {
                        FeatureRow(icon: "iphone", title: "スマホ側のローカル機能", subtitle: "下書き、インポート、設定と状態のデモ", status: "利用可能", active: true)
                        FeatureRow(icon: "link", title: "接続、認証、ペアリング解除", subtitle: "実機ではプロトタイプコアを再利用。自動では解除やリセットをしません")
                        FeatureRow(icon: "eyeglasses", title: "レンズ表示と逆方向イベント", subtitle: "実際のグラスで項目ごとに検証が必要です")
                        FeatureRow(icon: "signature", title: "非脱獄の署名デバイス", subtitle: "シミュレータビルドは非脱獄経路の検証にはなりません", status: "実機待ち")
                    }
                    Text("ファームウェアの操作、公式アカウントのペアリング解除、マイクの自動オン、録音のアップロードは行いません。")
                        .font(.footnote).foregroundStyle(Palette.green)
                }.padding(24)
            }.background(Palette.background).navigationTitle("接続の進捗").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
    }
}
