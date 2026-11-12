# Scribe

A small, fast, private transcription app for the Mac. Drop in a video or audio file, or paste a link to a video, a playlist or a whole channel, and get a clean transcript with speaker labels. Everything runs on your Mac; nothing is uploaded.

![The start screen](docs/start.png)

## What it does

- **Any file:** video or audio in any format macOS or ffmpeg can read.
- **Any link:** YouTube and the many other sites [yt-dlp](https://github.com/yt-dlp/yt-dlp) supports.
- **Playlists and channels:** paste the link, choose how many, and they are transcribed one after another and saved as numbered text files.
- **Speaker labels:** who said what, as "Speaker 1", "Speaker 2" and so on.
- **A queue:** add more while one is running; go back and it keeps going.
- **Saved automatically:** every transcript lands in `~/Documents/Scribe` as a `.txt` file. You can also copy it or save subtitles (`.srt`).
- **Light:** the app is about 15 MB and idles at around 15–20 MB of memory. Each job runs in its own process that exits when done.

On an M1 Pro, a 17-minute two-person call takes about 15 seconds with speaker labels (roughly 65× real time) and peaks near 190 MB of memory.

| | |
|---|---|
| ![Transcribing](docs/working.png) | ![A transcript](docs/transcript.png) |
| ![A playlist in the queue](docs/queue.png) | |

## Requirements

- An Apple Silicon Mac (M1 or later)
- macOS 26 or later
- About 1.1 GB of disk for the speech models, downloaded once on first use
- [Homebrew](https://brew.sh) for links: `yt-dlp` (downloads) and `ffmpeg` (unusual formats). Local files in common formats work without them.

## Install

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/WHATDOESTHEFOXSAY2U/scribe/main/install.sh | sh
```

It downloads the latest release into `/Applications`, installs `yt-dlp` and `ffmpeg` with Homebrew if they are missing, and adds a `scribe` terminal command. [Read the script](install.sh) first if you like; it is short.

**Or by hand:** download `Scribe.zip` from the [latest release](https://github.com/WHATDOESTHEFOXSAY2U/scribe/releases/latest), unzip it and move `Scribe.app` to Applications. The app is not notarised by Apple, so the first time macOS will refuse to open it: go to System Settings › Privacy & Security and click **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Scribe.app`. Then `brew install yt-dlp ffmpeg` for links.

## Use

- Drop a file on the window, press **Choose File…**, or paste a link and press Return.
- For a playlist or channel, pick how many recordings to transcribe and where to save them.
- **Back** never stops a job. The pill at the bottom of the start screen takes you back to it.
- **Identify speakers** (bottom of the start screen) can be turned off for more speed on long recordings.

### From the terminal

```bash
scribe recording.mp4                      # prints the transcript
scribe "https://youtu.be/…" -o talk.txt   # saves it
scribe recording.mp4 --srt -o subs.srt    # subtitles
scribe recording.mp4 --timestamps         # a timestamp on every sentence
scribe recording.mp4 --no-speakers        # skip speaker labels
scribe recording.mp4 --fast               # skip the punctuation pass
```

## How it works

- **Words:** [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra), a 0.6B-parameter speech model, run through [FluidAudio](https://github.com/FluidInference/FluidAudio) on the Neural Engine. In a test against 86 minutes of human-transcribed conversational and accented English it had the lowest word error rate of eleven on-device models tried (9.4%), ahead of Whisper large-v3 (10.3%) at a small fraction of the time and memory.
- **Punctuation:** a second pass with Parakeet v2, whose punctuation and capitals are copied onto the first pass's words. The words themselves never change.
- **Speakers:** FluidAudio's offline diarizer (pyannote segmentation, WeSpeaker embeddings, VBx clustering).
- **Languages:** Parakeet Ultra covers 25 European languages. The punctuation pass is English-only and leaves other languages as the first pass wrote them. Other languages (Hindi, Chinese, Japanese, Arabic and so on) are not supported.

## Limits

- Speaker labels are sometimes wrong on very short turns, and recordings with many overlapping voices may get no labels.
- Names and jargon the model has not seen can be misheard.
- Sites that need a signed-in account (Vimeo, private or members-only videos) cannot be downloaded.

## Build from source

Needs Xcode 26 or later.

```bash
git clone https://github.com/WHATDOESTHEFOXSAY2U/scribe.git
cd scribe
./build.sh
```

`build.sh` builds a release binary, assembles `Scribe.app`, signs it ad hoc, installs it to `/Applications` and adds the `scribe` command.

The code is six Swift files in `Sources/Scribe`: `Engine.swift` (download, decode, recognition, speakers, formatting), `App.swift` (the window's state and the queue), `Views.swift` and `TranscriptView.swift` (the screens), `main.swift` (the command line), and `Snapshot.swift` (draws every screen to PNG files for checking the design: `scribe --snapshot <folder>`).

## Licence

Scribe's own code is under the [MIT licence](LICENSE). It depends on FluidAudio (Apache 2.0) and downloads speech and speaker models that carry their own licences; see their model pages. Scribe is an independent project and is not affiliated with any of them.

Only download and transcribe material you have the right to use.
