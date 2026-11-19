"""Check the delivered movie using ffprobe and decoded pixels. Python stdlib only."""
import argparse
import json
import subprocess


def probe(path):
    fields = "stream=codec_name,width,height,profile:frame=best_effort_timestamp_time"
    data = subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames",
        "-show_entries", fields, "-of", "json", path,
    ])
    result = json.loads(data)
    return result["streams"][0], [float(f["best_effort_timestamp_time"]) for f in result["frames"]]


def eye_disparities(frame):
    # Seek horizontal matches between eye images on textured 9x9 patches.
    # Reject near ties and low-contrast patches, including letterbox bars.
    shifts = []
    for y in range(12, 229, 20):
        for x in range(12, 389, 20):
            locations = [(y + dy) * 800 + x + dx for dy in (-4, -2, 0, 2, 4)
                         for dx in range(-4, 5)]
            left = [frame[p] for p in locations]
            if max(left) - min(left) < 30:
                continue
            costs = sorted((sum(abs(v - frame[p + 400 + shift]) for p, v in zip(locations, left)), shift)
                           for shift in range(-7, 8))
            if costs[1][0] - costs[0][0] > len(locations):
                shifts.append(costs[0][1])
    return shifts


def verify(source, output):
    _, original = probe(source)
    stream, converted = probe(output)
    if (stream["codec_name"], stream["width"], stream["height"]) != ("h264", 800, 240):
        raise ValueError(f"unexpected output format {stream}")
    if len(original) != len(converted) or not original:
        raise ValueError("input and output frame counts differ or are empty")
    maximum_error = max(abs(a - b) for a, b in zip(original, converted))
    if maximum_error > 0.001:
        raise ValueError(f"presentation timestamps diverge by {maximum_error} seconds")
    raw = subprocess.check_output([
        "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-i", output, "-an",
        "-vf", "fps=1/4,format=gray", "-f", "rawvideo", "-",
    ])
    size = 800 * 240
    shifts = []
    for offset in range(0, len(raw), size):
        shifts.extend(eye_disparities(raw[offset:offset + size]))
    nonzero = sum(d != 0 for d in shifts)
    if not nonzero:
        raise ValueError("no measurable horizontal disparity in sampled textured patches")
    print(json.dumps(dict(frames=len(converted), max_pts_error_ms=maximum_error * 1000,
                          profile=stream["profile"], sampled_frames=len(raw) // size,
                          confident_patches=len(shifts), nonzero_disparity_patches=nonzero,
                          horizontal_shift_range_px=[min(shifts), max(shifts)]), indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("output")
    args = parser.parse_args()
    verify(args.source, args.output)
