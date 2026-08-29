# WalkieTalkie Translation App — Implementation Plan

Status: **In progress — speech-to-text plus Indonesian translation demo**
Last updated: 2026-08-29  
Target: iOS/iPadOS 26.5+, SwiftUI, Swift 6-compatible concurrency

## 1. Goal

Build a privacy-first translation app with the core experience of Apple Translate:

- spoken audio → live source transcript → translated text;
- text-only translated output for the initial product;
- a two-person walkie-talkie/conversation mode;
- downloadable language resources and a clearly reported offline-ready state;
- replaceable service boundaries so Apple frameworks can later be swapped for or supplemented by providers such as ElevenLabs or another language model.

Apple's frameworks are the initial providers. Application features must depend on app-owned protocols and models, not directly on `Speech`, `Translation`, or `AVFAudio` types.

## 2. Current Project State

- `WalkieTalkie` now has a landscape-only, two-panel conversation UI with fixed roles: the orange bottom panel is always the speech source and owns the microphone, while the blue top panel is always the translation target. The blue target panel occupies 5/8 of the available height; both panels have installed-language selectors.
- The orange source prompt is dynamically translated from English into the selected source language when that offline Translation model is installed, with an English fallback when it is unavailable.
- Deployment target is iOS 26.5; the local toolchain is Xcode 26.6 with an iOS 26.5 simulator runtime.
- The app targets iPhone and iPad.
- The project now compiles in Swift 6 mode and includes a microphone privacy usage description.
- The first speech backend slice is implemented: provider-neutral audio/transcript contracts, Apple microphone capture, on-device `SpeechAnalyzer`/`SpeechTranscriber`, Speech asset status/download preparation, format conversion, finalization, and cancellation.
- The UI prepares the preferred supported language, starts/stops capture, renders partial/final transcript results, reports setup/errors in the same label, and cancels capture when dismissed.
- The provider-neutral voice pipeline emits original and translated text together. The UI discovers locally installed Speech assets, defaults the orange source panel to the device's preferred installed language, prefers Indonesian (`id`) as the blue target when it differs, and checks the selected Translation pair through `LanguageAvailability`; final transcripts are translated only when that direction's offline model is installed.
- Physical-device speech/translation verification, Translation model download UX, interruption/route handling, test targets, synthesis, and persistence remain pending.

## 3. Product Scope

### Core scope

1. Choose source and target languages and swap them.
2. Hold/tap to capture speech and show partial/final transcription.
3. Translate final utterances and display the translated text.
4. Keep speech synthesis behind a provider boundary for a later phase; it is not part of the initial output.
5. Run a two-sided conversation with manual turns.
6. Download/check the speech and translation resources needed for offline use.
7. Explain unavailable, unsupported, downloading, installed, denied-permission, and failed states.

### Apple Translate parity extensions

These are deliberately separate so they can be scheduled after the core:

- automatic conversation turn detection and auto-play;
- face-to-face rotated conversation layout;
- translation history, delete, favorites, copy/share, and full-screen display;
- speech playback speed and voice selection;
- language/meaning/gender alternatives where a provider exposes them;
- camera and photo-library text translation;
- cross-device favorites sync;
- accessibility and iPad-specific refinements;
- default-translation-app or system integration, if public APIs/entitlements permit it.

Out of scope unless explicitly selected: Phone/FaceTime interception, Messages integration, AirPods system Live Translation controls, accounts, a custom backend, and cloning Apple branding or pixel-perfect proprietary UI.

Typed source input is explicitly out of scope. Every user-originated translation request begins with captured speech.

## 4. Technical Direction

### App-owned domain types

Use small `Sendable`, framework-neutral value types:

- `Language`: stable BCP-47 identifier, display name, and optional region/script.
- `LanguagePair`: source and target.
- `TranscriptSegment`: text, final/partial state, optional timing, confidence, and detected language.
- `TranslationRequest` / `TranslationResult`: source, target, translated text, detected source, alternatives, and provider metadata.
- `ConversationTurn`: speaker side, source text, translated text, timestamps, and processing state.
- `LanguageResourceStatus`: unsupported, downloadable, downloading(progress), installed, failed.
- typed service errors suitable for user-facing recovery actions.

### Provider interfaces

Exact signatures should be finalized in the architecture phase, but the capability boundaries are:

```swift
protocol SpeechTranscribing: Sendable {
    func supportedLanguages() async -> [Language]
    func resourceStatus(for language: Language) async -> LanguageResourceStatus
    func prepare(language: Language) async throws
    func transcribe(_ audio: AsyncStream<AudioChunk>, language: Language) -> AsyncThrowingStream<TranscriptSegment, Error>
    func cancel() async
}

protocol TextTranslating: Sendable {
    func supportedLanguages() async -> [Language]
    func resourceStatus(for pair: LanguagePair) async -> LanguageResourceStatus
    func prepare(pair: LanguagePair) async throws
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
    func cancel() async
}

protocol SpeechSynthesizing: Sendable {
    func availableVoices(for language: Language) async -> [Voice]
    func speak(_ text: String, voice: Voice?, rate: SpeechRate) async throws
    func stop() async
}

protocol AudioCapturing: Sendable {
    func requestPermission() async -> Bool
    func start() async throws -> AsyncStream<AudioChunk>
    func stop() async
}
```

`AudioChunk` must be an app-owned transport type or a narrowly scoped adapter value. If retaining `AVAudioPCMBuffer` is materially better for real-time performance, isolate that dependency in the audio/Speech provider layer rather than leaking it into UI or feature models.

### Initial Apple-backed adapters

- `AppleSpeechTranscriber`: `SpeechAnalyzer` + `SpeechTranscriber`; use `DictationTranscriber` only as an explicit compatibility fallback when requirements allow it.
- `AppleTranslationService`: Translation framework `TranslationSession`, with `.lowLatency` as the deterministic offline-first default and an optional `.highFidelity` preference on supported Apple Intelligence devices.
- `AppleSpeechSynthesizer`: `AVSpeechSynthesizer` and installed `AVSpeechSynthesisVoice` values.
- `AppleAudioCaptureService`: `AVAudioEngine`/`AVAudioSession`, interruption handling, route changes, and microphone permission.
- `AppleLanguageResourceManager`: coordinates `Speech.AssetInventory`, Translation `LanguageAvailability`, and the user-mediated `prepareTranslation()` download flow.

Important constraint: translation-session acquisition/download is tied to Apple's Translation APIs and, for user-authorized downloads, SwiftUI's `translationTask`. Keep that lifecycle in a small adapter/coordinator so it does not shape the rest of the application.

### Dependency composition

Create one composition root at app launch:

```text
SwiftUI feature → feature model/coordinator → app protocols → selected provider adapters
```

Provider choice should be configuration, not branching throughout views. A future ElevenLabs adapter can implement speech synthesis/transcription while Apple Translation remains selected. Capabilities may therefore be chosen independently rather than through one monolithic “AI provider.”

### State and concurrency

- UI-facing feature models are `@MainActor` and use Observation.
- Stateful framework adapters are actors where appropriate.
- Each recording/translation session has one owner and structured child tasks.
- Cancellation is part of each protocol and occurs on language swap, new utterance, navigation, interruption, and app backgrounding.
- Conversation processing uses an explicit state machine (idle → preparing → listening → transcribing → translating → speaking → listening/idle; plus failure/cancelled states) to prevent double recording, stale results, and audio feedback loops.

### Persistence and privacy

- Keep raw microphone audio in memory only and discard it after transcription by default.
- Store history/favorites only if that phase is selected; use SwiftData behind a repository protocol.
- Provide a clear-history action and avoid logging transcript/translation content.
- No network provider is enabled in the Apple-only configuration. A future remote provider must disclose network use and credentials explicitly.

## 5. Selectable Implementation Phases

Phases have dependencies, but delivery order can vary where noted. Each phase should be its own reviewable checkpoint.

### Phase 0 — Project foundation

Dependencies: none  
Estimate: small

- Add feature/domain/provider folder structure and composition root.
- Define domain models, protocols, common errors, and mock providers.
- Add unit and UI test targets.
- Add microphone privacy usage description; add speech-recognition usage description only if the selected implementation/API requires it.
- Configure Swift concurrency checking and establish formatting/naming conventions.

Acceptance:

- App builds and launches on iPhone and iPad simulators.
- A feature model can run end-to-end with deterministic mock transcription, translation, and speech providers.
- No feature/domain type imports Apple speech/translation frameworks.

### Phase 1 — Transcript-to-translation vertical slice

Dependencies: Phase 0  
Estimate: medium

- Build source/target language selectors, swap action, transcript/result cards, loading/error/retry states, and copy.
- Implement the Apple Translation adapter and supported-language mapping.
- Accept only finalized speech transcripts as translation input.
- Guard same-language and unsupported-pair cases.

Acceptance:

- A finalized voice transcript can be translated, languages can be swapped, and the result can be copied.
- Stale requests cannot replace a newer result.
- Unsupported/not-installed states provide a meaningful next action.
- Mock-driven tests cover success, cancellation, failure, and rapid successive utterances.

### Phase 2 — Offline language resource management

Dependencies: Phase 0; integrate with Phase 1 and/or Phase 3 when present  
Estimate: medium

- Implement the unified resource manager for translation language pairs and speech locales.
- Add a Languages screen with supported, installed, downloadable, downloading, and failed states.
- Trigger Apple-controlled downloads with clear confirmation and progress where the APIs expose it.
- Reserve/release Speech assets within `AssetInventory.maximumReservedLocales` constraints.
- Distinguish “translation ready,” “transcription ready,” and “fully offline ready.”
- Add an offline-only preference that prevents future network-backed providers from being selected.

Acceptance:

- A selected pair is marked fully offline ready only when all selected capabilities are locally available.
- After resources are installed, text translation and speech transcription succeed with networking disabled on a physical supported device.
- App handles storage/download failure and resource eviction without crashing or falsely reporting readiness.

Note: model downloads and microphone behavior require physical-device verification; the simulator alone is insufficient evidence of offline support.

### Phase 3 — Speech-to-text input

Dependencies: Phase 0; Phase 2 recommended  
Estimate: large

- **Selected first:** implement the backend before its push-to-talk UI.
- Implement audio capture, audio format conversion, `SpeechAnalyzer`, `SpeechTranscriber`, and Speech asset preparation behind app-owned interfaces.
- Add first-use microphone permission UX and Settings recovery.
- Add push-to-talk/tap-to-talk controls, live partial transcript, finalization, cancel, audio-level feedback, interruption, and route handling.
- Feed only finalized utterances into translation by default; keep partial-translation experimentation behind a setting.

Acceptance:

- Supported on-device speech produces partial and final transcripts.
- Start/stop can be repeated without leaked taps/tasks or duplicated results.
- Denied permission, incoming interruption, route change, backgrounding, unsupported locale, and missing assets end in recoverable UI states.
- No captured audio is persisted or sent to a server by the Apple provider.

### Phase 4 — Speech synthesis (deferred)

Dependencies: Phase 0; not required for the initial text-output product
Estimate: small/medium

- Implement the Apple synthesizer adapter and installed-voice discovery.
- Play original or translated text; support stop and selected playback rates.
- Coordinate the audio session so synthesis never feeds back into active recognition.

Acceptance:

- Playback uses a voice matching the target language when available.
- Starting capture stops playback; starting playback suspends capture according to the conversation state machine.
- Missing voice and audio-route failures are surfaced cleanly.

### Phase 5 — Manual walkie-talkie conversation

Dependencies: Phases 1, 3, and 4; Phase 2 strongly recommended  
Estimate: large

- Build two participant panels, language controls, conversation turn timeline, and per-side push-to-talk.
- Transcribe → translate → display → optional auto-speak as one cancellable pipeline.
- Add retry, replay, copy, and clear-conversation actions.
- Preserve original and translated text for every turn during the session.

Acceptance:

- Either participant can hold/tap their control, speak, and receive the translated text/audio on the other side.
- Rapid turn changes never attribute text to the wrong participant.
- The pipeline works in airplane mode when both languages/resources are marked fully offline ready.

### Phase 6 — Automatic and face-to-face conversation

Dependencies: Phase 5  
Estimate: large/high risk

- Add voice-activity/end-of-utterance handling and automatic alternating turns.
- Add face-to-face layout with the remote side rotated 180 degrees.
- Add auto-play, pause/resume, and safeguards against speaker output being retranscribed.
- Tune silence thresholds and allow fallback to manual control in noisy environments.

Acceptance:

- A two-person scripted test completes multiple alternating turns without tapping for each turn.
- Speaker playback is not captured as a new participant utterance in supported routes/environments.
- Manual mode remains immediately available when automatic detection is unreliable.

### Phase 7 — History, favorites, sharing, and display polish

Dependencies: Phase 1; can run before conversation work  
Estimate: medium

- Add SwiftData repository, recent translations, favorites, delete/clear, copy/share, and full-screen “show someone” view.
- Add Dynamic Type, VoiceOver labels/actions, reduce-motion behavior, keyboard focus, landscape, and iPad layouts.
- Decide separately whether favorites need CloudKit sync.

Acceptance:

- Data survives relaunch, can be deleted, and contains no raw audio.
- Core flows pass accessibility inspection at large text sizes and with VoiceOver.

### Phase 8 — Camera/photo translation (optional parity)

Dependencies: Phases 1 and 2  
Estimate: very large

- Add camera permission and photo-picker flows.
- Create replaceable text-recognition and translated-overlay interfaces.
- Use Vision/VisionKit for text regions, translate recognized text, and render stable overlays.
- Support pause/capture, selecting a translated region, copy/favorite/listen, share, and save translated image.

Acceptance:

- Live camera and selected-photo text can be recognized and translated for supported pairs.
- Overlay positions remain aligned across orientation/zoom changes.
- All processing works offline when OCR and language resources support it.

### Phase 9 — Alternate provider integration (optional)

Dependencies: Phase 0 plus the relevant feature phase  
Estimate: provider-dependent

- Add provider configuration and capability reporting.
- Implement one adapter (for example, ElevenLabs synthesis) without changing feature views/models.
- Add secure credential storage, network reachability semantics, privacy disclosure, rate limits, cancellation, and usage/error mapping.
- Define deterministic fallback rules; never silently leave offline-only mode.

Acceptance:

- Provider can be changed through dependency composition/configuration.
- Existing Apple-provider tests continue passing.
- Offline-only mode never invokes a remote adapter.

## 6. Recommended Delivery Orders

Choose one; it is not assumed until approved.

### Option A — Voice-first MVP (selected direction)

`0 + speech backend from 3 → speech UI from 3 → 2 → 1 → 5`

This validates the on-device voice pipeline and provider seam first, then adds verified offline state, translation, and the walkie-talkie experience. Phase 4 remains deferred.

### Option B — Offline risk first

`0 → 2 → 3 → 1 → 5 → 4 (optional)`

This tackles model availability, downloads, and physical-device constraints before substantial UI work.

### Option C — Broad Apple Translate parity

`0 → 3 → 2 → 1 → 5 → 6 → 7 → 8 → 4 (optional) → 9`

This includes the major standalone Translate-app surfaces. Camera translation and alternative providers remain explicit checkpoints because of their size and risk.

## 7. Test and Verification Strategy

- Unit tests: language mapping, availability aggregation, state machine transitions, cancellation, stale-result suppression, provider fallback, and persistence.
- Contract tests: run the same behavioral suite against mocks and each provider adapter where feasible.
- Integration tests: Apple translation sessions, Speech asset state, live audio finalization, synthesizer lifecycle, and audio interruptions.
- UI tests: speak/transcribe/translate, language swap, permission denial, download prompt/status, push-to-talk, alternating turns, offline-state messaging, Dynamic Type, and VoiceOver identifiers.
- Manual physical-device matrix: Apple Intelligence capable/non-capable device if available; downloaded/not-downloaded pair; Wi-Fi/cellular/airplane mode; speaker/wired/Bluetooth routes; interruption/backgrounding; quiet/noisy rooms.
- Build gate after every phase: clean Debug build, unit tests, and selected UI smoke tests on iPhone and iPad simulators; device-only checklist for speech/offline phases.

## 8. Key Risks and Decisions Needed

1. **Parity boundary:** confirm whether camera, favorites/history, alternatives, and auto conversation are required for v1 or later.
2. **Minimum hardware:** decide whether to require `SpeechTranscriber`-capable devices or support `DictationTranscriber` fallback. The latter can change privacy/permission/offline guarantees and must not be silently enabled.
3. **Translation strategy:** `.lowLatency` is recommended for predictable offline behavior; decide whether users may opt into `.highFidelity` Apple Intelligence translation when available.
4. **Offline definition:** recommended definition is that transcription, translation, and synthesis resources for the selected pair are all locally ready—not merely that translation languages are downloaded.
5. **Conversation control:** manual push-to-talk is recommended for v1; automatic turn detection is a distinct higher-risk phase.
6. **Persistence:** decide whether history is device-local, whether favorites sync, and retention limits.
7. **Provider UX:** decide whether provider selection is user-facing initially or remains developer configuration until a second provider exists.
8. **Language breadth:** expose only the intersection required by the active capabilities, while showing which missing resource limits each language. Do not hard-code a marketing list.

## 9. Definition of Done for the Core App

The core is complete when Phases 0–5 are approved and delivered, and:

- voice transcription and transcript-to-text translation work for a supported selected pair;
- two participants can complete a manual walkie-talkie conversation;
- installed/downloadable/unsupported states are accurate and actionable;
- an airplane-mode physical-device test passes after all required resources are installed;
- Apple frameworks exist only behind app-owned interfaces;
- permissions, interruptions, cancellation, and failures recover without restart;
- tests cover the feature state machines and provider contracts;
- accessibility basics work on iPhone and iPad;
- raw audio and sensitive text are not logged, and raw audio is not persisted.

## 10. Reference APIs and Product Baseline

Primary Apple references used for this plan:

- SpeechAnalyzer: <https://developer.apple.com/documentation/speech/speechanalyzer>
- SpeechTranscriber: <https://developer.apple.com/documentation/speech/speechtranscriber>
- Speech AssetInventory: <https://developer.apple.com/documentation/speech/assetinventory>
- WWDC25 advanced speech-to-text session: <https://developer.apple.com/videos/play/wwdc2025/277/>
- TranslationSession: <https://developer.apple.com/documentation/translation/translationsession>
- LanguageAvailability: <https://developer.apple.com/documentation/translation/languageavailability>
- Translation strategy: <https://developer.apple.com/documentation/translation/translationsession/strategy>
- AVSpeechSynthesizer: <https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer>
- Apple Translate text/voice/conversation behavior: <https://support.apple.com/guide/iphone/translate-text-voice-and-conversations-iphd74cb450f/ios>
- Apple Translate camera behavior: <https://support.apple.com/guide/iphone/translate-with-the-camera-view-iphea8b95631/26/ios/26>

## 11. Approval Checkpoint

No additional implementation phase starts until the owner selects:

1. the phase(s) to implement next;
2. their order (or one recommended order above);
3. answers to any decision in Section 8 that affects the selected phase.
