# Echo

<p align="center">
  <img src="docs/icon.png" width="160" alt="Echo">
</p>

Menu-bar dictation for Mac. Press the shortcut, speak, press again. Echo transcribes and pastes into the app you were using.

Requires macOS 26.3 (Tahoe). Apple Speech is on-device. Whisper, Parakeet, and S1-mini are optional local models.

## Engines

- **Apple Speech** — default
- **Whisper** — WhisperKit (Tiny / Base / Small English, Large v3 Turbo)
- **Parakeet** — FluidAudio TDT (English v2, multilingual v3)
- **Deepgram / Mistral** — optional cloud, API key required

Optional rewrite (Apple Intelligence or S1-mini) is off the paste path. Models download to `~/Library/Application Support/Echo/Models`.

## Run

Open `~/Applications/echo.app`, or build and install a fresh Release build:

```sh
./scripts/install-release.sh
```

Always ship Release. The Debug product is a small stub around an unoptimised dylib and it bundles
the test frameworks, which makes every hot path several times slower and pages in badly after the
app has been sitting idle.

To build without installing, from `echo/`:

```sh
xcodebuild -scheme echo -configuration Release -destination 'platform=macOS'
```

Default shortcut is ⌘⇧Space. Change it in Settings.

## Permissions

Microphone. Speech Recognition for Apple. Accessibility to paste (otherwise the transcript stays on the clipboard). Echo does not capture or record the screen.

Settings can hide the menu bar extra or the Dock icon. The shortcut still works.

## Latency

Echo logs what each take cost. To see it:

```sh
log show --predicate 'subsystem == "echo"' --last 1h --style compact
```

`hotkey→chip` is the overlay appearing, `stop→transcript` is recognition, and `stop→paste` is what
you actually wait for. Stats in Settings shows the same two figures averaged.

Apple Speech transcribes while you talk, so stop → paste does not grow with how long you spoke. If
a take ever comes back wrong, `defaults write com.fuadnafiz98.echo echo.appleBatchFallback -bool YES`
restores the old transcribe-after-stop behaviour.
