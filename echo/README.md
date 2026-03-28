# Echo

Echo is a lightweight macOS menu bar dictation app.

Press `Cmd + Shift + Space`, speak, and Echo turns your voice into text and pastes it into the app you were already using.

## What it does

- Lives in the menu bar
- Shows a small floating recording pill
- Displays live audio activity
- Transcribes speech with Apple Speech
- Pastes the final text into the active app

## Current status

- Working now: menu bar app, hotkey, floating overlay, waveform, Apple Speech transcription, automatic paste
- Planned later: Deepgram, Mistral, and Parakeet local transcription

## Permissions

- `Microphone` - capture your voice
- `Speech Recognition` - transcribe speech
- `Accessibility` - automatically paste into the active app

Without Accessibility permission, Echo can still copy text to the clipboard, but it cannot paste automatically.

## Project structure

- `echo/echoApp.swift` - app entry point
- `echo/EchoCoordinator.swift` - main recording and transcription flow
- `echo/Models/` - app state
- `echo/Services/` - audio, hotkey, paste, and transcription logic
- `echo/Views/` - menu bar UI and overlay UI
- `echo/Windows/` - floating panel window code

## Run locally

1. Open `echo/echo.xcodeproj` in Xcode.
2. Build and run the `echo` target.
3. Grant macOS permissions when prompted.
4. Use `Cmd + Shift + Space` to start and stop dictation.

## Releases

The GitHub workflow publishes:

- a `.dmg` for normal downloads
- an `.app.zip` for the raw app bundle

This release flow is unsigned, so macOS may ask users to right-click the app and choose `Open` the first time.
