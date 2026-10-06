# YouTube to MP3 for DaVinci Resolve

Paste YouTube links inside Resolve, convert them to MP3 (or WAV), and have them land in a
**YouTube Audio** bin in the Media Pool.

Only download audio you have the rights to use (your own uploads, royalty-free or Creative Commons tracks).

## Install

```bash
~/Documents/YTtoMP3/install.sh
```

This downloads and checksum-verifies the tools into `~/Library/Application Support/YTtoMP3/bin`
(yt-dlp from GitHub, Deno from dl.deno.land, ffmpeg/ffprobe from ffmpeg.martin-riedl.de) and copies
`YouTube to MP3.lua` into Resolve's `Fusion/Scripts/Utility` folder. Re-run it after editing the script.

## Use

1. In Resolve: **Workspace > Scripts > YouTube to MP3** (restart Resolve once if it isn't listed).
2. Paste one or more links (one per line), or click **Paste from Clipboard**.
3. Pick **MP3 - 320 kbps** or **WAV - 48 kHz** and click **Convert**.

Files are saved to `~/Music/Resolve YouTube Audio/<project name>/` by default. All audio is
resampled to 48 kHz to match video projects. Settings are remembered between runs.

## Updating

- **Update yt-dlp** button in the window: do this first whenever YouTube downloads start failing.
- `install.sh --update` re-downloads every tool at its latest version.

## Troubleshooting

- The log of the last run is at `~/Library/Application Support/YTtoMP3/last-log.txt`.
- **install.sh says it can't reach github.com**: GitHub only works over IPv4. If your Mac's IP address
  starts with 169.254 (common on busy public Wi-Fi), renew the DHCP lease or use another network.
- The plugin uses IPv4 whenever your Mac has it, because some networks reach YouTube over IPv6 but
  stall on its media servers.

## Uninstall

```bash
rm "$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/YouTube to MP3.lua"
```

```bash
rm -r "$HOME/Library/Application Support/YTtoMP3"
```
