//
//  ContentView.swift
//  WalkieTalkie
//
//  Created by Alexey Shcherbak on 28/8/2026.
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = TranscriptionViewModel()

    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 20) {
                Text(viewModel.sourceLanguageText)
                    .font(.title2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .accessibilityLabel("Original text")
                    .accessibilityIdentifier("sourceLanguageTextLabel")

                Divider()

                Text(viewModel.targetLanguageText)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .accessibilityLabel("Indonesian translation")
                    .accessibilityIdentifier("targetLanguageTextLabel")
            }

            Button {
                viewModel.toggleCapture()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .background(
                        viewModel.isListening ? Color.red : Color.accentColor,
                        in: Circle()
                    )
                    .shadow(
                        color: (viewModel.isListening ? Color.red : Color.accentColor)
                            .opacity(0.3),
                        radius: 12,
                        y: 6
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.state == .finishing)
            .accessibilityLabel(viewModel.isListening ? "Stop listening" : "Start listening")
            .accessibilityIdentifier("microphoneButton")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            viewModel.cancelCapture()
        }
    }
}

#Preview {
    ContentView()
}
