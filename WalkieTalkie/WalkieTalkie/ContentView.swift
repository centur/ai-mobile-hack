import SwiftUI
@preconcurrency import Translation
import UIKit

struct ContentView: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var viewModel = TranscriptionViewModel()
    @State private var isSpeechModelManagerPresented = false
    @State private var isTranslationModelManagerPresented = false

    private var isCompactLandscape: Bool {
        verticalSizeClass == .compact
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = isCompactLandscape ? 8 : 12
            let translatedToPanelHeight = proxy.size.height * 0.625
            let spokenPanelHeight = proxy.size.height - translatedToPanelHeight - spacing

            ZStack(alignment: .topLeading) {
                VStack(spacing: spacing) {
                    languagePanel(
                        role: .translatedTo,
                        language: viewModel.translatedToLanguage,
                        tint: .blue,
                        background: Color.blue.opacity(0.09)
                    )
                    .frame(height: translatedToPanelHeight)

                    languagePanel(
                        role: .spoken,
                        language: viewModel.spokenLanguage,
                        tint: .orange,
                        background: Color.orange.opacity(0.09)
                    )
                    .frame(height: max(0, spokenPanelHeight))
                }

                Button {
                    viewModel.swapLanguages()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(
                            .system(
                                size: isCompactLandscape ? 15 : 18,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(.primary)
                        .frame(
                            width: isCompactLandscape ? 38 : 44,
                            height: isCompactLandscape ? 38 : 44
                        )
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(
                    viewModel.state != .idle
                        || viewModel.translatedToLanguage == nil
                        || viewModel.spokenLanguage == nil
                )
                .position(
                    x: proxy.size.width / 2,
                    y: translatedToPanelHeight + (spacing / 2)
                )
                .accessibilityLabel("Swap spoken and translated-to languages")
                .accessibilityHint("Updates speech recognition and translation languages")
                .accessibilityIdentifier("swapLanguagesButton")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(isCompactLandscape ? 8 : 12)
        .background(Color(uiColor: .systemBackground))
        .task {
            await viewModel.loadInstalledLanguages()
        }
        .onDisappear {
            viewModel.cancelCapture()
        }
        .sheet(isPresented: $isSpeechModelManagerPresented) {
            SpeechModelManagerView(viewModel: viewModel)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $isTranslationModelManagerPresented) {
            TranslationModelManagerView(viewModel: viewModel)
                .presentationDetents([.large])
        }
    }

    private func languagePanel(
        role: TranscriptionViewModel.LanguageRole,
        language: Language?,
        tint: Color,
        background: Color
    ) -> some View {
        HStack(spacing: 28) {
            languageText(role: role)

            VStack(spacing: isCompactLandscape ? 5 : 14) {
                languageMenu(role: role, selection: language, tint: tint)
                microphoneButton(role: role, tint: tint)
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

    @ViewBuilder
    private func languageText(role: TranscriptionViewModel.LanguageRole) -> some View {
        if role == .translatedTo {
            AutoScrollingPanelText(
                text: viewModel.text(for: role),
                fontSize: isCompactLandscape ? 36 : 52,
                weight: .black
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("translatedToLanguageTextLabel")
        } else {
            AutoScrollingPanelText(
                text: viewModel.text(for: role),
                fontSize: isCompactLandscape ? 20 : 34,
                weight: .regular
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("spokenLanguageTextLabel")
        }
    }

    @ViewBuilder
    private func languageMenu(
        role: TranscriptionViewModel.LanguageRole,
        selection: Language?,
        tint: Color
    ) -> some View {
        if role == .translatedTo {
            let languages = viewModel.languages(for: role)

            Menu {
                if languages.isEmpty {
                    Text("No supported languages")
                } else {
                    ForEach(languages) { language in
                        Button {
                            viewModel.select(language, for: role)
                        } label: {
                            if language == selection {
                                Label(languageMenuItemTitle(language), systemImage: "checkmark")
                            } else {
                                Text(languageMenuItemTitle(language))
                            }
                        }
                    }
                }

                Divider()

                Button {
                    isTranslationModelManagerPresented = true
                } label: {
                    Label("Download models for offline use", systemImage: "arrow.down.circle")
                }
            } label: {
                languageMenuLabel(selection: selection, tint: tint)
            }
            .disabled(
                viewModel.state != .idle
                    || viewModel.isLoadingLanguages
                    || viewModel.spokenLanguage == nil
            )
            .accessibilityLabel("Translated-to language selector")
            .accessibilityValue(selection?.displayName() ?? "No language selected")
            .accessibilityIdentifier("translatedToLanguageSelector")
        } else {
            let languages = viewModel.languages(for: role)

            Menu {
                if languages.isEmpty {
                    Text("No installed languages")
                } else {
                    ForEach(languages) { language in
                        Button {
                            viewModel.select(language, for: role)
                        } label: {
                            if language == selection {
                                Label(languageMenuItemTitle(language), systemImage: "checkmark")
                            } else {
                                Text(languageMenuItemTitle(language))
                            }
                        }
                    }
                }

                Divider()

                Button {
                    isSpeechModelManagerPresented = true
                } label: {
                    Label("Download models for offline use", systemImage: "arrow.down.circle")
                }

                Divider()

                Menu {
                    ForEach([0.5, 1.0, 1.5, 2.0, 3.0, 5.0], id: \.self) { seconds in
                        Button {
                            viewModel.setSilenceDuration(seconds: seconds)
                        } label: {
                            let duration = seconds.formatted(
                                .number.precision(.fractionLength(1))
                            )
                            if seconds == viewModel.silenceDurationSeconds {
                                Label("\(duration) seconds", systemImage: "checkmark")
                            } else {
                                Text("\(duration) seconds")
                            }
                        }
                    }
                } label: {
                    let duration = viewModel.silenceDurationSeconds.formatted(
                        .number.precision(.fractionLength(1))
                    )
                    Label("Translate after \(duration)s silence", systemImage: "timer")
                }
            } label: {
                languageMenuLabel(selection: selection, tint: tint)
            }
            .disabled(viewModel.state != .idle || viewModel.isLoadingLanguages)
            .accessibilityLabel("Select spoken language")
            .accessibilityValue(selection?.displayName() ?? "No language selected")
            .accessibilityIdentifier("spokenLanguageSelector")
        }
    }

    private func languageMenuLabel(selection: Language?, tint: Color) -> some View {
        VStack(spacing: isCompactLandscape ? 2 : 5) {
            if let selection {
                Text(selection.flagEmoji)
                    .font(isCompactLandscape ? .title3 : .title)
                    .accessibilityHidden(true)

                HStack(spacing: 5) {
                    Text(selection.twoLetterCode)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                }
            } else {
                Image(systemName: "globe")
                    .font(isCompactLandscape ? .body : .title2)

                HStack(spacing: 5) {
                    if viewModel.isLoadingLanguages {
                        Text("…")
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                }
            }
        }
        .font(isCompactLandscape ? .subheadline.bold() : .headline)
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
    }

    private func languageMenuItemTitle(_ language: Language) -> String {
        "\(language.flagEmoji) \(language.displayName())"
    }

    private func microphoneButton(
        role: TranscriptionViewModel.LanguageRole,
        tint: Color
    ) -> some View {
        let active = viewModel.isMicrophoneActive(for: role)

        return Button {
            viewModel.toggleCapture(for: role)
        } label: {
            microphoneIcon(tint: tint, active: active)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isMicrophoneEnabled(for: role))
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityLabel(
            active
                ? "Stop listening"
                : "Speak \(role == .translatedTo ? "translated-to" : "spoken") language"
        )
        .accessibilityHint(active ? "Tap to stop and translate" : "Tap to start recording")
        .accessibilityIdentifier(
            role == .translatedTo
                ? "translatedToLanguageMicrophoneButton"
                : "spokenLanguageMicrophoneButton"
        )
    }

    private func microphoneIcon(tint: Color, active: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let pulse = active ? (sin(elapsed * .pi * 2 / 0.9) + 1) / 2 : 0

            Image(systemName: "mic.fill")
                .symbolRenderingMode(.monochrome)
                .font(
                    .system(
                        size: isCompactLandscape ? 28 : 37,
                        weight: .black
                    )
                )
                .foregroundStyle(.white)
                .frame(
                    width: isCompactLandscape ? 54 : 72,
                    height: isCompactLandscape ? 54 : 72
                )
                .background(tint, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                }
                .padding(isCompactLandscape ? 8 : 11)
                .background(tint.opacity(active ? 0.22 : 0.12), in: Circle())
                .overlay {
                    Circle()
                        .fill(tint.opacity(active ? 0.12 + (0.10 * pulse) : 0))
                        .scaleEffect(1 + (0.18 * pulse))
                }
                .overlay {
                    Circle()
                        .stroke(tint.opacity(active ? 0.85 * (1 - pulse) : 0), lineWidth: 4)
                        .scaleEffect(1 + (0.24 * pulse))
                }
                .scaleEffect(1 + (active ? 0.045 * pulse : 0))
                .shadow(
                    color: tint.opacity(active ? 0.35 + (0.35 * pulse) : 0.16),
                    radius: active ? 9 + (12 * pulse) : 3,
                    y: active ? 0 : 1
                )
        }
    }
}

private struct AutoScrollingPanelText: View {
    private static let bottomAnchor = "panel-text-bottom"
    private static let visibleLineCount: CGFloat = 4

    let text: String
    let fontSize: CGFloat
    let weight: Font.Weight

    private var lineHeight: CGFloat {
        let uiWeight: UIFont.Weight = weight == .black ? .black : .regular
        let systemFont = UIFont.systemFont(ofSize: fontSize, weight: uiWeight)
        let descriptor = systemFont.fontDescriptor.withDesign(.rounded)
            ?? systemFont.fontDescriptor
        return UIFont(descriptor: descriptor, size: fontSize).lineHeight
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(
                            .system(
                                size: fontSize,
                                weight: weight,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
            }
            .frame(height: lineHeight * Self.visibleLineCount)
            .scrollIndicators(.hidden)
            .onChange(of: text, initial: true) {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }
}

private struct TranslationModelManagerView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: TranscriptionViewModel

    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoadingTranslationModels && viewModel.translationModels.isEmpty {
                    ProgressView("Loading Translation models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.translationModels.isEmpty {
                    ContentUnavailableView(
                        "No Translation Models Available",
                        systemImage: "character.book.closed",
                        description: Text("No translations are supported from the selected spoken language.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(viewModel.translationModels) { model in
                                translationModelRow(model)
                            }
                        } footer: {
                            Text("Translation downloads require system confirmation. Apple requires downloaded Translation models to be removed in Settings.")
                        }
                    }
                    .refreshable {
                        await viewModel.loadTranslationModels()
                    }
                }
            }
            .navigationTitle("Offline Translation Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .disabled(viewModel.translationModelOperationLanguage != nil)
                }
            }
        }
        .task {
            await viewModel.loadTranslationModels()
        }
        .translationTask(configuration) { session in
            guard let language = viewModel.translationModelOperationLanguage else { return }

            let preparationError: Error?
            do {
                try await session.prepareTranslation()
                preparationError = nil
            } catch {
                preparationError = error
            }

            // The system download sheet is a remote view service. Mutating this
            // view while it is dismissing can interrupt that service (Translation
            // error 14), so let its dismissal transaction finish first.
            try? await Task.sleep(for: .milliseconds(500))

            if let preparationError {
                await viewModel.failTranslationModelDownload(
                    language,
                    error: preparationError
                )
            } else {
                await viewModel.finishTranslationModelDownload(language)
            }

        }
        .interactiveDismissDisabled(viewModel.translationModelOperationLanguage != nil)
        .alert(
            "Translation Models",
            isPresented: Binding(
                get: { viewModel.translationModelManagerMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.clearTranslationModelManagerMessage()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.clearTranslationModelManagerMessage()
            }
        } message: {
            Text(viewModel.translationModelManagerMessage ?? "")
        }
    }

    private func translationModelRow(_ model: TranslationModelResource) -> some View {
        HStack(spacing: 12) {
            Text(model.status == .installed ? "🟢" : "🟡")
                .accessibilityHidden(true)

            Text(model.language.displayName())
                .frame(maxWidth: .infinity, alignment: .leading)

            action(for: model)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func action(for model: TranslationModelResource) -> some View {
        if viewModel.translationModelOperationLanguage == model.language {
            ProgressView()
                .accessibilityLabel("Downloading \(model.language.displayName())")
        } else if model.status == .installed {
            Button {
                viewModel.showTranslationModelRemovalInstructions(for: model.language)
            } label: {
                Text("⛔")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Show removal instructions for \(model.language.displayName()) translation model")
        } else {
            Button {
                requestDownload(of: model.language)
            } label: {
                Text("⬇️")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download \(model.language.displayName()) translation model")
        }
    }

    private func requestDownload(of language: Language) {
        guard let spokenLanguage = viewModel.spokenLanguage else { return }
        viewModel.beginTranslationModelDownload(language)
        guard viewModel.translationModelOperationLanguage == language else { return }

        let nextConfiguration = TranslationSession.Configuration(
            source: Locale.Language(identifier: spokenLanguage.identifier),
            target: Locale.Language(identifier: language.identifier),
            preferredStrategy: .lowLatency
        )
        if configuration == nextConfiguration {
            configuration?.invalidate()
        } else {
            configuration = nextConfiguration
        }
    }
}

private struct SpeechModelManagerView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: TranscriptionViewModel

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoadingSpeechModels && viewModel.speechModels.isEmpty {
                    ProgressView("Loading Speech-to-Text models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.speechModels.isEmpty {
                    ContentUnavailableView(
                        "No Speech Models Available",
                        systemImage: "waveform.slash",
                        description: Text("On-device speech transcription is unavailable on this device.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(viewModel.speechModels) { model in
                                speechModelRow(model)
                            }
                        } footer: {
                            Text("Removing releases this app’s model reservation. iOS deletes shared model data later when it is no longer in use.")
                        }
                    }
                    .refreshable {
                        await viewModel.loadSpeechModels()
                    }
                }
            }
            .navigationTitle("Offline Speech Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .disabled(viewModel.speechModelOperationLanguage != nil)
                }
            }
        }
        .task {
            await viewModel.loadSpeechModels()
        }
        .interactiveDismissDisabled(viewModel.speechModelOperationLanguage != nil)
        .alert(
            "Speech Models",
            isPresented: Binding(
                get: { viewModel.speechModelManagerMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.clearSpeechModelManagerMessage()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.clearSpeechModelManagerMessage()
            }
        } message: {
            Text(viewModel.speechModelManagerMessage ?? "")
        }
    }

    private func speechModelRow(_ model: SpeechModelResource) -> some View {
        HStack(spacing: 12) {
            Text(model.status == .installed ? "🟢" : "🟡")
                .accessibilityHidden(true)

            Text(model.language.displayName())
                .frame(maxWidth: .infinity, alignment: .leading)

            action(for: model)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func action(for model: SpeechModelResource) -> some View {
        if viewModel.speechModelOperationLanguage == model.language
            || model.status == .downloading {
            ProgressView()
                .accessibilityLabel("Updating \(model.language.displayName())")
        } else if model.status == .installed {
            Button {
                Task {
                    await viewModel.removeSpeechModel(model.language)
                }
            } label: {
                Text("⛔")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(model.language.displayName()) speech model")
        } else {
            Button {
                Task {
                    await viewModel.downloadSpeechModel(model.language)
                }
            } label: {
                Text("⬇️")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download \(model.language.displayName()) speech model")
        }
    }
}

#Preview("Landscape", traits: .landscapeRight) {
    ContentView()
}
