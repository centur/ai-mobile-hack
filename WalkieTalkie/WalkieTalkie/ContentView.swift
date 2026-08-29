import SwiftUI

struct ContentView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var viewModel = TranscriptionViewModel()

    private var isCompactLandscape: Bool {
        verticalSizeClass == .compact
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let spacing: CGFloat = isCompactLandscape ? 8 : 12
                let targetPanelHeight = proxy.size.height * 0.625
                let sourcePanelHeight = proxy.size.height - targetPanelHeight - spacing

                VStack(spacing: spacing) {
                    languagePanel(
                        side: .top,
                        language: viewModel.topLanguage,
                        tint: .blue,
                        background: Color.blue.opacity(0.09)
                    )
                    .frame(height: targetPanelHeight)

                    languagePanel(
                        side: .bottom,
                        language: viewModel.bottomLanguage,
                        tint: .orange,
                        background: Color.orange.opacity(0.09)
                    )
                    .frame(height: max(0, sourcePanelHeight))
                }
            }

            Button {
                viewModel.swapLanguages()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 52)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(
                viewModel.state != .idle
                    || viewModel.topLanguage == nil
                    || viewModel.bottomLanguage == nil
            )
            .accessibilityLabel("Swap languages")
            .accessibilityIdentifier("swapLanguagesButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Text(viewModel.modelStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 8)
        }
        .padding(isCompactLandscape ? 8 : 12)
        .background(Color(uiColor: .systemBackground))
        .task {
            await viewModel.loadInstalledLanguages()
        }
        .onDisappear {
            viewModel.cancelCapture()
        }
    }

    private func languagePanel(
        side: TranscriptionViewModel.Side,
        language: Language?,
        tint: Color,
        background: Color
    ) -> some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: isCompactLandscape ? 5 : 9) {
                Text(side == .top ? "TARGET LANGUAGE" : "SOURCE LANGUAGE")
                    .font(.caption.bold())
                    .foregroundStyle(tint)

                Text(viewModel.text(for: side))
                    .font(
                        .system(
                            size: isCompactLandscape ? 24 : 34,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .accessibilityIdentifier(
                        side == .top ? "targetLanguageTextLabel" : "sourceLanguageTextLabel"
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            VStack(spacing: isCompactLandscape ? 5 : 14) {
                languageMenu(side: side, selection: language, tint: tint)
                if side == .bottom {
                    microphoneButton(tint: tint)
                    listeningIndicator(active: viewModel.isMicrophoneActive, tint: tint)
                } else {
                    targetOutputIndicator(tint: tint)
                }
            }
            .frame(width: isCompactLandscape ? 122 : 150)
        }
        .padding(.leading, isCompactLandscape ? 26 : 44)
        .padding(.trailing, isCompactLandscape ? 18 : 28)
        .padding(.vertical, isCompactLandscape ? 8 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            background,
            in: RoundedRectangle(
                cornerRadius: isCompactLandscape ? 24 : 34,
                style: .continuous
            )
        )
    }

    private func languageMenu(
        side: TranscriptionViewModel.Side,
        selection: Language?,
        tint: Color
    ) -> some View {
        Menu {
            if viewModel.installedLanguages.isEmpty {
                Text("No installed languages")
            } else {
                ForEach(viewModel.installedLanguages) { language in
                    Button {
                        viewModel.select(language, for: side)
                    } label: {
                        if language == selection {
                            Label(language.displayName(), systemImage: "checkmark")
                        } else {
                            Text(language.displayName())
                        }
                    }
                }
            }
        } label: {
            VStack(spacing: isCompactLandscape ? 2 : 5) {
                Image(systemName: "globe")
                    .font(isCompactLandscape ? .body : .title2)
                HStack(spacing: 5) {
                    Text(
                        selection?.displayName()
                            ?? (viewModel.isLoadingLanguages ? "Loading…" : "Select")
                    )
                    .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                }
            }
            .font(isCompactLandscape ? .subheadline.bold() : .headline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
        }
        .disabled(viewModel.state != .idle || viewModel.isLoadingLanguages)
        .accessibilityLabel("Select \(side == .top ? "top" : "bottom") language")
        .accessibilityIdentifier(side == .top ? "topLanguageSelector" : "bottomLanguageSelector")
    }

    private func microphoneButton(tint: Color) -> some View {
        let active = viewModel.isMicrophoneActive

        return Button {
            viewModel.toggleCapture()
        } label: {
            Image(systemName: active ? "stop.fill" : "mic.fill")
                .symbolRenderingMode(.monochrome)
                .font(
                    .system(
                        size: isCompactLandscape ? 19 : 25,
                        weight: .bold
                    )
                )
                .foregroundStyle(.white)
                .frame(
                    width: isCompactLandscape ? 44 : 60,
                    height: isCompactLandscape ? 44 : 60
                )
                .background(tint, in: Circle())
                .padding(isCompactLandscape ? 4 : 6)
                .background(tint.opacity(active ? 0.22 : 0.12), in: Circle())
                .overlay {
                    Circle()
                        .stroke(tint.opacity(0.28), lineWidth: 1)
                }
                .shadow(color: tint.opacity(0.2), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isMicrophoneEnabled)
        .opacity(viewModel.isMicrophoneEnabled ? 1 : 0.42)
        .accessibilityLabel(active ? "Stop listening" : "Speak source language")
        .accessibilityIdentifier("sourceLanguageMicrophoneButton")
    }

    private func targetOutputIndicator(tint: Color) -> some View {
        Image(systemName: "text.bubble.fill")
            .font(.system(size: isCompactLandscape ? 22 : 30, weight: .semibold))
            .foregroundStyle(tint)
            .frame(
                width: isCompactLandscape ? 52 : 76,
                height: isCompactLandscape ? 52 : 76
            )
            .padding(isCompactLandscape ? 6 : 10)
            .background(tint.opacity(0.1), in: Circle())
            .accessibilityLabel("Translation output")
            .accessibilityIdentifier("targetLanguageOutputIndicator")
    }

    private func listeningIndicator(active: Bool, tint: Color) -> some View {
        HStack(spacing: isCompactLandscape ? 5 : 7) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(tint.opacity(active ? 1 : 0.25))
                    .frame(
                        width: isCompactLandscape ? 5 : 7,
                        height: active && index == 3
                            ? (isCompactLandscape ? 14 : 22)
                            : (isCompactLandscape ? 5 : 7)
                    )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: active)
        .accessibilityHidden(true)
    }
}

#Preview("Landscape", traits: .landscapeLeft) {
    ContentView()
}
