#!/bin/zsh
# Final render: 1080p60 with adaptive motion blur, in three segments (resilient, resumable),
# concatenated losslessly, then muxed with the original audio.
#   zsh scripts/render-final.sh [--scale 2]
set -euo pipefail
cd "${0:A:h}/.."
OUT=../out/final
mkdir -p $OUT
EXTRA=("$@")
bounds=(0 10 20 30.854)
for i in 1 2 3; do
  seg=$OUT/seg$i.mp4
  [[ -s $seg ]] && { echo "skip $seg"; continue; }
  bun scripts/render.ts video --from ${bounds[$i]} --to ${bounds[$((i+1))]} --samples auto --shutter 0.2 \
    --noaudio --crf 14 --out $seg.part.mp4 "${EXTRA[@]}"
  mv $seg.part.mp4 $seg
done
printf "file 'seg1.mp4'\nfile 'seg2.mp4'\nfile 'seg3.mp4'\n" > $OUT/list.txt
ffmpeg -y -loglevel error -f concat -safe 0 -i $OUT/list.txt -i ../audio/glossy-loop.wav \
  -map 0:v -map 1:a -c:v copy -c:a aac -b:a 320k -shortest -movflags +faststart ../out/whisprgo-trailer.mp4
echo "wrote ../out/whisprgo-trailer.mp4"
