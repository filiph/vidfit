# Video Size Fitting

CLI tool that fits video files under a target byte size limit while preserving maximum visual quality and compatibility for social platforms.

## Language

**Budget**:
The maximum allowed output file size in bytes, derived from megabytes using decimal notation (1 MB = 1,000,000 bytes).
_Avoid_: File size cap, max payload, size quota

**Fast Path**:
Direct stream copy (remuxing) of compliant H.264/AAC media without re-encoding when the source file already fits within the budget.
_Avoid_: Passthrough, direct copy, stream bypass

**Re-encode**:
A two-pass video and audio encoding workflow that optimizes bitrates to maximize visual quality under the budget.
_Avoid_: Transcode, compression pass

**Target Height**:
The maximum vertical pixel resolution constraint applied to the output video without upscaling.
_Avoid_: Resolution cap, scale limit

**Auto Scale**:
Automatic selection of output resolution and framerate based on available bitrate, reducing framerate down to the minimum threshold before downscaling resolution to preserve visual clarity.
_Avoid_: Dynamic resolution, smart downscale

**Minimum Framerate**:
The lowest framerate permitted during auto-scaling before resolution downscaling begins (defaults to 30 fps).
_Avoid_: Min FPS cap, framerate floor

## Example Dialogue

> **Developer**: "When a user provides an existing H.264 video, does it always go through the **re-encode** workflow?"  
> **Domain Expert**: "No. If the video already fits within the **budget** and has compatible streams, it takes the **fast path** to avoid quality loss."  
> **Developer**: "And if the bitrate budget is too tight for a 60fps 1080p source?"  
> **Domain Expert**: "**Auto scale** will first lower the framerate down toward the **minimum framerate** (e.g. 30fps) to keep 1080p sharp before reducing the **target height**."
