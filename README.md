# sj-encode-pipeline

A hobbyist pipeline that re-encodes Blu-ray and UHD Blu-ray MKVs with NVIDIA's hardware HEVC
encoder. It scores every encode against its source with VMAF, picks the smallest one that
passes a quality bar, and finishes the file for a media server (Jellyfin naming): it rebuilds
the audio tracks, OCRs the subtitles, and handles Dolby Vision profile 7.

It's published as a worked example of how these problems were solved, not as a supported
tool. It's built for one setup: Windows, Windows PowerShell 5.1, an NVIDIA GPU, and WSL for
the Linux-only parts. Expect to read the scripts.

**Scope:** everything here starts from MKV files you already have. Nothing in this repository
reads discs or deals with copy protection.

It has the ability to encode multiple videos at a time, depending on your hardware. The RTX 4090 has 2 NVENC chips, so I do 2 at a time. Check your card before blindly using 2 like I do.

## FAQ

I'm starting with the FAQ first as I don't expect you to use my pipeline outright, this is meant to be a guide or tool to help you figure out how to do it your way.

### Windows AND WSL? Huh?

I know, I know. But the answer is easy: WSL's disk mapping layer is not up to the task here, even on NVME SSDs. Windows native allows direct access to the hardware and the better Nvidia drivers as well.

WSL is still needed for [dovi_convert](https://github.com/cryptochrome/dovi_convert) and libvmaf_cuda for ffmpeg. dovi_convert is end of life but I still have a use for it for inspection and doing simple converts of MELs. libvmaf_cuda allows for vmaf scoring using your gpu hardware (much, much quicker). It is a pain to get on Windows, so I use it in WSL instead.

### Why? Why not Tdarr/Handbrake/FastFlix?

I couldn't find a tool that did everything that was needed. I previously looked at [Tdarr](https://tdarr.io/) but felt it was limited in some areas, and I was running it on an Intel mini PC with QSV and I could easily tell how poor QSV was to NVENC with eyeball checks. I also didn't want to bog down my mini PC as it runs Jellyfin and also transcodes with QSV on demand.

[Handbrake](https://handbrake.fr/) and [FastFlix](https://github.com/cdgriffith/FastFlix) aren't really made for encoding batches when the content can vary file to file. Both are very limiting in terms of choosing audio tracks and the logic around that. So, I solved it myself here (see `Add-BluRayAudio.ps1`). They also don't do subtitles, and you'd still need Subtitle Edit in some fashion.

Credit where it is due, FastFlix helped me solve one component of how to do Dolby Vision with NVENC using [Rigaya's NVEncC](https://github.com/rigaya/NVEnc). Still needed to convert the profile first though, which FastFlix/Rigaya can't do. This pipeline can though!

## Why NVENC and not software encoding?

Search the internet and you'll find countless (aging or repeated) comments of "Hardware encoding bad, software only one true god". I did not find that the case. All of my NVENCs have been phenominal on quality and space savings (with some caveats on harder grainier film). I didn't do exhaustive testing, but the software encoding I did do came out with _larger_ files than with NVENC, while of course taking much, much longer.

That said, I'm sure NVENC has gotten better over time, and I'm only comparing with my RTX 4090. So I only have a newer version to test with, and I like the results and the speed. 

## Hurr durr VMAF sucks, use x instead

I have had zero problems with VMAF, nor has the entire publishing industry. There may be ways to improve scoring, but my bar is high enough that even those areas that could be improved are already caught by VMAF. Every single video issue I thought was an encoding issue turned out to exist on the source file or blu-ray. Every single one.

Unless you're seated very differently than VMAF expects, you won't notice it either. If you pixel peep or stand right next to your TV (don't), you can see the pixels that are different, but you'd be hard pressed to call it "bad". But again, at the couch, no difference to your meat-sac's eyes.

## Goals

### Speed > accuracy, but accuracy needs to be verified

Even if I ran two files through NVENC and software encoding and got them to have matching VMAF scores in an effort to see which filesize is better: it doesn't matter (to me). I have watched a lot of content ran through this pipeline and never have I noticed it was encoded. So it really comes down to filesize. **Even if software encoding produced smaller filesizes, I'd still take speed over that negligible difference.**

A single 4K movie can take over a day to encode with software (at leat with my CPU - AMD 7800X3D). This pipeline encodes multiple versions of each source to try to determine which quality level to choose. That could mean upwards of a week for a single film where I can't use the PC for anything else. Pass.

That's without even mentioning energy costs.

### Accuracy

Everything encoded must meet a defined quality bar. Here's what it looks like below.

It starts by targeting the bar. Generally, if a video meets the bar and is under 70% of the original video stream size, it is used. However, if it is well over the bar but not near the "target" 20%, it will lower the quality to get closer to 20% stream size. It still needs to pass the bar though, else it will choose the larger encode.

Further, if the video is well under the target of 20% and passing the bar, it'll encode it again at a _higher_ quality, increasing video stream size, until it gets closer to, but under, 20%. If it passes the "top bar" trying to get to 20%, it stops trying and uses the best encode still under 20%. This is a quality ceiling.

```
bar:
mean: >= 93.5
p1: >= 80
min: >= 75
video stream size: <= 70% of the source's
target: 20% stream size

top bar:
mean: >= 97
p1: >= 85
min: >= 80.
```

### Why a Mean of 93.5 and not 95?

Storage is (no longer) cheap. Simple as that. I also have not seen a good reason to increase it on my encodes. But you've probably read online that 95 is a good target for archival purposes. If you want 95, and have the storage needed to achieve it, then set it. You do you. My NAS just isn't as large as I'd like and it was still a small fortune.

Netflix says a score difference of 6 is noticeable by your eyes. That would mean 94 is a better target Mean. I may do that in the future but 93.5 has suited me well. And again, it's just a bar, the encode has to be _greater_ than that. They usually are 94+.

### Compatibility
1. Audio is re-organized so an AC3 5.1 track is always available and is the default (unless the masters are \<6 channels). Stereo-only masters will get either AC3 2.0 or AAC depending on if they are Dolby or other (DTS, LPCM, etc). See the Audio section below for more details.
1. Dolby Vision profile 7.6 are converted or baked to profile 8.1 depending on if they are MEL or either FEL.
1. Jellyfin support. This primarily means file naming is expected to match what they want, but also the generated subtitles are external files. It'll use the filenames you feed into it, but subtitles will has suffixes based on what Jellyfin expects.

### Audio
The logic at the moment flows something like this (may change in the future, see `Add-BluRayAudio.ps1` for most up-to-date practice):

Every audio track is inspected to determine what type of a track it is.
- Masters are defined by greatest number of channels and lossless-ness. But not all masters are lossless nor multi-channel.
  - Dolby TrueHD w/ Atmos and DTS:X Masters are preserved as-is (because object-based audio encoding is problematic for the moment without a Dolby license $$$).
  - Dolby TrueHD masters have an AC3 core that is used as the new default track (for compatibility). If that core is \<448 kbps, it is re-encoded from the master at 640 kbps (for 5.1). Dialog normalization metadata is left intact (copied).
  - Non-Dolby masters get a new AC3 track encoded for the default (again for compatibility).
  - DTS:HD (non-X) is left as-is for now, but may change in the future to Opus for space savings.
  - Stereo masters will get encoded to AAC (for compatibility) and set as the default track if no multi-channel master exists.
  - Any other lossless format (LPCM, etc) is also encoded to Opus as the "higher quality" track for devices that support Opus.
  - Multiple lossless masters are all kept (rare, but I've seen it), encoded or not based on the rules above.
  - Lossy masters are generally kept as is, but an AC3 track may be added (transcoded) if needed.
- Non-masters/lossy tracks are checked to determine what they are.
  - If a track is deemed to be a commentary track, it is kept and numbered sequentially for now (as it cannot determine what type of commentary it is).
  - Tracks not thought to be commentary tracks and also not a solo lossy master is discarded (not copied).

### Limitations

1. Subtitles are ran through Subtitle Edit's cli tool to do OCR with Paddle OCR. I've had the most luck with Paddle vs others while also being decently quick. But like all of them, it isn't perfect. I have some regex filters to fix common issues it has, but some I can't really fix safely. The most common issues are music symbols and leading multiple periods/ellipsis. If you end up seeing random "5", "J" or "JJ" in the middle of a song, it was probably a music symbol.
1. It tries its best to determine which subtitle belongs to which audio track, but this is actually harder than determining the audio tracks themselves! If it isn't confident, it'll ask you to choose and name the subtitle files correctly. In the future, I'd like to plan to use a lightweight AI model to determine which subtitle is which.

## TODO

1. Incorporate a local AI model to increase reliability in determining what a subtitle file is (main track, forced track, commentary, closed captioning, etc)
1. Incorporate another or the same local AI to determine what type of commentary track a track is- whether Director's or Filmmaker, actor(s), etc. If subtitles exist for the commentary tracks, they will need to be named the same.
1. Go full Linux. This will happen when I finally ditch windows. Soon™

## What's here

| Script | What it does |
|---|---|
| `Encode-Batch.ps1` | The orchestrator. For every source MKV under `-Source` it encodes a ladder of quality settings (or fixed variants), scores each with `compare_encode`, picks one, then finishes it: audio, subtitles, moving it into place, a report per folder. Resumable; keeps per-title logs. |
| `Encode-Video.ps1` | One NVEncC encode (crop, HDR10 / HDR10+ / Dolby Vision metadata). |
| `CropDetect.ps1` | Finds black bars (and soft, darkened edges) by sampling frames. |
| `Convert-DolbyVision.ps1` | Dolby Vision profile 7 to 8.1: converts an MEL, bakes an FEL's enhancement layer into the picture (VapourSynth + felbaker), keeps titles with no usable metadata as they are. |
| `Add-BluRayAudio.ps1` | Rebuilds an encode's audio from its source: keeps the lossless masters, adds a compatible default track (the TrueHD's AC-3 core, or a new AC-3 that copies its dialogue level and downmix settings), commentary tracks, Opus/AAC alternatives. |
| `Convert-Subtitles.ps1` | OCRs English PGS subtitles to SRT with Subtitle Edit's command line, sorting forced, full, SDH and commentary tracks into Jellyfin names. |
| `SE_Replace_Rules.template` | Subtitle Edit "multiple replace" rules that fix common OCR mistakes. Convert-Subtitles applies the copy next to it; edit it there (in Subtitle Edit: Tools > Multiple replace > Export). |
| `compare_encode.sh` | VMAF scoring in WSL (GPU via libvmaf_cuda when available), with automatic frame alignment: seek-offset and start-offset detection, and drift detection that bisects and scores in parts. |
| `Shared.ps1` | Loaded by every PowerShell script: the settings file and path handling. |
| `Encode-Batch.Common.ps1` | Helpers for Encode-Batch and its workers: logging, running programs and WSL, probing. |

The scripts are in `scripts/`. Each has full help: `Get-Help .\scripts\Encode-Batch.ps1 -Full`.

## Requirements

On Windows:

- Windows 10 or 11 with **Windows PowerShell 5.1** (PowerShell 7 works too).
- An NVIDIA GPU with NVENC HEVC, and [NVEncC](https://github.com/rigaya/NVEnc).
- [ffmpeg and ffprobe](https://ffmpeg.org/) on PATH.
- [MKVToolNix](https://mkvtoolnix.download/) (`mkvmerge`, `mkvextract`), on PATH or in its default folder.
- [MediaInfo CLI](https://mediaarea.net/en/MediaInfo) (optional; better Dolby Vision detection).
- Subtitles: [Subtitle Edit](https://github.com/SubtitleEdit/subtitleedit)'s command line (`seconv`) with PaddleOCR.
- Dolby Vision 7: [dovi_tool](https://github.com/quietvoid/dovi_tool), and [VapourSynth](https://www.vapoursynth.com/) with the ffms2 and felbaker plugins.

In WSL (any distribution):

- ffmpeg built with libvmaf (and, for GPU scoring, an ffmpeg built with libvmaf_cuda), and python3.
- `compare_encode.sh` on PATH as `compare_encode` (a symlink to the copy in this repository works, and keeps it next to the settings file).
- Dolby Vision 7: `dovi_convert`.

None of these are included here. Each has its own licence.

## Setup

1. Keep the `scripts` folder together. The scripts find each other (and `Shared.ps1`) next to themselves.
2. In `scripts`, copy `encode-settings.example.ini` to `encode-settings.ini` and fill in your paths (see below).
3. In WSL, link the scoring script onto PATH, for example:
   `ln -s /mnt/c/path/to/repo/scripts/compare_encode.sh ~/.local/bin/compare_encode`
4. Try one title first: `.\scripts\Encode-Batch.ps1 -Source 'S:\Sources\Movies\Movie (2001)' -Dest 'E:\Encodes'`

## Settings

`scripts\encode-settings.ini` (git-ignored) holds your machine's settings, so the scripts work without
long command lines. Set `ENCODE_SETTINGS` to keep it somewhere else. It's a plain INI file:

```ini
[All]
DoviTool = C:\Tools\dovi_tool\dovi_tool.exe
VsPipe = C:\Tools\vapoursynth-portable\vspipe.exe
SeConv = C:\Tools\SubtitleEdit\seconv.exe

[Encode-Batch]
Threads = 1

[compare_encode]
FFMPEG_CUDA = /opt/ffmpeg-cuda/bin/ffmpeg
```

- A key is a parameter's name. `[All]` applies to every script with that parameter, and a
  section named after a script applies only to it (and wins over `[All]`).
- A setting only fills in a parameter you didn't give; the command line always wins.
  Encode-Batch's log lists the settings it used.
- `[compare_encode]` is read by `compare_encode.sh` in WSL. Encode-Batch passes the file's
  location on, and when you run the script by hand it looks next to itself (following the
  symlink).
- Paths are only written the Windows way. WSL paths are worked out from the drive letter
  (`L:\Library` is `/mnt/l/Library`; see `WslMountRoot`).
- Per-run parameters (`Source`, `Dest`, `WorkDir`, ...) and hashtables (`-Ladder`, `-Variants`)
  can't be set here.

`encode-settings.example.ini` lists the useful keys.

## Network drives and WSL

Every WSL step first checks that the files it needs are visible there. If a drive's mount has
dropped (common with network drives), it's mounted again as root without a password prompt:
`wsl -u root mount -t drvfs X: /mnt/x`. Then the step runs again. Encode-Batch also checks
`-Source` and `-Dest` before it starts. To run your own mount command instead, set `RemountCmd`.

Mapped network drives belong to your Windows logon session. Run the scripts from a normal
(not elevated) PowerShell, or WSL won't be able to mount them.

## Paths with brackets

Library names usually contain brackets (`Movie (2001) [tmdbid-12345]`), and PowerShell's tab
completion escapes them with backticks (`` `[ ``, or `` ``[ `` inside double quotes). Every
script accepts a path either way.

## Why things are the way they are

Some choices look odd until you've hit the problem they solve:

- **`$ErrorActionPreference = 'Continue'` around native programs.** Under `'Stop'`, Windows
  PowerShell 5.1 turns anything a program writes to stderr into a terminating error, even a
  warning. The scripts check exit codes instead.
- **.NET file APIs (`[IO.File]::Exists`) instead of `Test-Path`.** Wildcard handling breaks on
  `[` and `]` in file names.
- **VMAF alignment.** Seeking in VC-1 and some MPEG-2 sources lands a frame or two away from
  where decoding from the start would, and some encodes gain or lose a frame partway through.
  `compare_encode` measures the shift at several points, checks the start by decoding from
  frame 0, and scores drifting files in parts.
- **Frame rates.** A DVD with soft pulldown is labelled 29.97 fps but holds 23.976 fps of
  frames. The real rate is measured (packet count / duration) rather than read from a label.
- **Dialogue normalization.** An AC-3 track tells the player how loud its dialogue is, and the
  player turns it down to match. ffmpeg writes "no adjustment" (-31 dB) by default, so a newly
  encoded track plays several dB louder than the disc's own tracks. Add-BluRayAudio copies the
  dialogue level (and downmix settings) from the AC-3 core or the TrueHD stream. That's also
  why, with `-LossyPerMaster`, a stereo TrueHD becomes AC-3 2.0, not AAC: ffmpeg's AAC encoder can't carry a dialogue
  level.

## Linting

```powershell
Invoke-ScriptAnalyzer -Path .\scripts -Settings .\PSScriptAnalyzerSettings.psd1
```

`PSScriptAnalyzerSettings.psd1` explains the rules it turns off. For the bash script:
`shellcheck scripts/compare_encode.sh`.

Keep the `.ps1` files ASCII-only. Windows PowerShell 5.1 reads a file without a BOM as the
system code page, so a stray non-ASCII character (a dash or a quote mark) can break it.

## Licence

MIT; see [LICENSE](LICENSE).
