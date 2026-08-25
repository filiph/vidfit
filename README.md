# vidfit

Fit a video into given size (defaults to 20MB). Useful for sharing screencasts to socials.

## Install

```shell
$ ln -s ~/path/to/vidfit.sh ~/.local/bin/vidfit
```

## Usage

```shell
$ vidfit
usage: vidfit [options] <input> [output.mp4]

  -s, --size MB     hard limit, 1 MB = 1,000,000 B (default 20)
  -h, --height PX   downscale to height <= PX (aspect kept, never upscales)
  -A, --auto        pick height (and fps) automatically for the bit budget
      --fps N       cap frame rate at N
      --min-fps N   minimum frame rate for --auto before downscaling (default 30)
  -n, --no-audio    strip audio
      --ab KBPS     force audio bitrate (default: auto 48-128k)
      --preset P    x264 preset (default slow; try veryslow for small clips)
      --tol PCT     accept results down to PCT% below the limit (default 20)
      --tries N     max encode attempts (default 5)
  -v                show full ffmpeg output
```
