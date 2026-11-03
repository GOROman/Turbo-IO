import SwiftUI
import RayNeoArchive
import RayNeoAudioContainer

struct AudioContainerInspectionView: View {
    @EnvironmentObject private var archive: LocalArchiveController
    @EnvironmentObject private var inspection: AudioContainerInspectionController
    let recordingID: UUID
    private var recording: ArchivedRecording? { archive.recordings.first { $0.id == recordingID } }
    private var issue: String? { archive.verificationIssues[recordingID] }
    private var ownResult: AudioContainerCheckResult? { inspection.result?.identity.recordingID == recordingID ? inspection.result : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("本機の構造チェック", systemImage: "waveform.path.ecg").font(.caption).foregroundStyle(Palette.mint)
                    Text("コンテナが通っても、音声が使えるとは限りません。").font(.title3.weight(.semibold)).foregroundStyle(.white)
                    Text("Ogg / Opus の宣言サブセットのみをチェックします。再生・デコード・音声認識は行いません。")
                        .font(.caption).foregroundStyle(Palette.mint.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.ink, in: RoundedRectangle(cornerRadius: 20))
                if let recording {
                    Card {
                        Text(recording.title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                        Text("ファイル \(ByteCountFormatter.string(fromByteCount: recording.byteCount, countStyle: .file)) · チェック上限 64 MiB")
                            .font(.caption).foregroundStyle(Palette.muted)
                        Text("アーカイブ記録 SHA-256\n\(recording.sha256)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                    }
                    if let issue {
                        Label("アーカイブ検証に異常があります。詳細に戻ってまず全体を再確認してください。\n\(issue)", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Palette.amber)
                    }
                    operationControls(recording)
                } else { Text("この録音は現在のアーカイブにありません。戻って更新してください。").foregroundStyle(Palette.amber) }

                if let message = inspection.message, inspection.identity?.recordingID == recordingID {
                    Text(message).font(.caption).foregroundStyle(Palette.amber).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color(red: 0.99, green: 0.95, blue: 0.85), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("container-check-message")
                }
                if let result = ownResult { resultView(result) }
                Card {
                    Text("チェック範囲とリソース").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text("単一ストリーム、連結なし、Opus v1、mapping 0、1または2チャンネル。CRC・ページ順・パケット境界・granule は構造上の証拠にすぎず、元の無線転送でパケット損失がなかったことは証明しません。")
                    Text("64 KiB ずつ読み取り。入力上限 64 MiB、パケット上限 1 MiB。予算を超えたら停止し、自動では拡大しません。チェックタスクは1つだけで、待機キューは作りません。")
                    Text("このページを離れるとキャンセルされ結果も消えます。再入しても自動チェックはしません。ファイルの変化やアーカイブ異常で古い結果は無効になります。キャンセル後はリソース解放を待ってから再開できます。")
                }.font(.caption).foregroundStyle(Palette.muted)
            }.padding(24)
        }.background(Palette.background).navigationTitle("音声コンテナチェック").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar).preference(key: CompanionTabBarHiddenPreference.self, value: true)
            .toolbarBackground(Palette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .onDisappear { inspection.leave(recordingID: recordingID) }
    }

    @ViewBuilder private func operationControls(_ recording: ArchivedRecording) -> some View {
        if ownResult != nil {
            PrimaryButton(title: "結果を消して再チェック", icon: "arrow.counterclockwise") { inspection.clear() }
                .accessibilityIdentifier("container-clear")
            Text("画面の結果だけを消します。音声やノートは削除しません。").font(.caption2).foregroundStyle(Palette.muted)
        } else if !inspection.canStart {
            ProgressView(value: inspection.progress?.fraction ?? 0) {
                Text(inspection.phase == .preparing ? "本機のアーカイブコピーを確認中…" : (inspection.phase == .reading ? "分割してチェック中…" : "以前の処理とモニターの終了を待っています…"))
            }.font(.caption).accessibilityIdentifier("container-progress")
            if let progress = inspection.progress {
                Text("\(ByteCountFormatter.string(fromByteCount: progress.bytesRead, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                    .font(.caption2).foregroundStyle(Palette.muted)
            }
            Button("チェックをキャンセル") { inspection.cancel() }.font(.subheadline).accessibilityIdentifier("container-cancel")
        } else {
            PrimaryButton(title: "音声コンテナをチェック", icon: "waveform.path.ecg", enabled: issue == nil && !archive.isBusy) {
                inspection.start(AudioInspectionIdentity(recording))
            }.accessibilityIdentifier("container-start")
            if inspection.phase == .idle { Text("未チェック。ページを開いても音声は読み取りません。").font(.caption).foregroundStyle(Palette.muted).accessibilityIdentifier("container-idle") }
        }
    }

    private func resultView(_ result: AudioContainerCheckResult) -> some View {
        Card {
            Text(result.outcome.title).font(.headline).foregroundStyle(resultColor(result.outcome)).accessibilityIdentifier("container-outcome")
            Text("チェック時刻：\(result.checkedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(Palette.muted)
            Text("チェック対象ストリームの SHA-256 は上記のアーカイブ記録と照合済み。今回の本機バイト列にのみ対応します。").font(.caption2).foregroundStyle(Palette.muted)
            switch result.outcome {
            case .supported(let report):
                VStack(spacing: 10) {
                    metric("Ogg ページ / CRC 合格ページ", "\(report.pageCount) / \(report.crcCheckedPages)")
                    metric("音声パケット / ヘッダー含む全パケット", "\(report.audioPacketCount) / \(report.packetCountIncludingHeaders)")
                    metric("BOS / EOS", "\(report.bosPresent ? "あり" : "なし") / \(report.eosPresent ? "あり" : "なし")")
                    metric("チャンネル / pre-skip", "\(report.opusHeader.channels) / \(report.opusHeader.preSkip)")
                    metric("先頭 / 末尾 granule", "\(report.firstAudioGranule) / \(report.finalGranule)")
                    metric("末尾 PCM 位置", "\(report.finalPCMPosition)")
                    metric("48 kHz 時間位置", String(format: "%.4f 秒", report.finalPCMPositionSeconds))
                    metric("解析ページバッファのピーク", "\(result.peakParserPageBytes) バイト")
                }
                Text("時間位置は実測した録音時間やデコード時間ではありません。ページバッファのピークは App 全体のメモリではありません。TOC・実際のパケット長・granule 増分の一貫性は未チェックです。")
                    .font(.caption).foregroundStyle(Palette.amber)
            case .unsupported(let reason), .invalid(let reason), .limited(let reason):
                Text(reason).font(.subheadline).foregroundStyle(Palette.muted)
            }
            Text("デコードなし · ASR 未実行 · アップロードなし").font(.caption.weight(.medium)).foregroundStyle(Palette.muted)
                .accessibilityIdentifier("container-no-asr")
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(Palette.muted); Spacer(minLength: 12)
            Text(value).foregroundStyle(Palette.ink).monospacedDigit()
        }.font(.caption)
    }
    private func resultColor(_ outcome: AudioContainerOutcome) -> Color {
        if case .supported = outcome { return Palette.green }
        return Palette.amber
    }
}
