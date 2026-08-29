# WalkieTalkie — Missing Implementation

This document records the gaps between the current implementation and the scope described in [`plan.md`](plan.md). The app currently provides a bidirectional, manual offline speech-to-translated-text prototype; it is not yet the complete two-person walkie-talkie defined by the plan.

## Highest-priority product gaps

- There is no participant-turn model or conversation timeline.
- Translation model downloads cannot be initiated from the app.
- Offline readiness has not been verified on a physical device in airplane mode.
- There are no unit or UI test targets.

## Phase 0 — Project foundation

Implemented: app-owned domain models and protocols, provider folders, a composition root, Swift 6 configuration, and a microphone privacy description.

Missing:

- Deterministic mock transcription and translation providers.
- Unit and UI test targets.
- Provider contract tests.
- A more complete shared error model with user-facing recovery actions.
- Documented formatting and naming conventions.

## Phase 1 — Transcript-to-translation vertical slice

Implemented: language selectors, swap, final-transcript-only translation, same-language protection, resource checks, result display, and basic error messages.

Missing:

- Copy translated or source text.
- Retry actions for failed transcription or translation.
- Explicit loading and recoverable error UI instead of placing errors in the translation panel.
- Stale-request protection so an older asynchronous prompt/status request cannot overwrite newer state.
- Tests for success, cancellation, failure, and rapid successive utterances.

## Phase 2 — Offline language resources

Implemented: queries for Speech asset status and Translation pair availability; a spoken-language Speech model-management sheet combining `SpeechTranscriber` with `DictationTranscriber` fallback coverage; Speech asset download/preparation; per-model operation state and errors; and app reservation release for installed Speech assets.

Missing:

- Translated-to-language model selection and resource-management UI; its selector currently reports "Not implemented."
- Translation model download using the Apple-controlled `translationTask`/`prepareTranslation()` lifecycle.
- Translation download confirmation, progress, failure, retry, and storage-error states.
- Speech download byte/progress reporting where Apple exposes it, plus explicit UI for the installed-locale limit.
- A unified distinction between transcription-ready, translation-ready, and fully-offline-ready.
- Handling for resource eviction after initial selection.
- An offline-only preference for future provider selection.
- Physical-device verification with networking disabled.

## Phase 3 — Speech-to-text input

Implemented: microphone permission request, audio capture, mono conversion, `SpeechAnalyzer`, partial/final transcription, tap-to-toggle finalization, per-side capture handoff, and cancellation.

Missing:

- A Settings recovery action after microphone permission is denied.
- Real microphone-level feedback; the pulsing microphone glow currently shows recording state rather than measured input level.
- Audio interruption handling, including incoming calls and system interruptions.
- Audio route-change handling for speaker, wired, and Bluetooth devices.
- Explicit app background/foreground handling.
- Recovery UI for unsupported locales and missing/evicted assets.
- Repeated start/stop and leak/duplicate-result tests.
- Physical-device microphone and transcription verification.

## Phase 4 — Speech synthesis

Not implemented:

- An app-owned speech-synthesis protocol and Apple adapter.
- Playback of translated or original text.
- Voice discovery and target-language voice selection.
- Playback speed selection and stop control.
- Audio-session coordination to prevent playback from feeding into recognition.
- Missing-voice and route-failure handling.

## Phase 5 — Manual walkie-talkie conversation

Implemented: two participant panels, per-side tap-to-toggle microphones, bidirectional transcription/translation, and a single-active-microphone handoff that finalizes the current utterance before switching sides.

Missing:

- A participant/side associated with every captured turn.
- A conversation-turn domain model and in-session timeline.
- Automated coverage for rapid alternation and participant attribution.
- Per-turn original and translated text preservation.
- Retry, replay, copy, and clear-conversation actions.
- Optional translated speech playback.
- Airplane-mode end-to-end conversation verification.

## Later plan phases

The following planned extensions are not implemented:

- Automatic turn and end-of-utterance detection.
- Face-to-face layout with the remote side rotated 180 degrees.
- Auto-play and feedback-loop safeguards.
- Translation history and favorites.
- Delete, clear, copy/share, and full-screen display flows.
- Persistence and optional cross-device sync.
- Camera and photo-library text translation.
- Alternate speech, translation, or synthesis providers.
- Provider selection, credentials, network disclosure, and fallback rules.

## Architecture and implementation gaps

- `AppleTextTranslator.cancel()` is a no-op, so Translation work is not actively cancelled at the provider boundary.
- A new `TranslationSession` is created for each translation rather than managed through a dedicated session/download coordinator.
- The feature state has only idle, preparing, listening, and finishing states; it does not implement the plan's full conversation state machine.
- Cancellation occurs on view disappearance, but interruption, route-change, backgrounding, language-change-during-work, and new-utterance behavior are not comprehensively coordinated.
- There is no persistence layer, although this is acceptable until history/favorites are selected.
- Accessibility identifiers and basic labels exist, but Dynamic Type, VoiceOver behavior, reduced motion, and iPad resizing still need explicit verification.

## Definition-of-done gaps

The core definition of done in `plan.md` remains unmet because:

- Two participants cannot complete a manual walkie-talkie conversation without repeatedly swapping fixed source/target roles.
- Translation model states are reported but are not yet actionable inside the app.
- Airplane-mode physical-device testing has not passed.
- Interruption and permission failures do not all provide complete recovery paths.
- Feature state machines and provider contracts have no automated test coverage.
- Accessibility has not been verified across supported iPhone and iPad layouts.
