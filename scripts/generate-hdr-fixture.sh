#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/hdr
# Synthetic PQ code-value pattern, not SDR footage claimed to have been restored to HDR.
# Map the generated 10-bit luma into video-range PQ values, retaining lower two bits.
ffmpeg -hide_banner -loglevel warning -y -f lavfi \
  -i 'testsrc2=size=2560x1440:rate=60,format=yuv420p10le' -t 20 \
  -vf 'lutyuv=y=clip(val*0.77\,64\,724)' -an -c:v hevc_videotoolbox \
  -profile:v main10 -pix_fmt p010le -b:v 20M -tag:v hvc1 \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv \
  -movflags +faststart .build/hdr/pq60-pattern.mp4
# Set both HEVC VUI and container color metadata; this VT/ffmpeg combination omits some VUI tags.
ffmpeg -hide_banner -loglevel warning -y -i .build/hdr/pq60-pattern.mp4 -c copy \
  -bsf:v 'hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9' \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv \
  -tag:v hvc1 -movflags +faststart .build/hdr/pq60-reference.mp4
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,profile,width,height,pix_fmt,color_space,color_transfer,color_primaries,avg_frame_rate \
  -of json .build/hdr/pq60-reference.mp4
