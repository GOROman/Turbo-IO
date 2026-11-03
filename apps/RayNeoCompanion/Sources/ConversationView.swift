import SwiftUI
import RayNeoSession

struct LegacyConversationView: View {
    @EnvironmentObject private var store: CompanionStore
    @State private var showConfiguration = false
    @State private var showSimulation = false

    var body: some View {
        Screen(title: "音声会話", eyebrow: "ローカル認識と会話") {
            HStack {
                Label("接続待ち", systemImage: "clock").font(.system(size: 16, weight: .semibold))
                Spacer(); Badge(text: "まだ録音していません", active: true)
            }.foregroundStyle(Palette.ink).padding(16).background(Palette.mint.opacity(0.18), in: RoundedRectangle(cornerRadius: 17))

            VStack(spacing: 13) {
                Text("あなたの声を、あなたのモデルへ").font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                Text("認識 · 会話 · 返答").font(.system(size: 13)).foregroundStyle(Palette.mint.opacity(0.7))
                HStack(spacing: 4) {
                    ForEach(0..<39) { index in
                        let height = Double([5, 8, 14, 25, 38, 27, 17, 9, 20, 30, 42, 24, 16][index % 13])
                        Capsule().fill(Palette.mint.opacity(0.35 + Double(index % 4) * 0.1)).frame(width: 3, height: height)
                    }
                }.frame(height: 65).padding(.top, 21).accessibilityLabel("静的な音声イメージ。音声は収録していません")
                Text("マイク未有効 · 音声は送信されていません").font(.system(size: 10)).foregroundStyle(Palette.mint.opacity(0.55))
            }.padding(.vertical, 35).frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [Palette.ink, Color(red: 0.10, green: 0.24, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))

            Card {
                Button { showConfiguration = true } label: {
                    HStack {
                        Label("認識元", systemImage: "waveform").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ink)
                        Spacer(); Text("実測で決定").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                    }
                }.buttonStyle(.plain)
                Divider().overlay(Palette.line)
                Button { showConfiguration = true } label: {
                    HStack {
                        Label("モデルサービス", systemImage: "server.rack").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ink)
                        Spacer(); Text(store.configuration.endpoint.isEmpty ? "未設定" : "この端末に保存済み").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                    }
                }.buttonStyle(.plain)
            }
            PrimaryButton(title: "モデル設定", icon: "gearshape") { showConfiguration = true }.accessibilityIdentifier("model-settings")
            Button { showSimulation = true } label: {
                Label("ローカルフロー デモ", systemImage: "play")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink).frame(maxWidth: .infinity).padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.green, lineWidth: 1))
            }.accessibilityIdentifier("open-session-lab")
        }
        .sheet(isPresented: $showConfiguration) { ModelConfigurationView() }
        .sheet(isPresented: $showSimulation) { SessionSimulationView() }
    }

}

struct ModelConfigurationView: View {
    @EnvironmentObject private var store: CompanionStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ModelConfiguration()
    @State private var key = ""
    @State private var hasKey = false
    @State private var error: String?
    @State private var confirmRemoval = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("設定を保存するだけです。サービスには接続しません", systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(Palette.green).padding(15)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Palette.mint.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                    Card {
                        Text("サービスアドレス").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink)
                        TextField("HTTPS ベースアドレス（空欄可）", text: $draft.endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(13).background(Palette.background, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("model-endpoint")
                        Text("モデル名").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink)
                        TextField("モデル名を入力", text: $draft.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(13).background(Palette.background, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("model-name")
                        Text("APIキー").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.ink)
                        SecureField(hasKey ? "新しいキー（空欄でこのアドレスのキーを保持）" : "キーチェーンに安全に保存（空欄可）", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(13).background(Palette.background, in: RoundedRectangle(cornerRadius: 10)).privacySensitive()
                        Text(hasKey ? "このサービスアドレスのキーは保存済みです。元の値は表示しません。" : "キーは完全なサービスアドレス毎に個別保存し、アドレスをまたいで使い回しません。")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                    }
                    Card {
                        HStack {
                        Text("音声認識の方針").foregroundStyle(Palette.ink).accessibilityIdentifier("recognition-strategy-label")
                        Spacer()
                        Picker("音声認識の方針", selection: $draft.recognition) {
                            Text("実測で決定").tag("待实测决定")
                            Text("ローカル Sherpa（未対応）").tag("本地 Sherpa")
                            Text("自前クラウド（未対応）").tag("自有云端")
                        }.labelsHidden().accessibilityLabel("音声認識の方針")
                        }
                        Divider().overlay(Palette.line)
                        HStack {
                        Text("音声出力").foregroundStyle(Palette.ink).accessibilityIdentifier("speech-output-label")
                        Spacer()
                        Picker("音声出力", selection: $draft.speech) {
                            Text("未対応").tag("待接入")
                            Text("システム音声（未対応）").tag("系统语音")
                            Text("自前TTS（未対応）").tag("自有 TTS")
                        }.labelsHidden().accessibilityLabel("音声出力")
                        }
                    }.font(.system(size: 14))
                    PrimaryButton(title: "設定を保存", icon: "square.and.arrow.down") { save() }.accessibilityIdentifier("save-model")
                    Label("公式アカウントやクラウド認証情報は使いません", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Palette.amber).padding(15)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color(red: 0.99, green: 0.95, blue: 0.85), in: RoundedRectangle(cornerRadius: 14))
                    Text("キーは現在のデバイスでのみ、ロック解除後に使えます。ログや設定ファイルには書きません。認識と音声の選択肢は方針の下書きに過ぎず、モデルを実行したりグラスの設定を変更したりはしません。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                    if hasKey { Button("このサービスの端末内キーを削除", role: .destructive) { confirmRemoval = true }.font(.footnote) }
                }.padding(24)
            }.background(Palette.background).scrollDismissesKeyboard(.interactively)
            .navigationTitle("モデル設定").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            }
            .onAppear { draft = store.configuration; hasKey = CredentialVault.hasKey(for: draft.endpoint) }
            .onChange(of: draft.endpoint) { _ in hasKey = CredentialVault.hasKey(for: draft.endpoint) }
            .confirmationDialog("Turbo IO自身が保存したモデルキーだけを削除します。公式Appには影響しません。", isPresented: $confirmRemoval) {
                Button("この端末のキーを削除", role: .destructive) {
                    do { try CredentialVault.remove(for: draft.endpoint); hasKey = false } catch { self.error = error.localizedDescription }
                }
            }
            .alert("設定を保存していません", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("了解", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }
    private func save() {
        do { try store.saveConfiguration(draft, key: key); key = ""; dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
