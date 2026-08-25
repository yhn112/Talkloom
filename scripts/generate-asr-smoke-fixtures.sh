#!/usr/bin/env bash
# Generate the synthetic smoke fixtures described by the asr-eval skill. Audio remains
# ignored by git; only the human-reviewable reference text and this recipe are committed.
set -euo pipefail

cd "$(dirname "$0")/.."

for command in say ffmpeg; do
    if ! command -v "$command" >/dev/null; then
        echo "$command is missing — run brew bundle" >&2
        exit 127
    fi
done

voices=$(say -v '?')
for voice in Milena Samantha; do
    if ! grep -q "^$voice " <<<"$voices"; then
        echo "$voice voice is missing — install it in System Settings > Accessibility > Spoken Content" >&2
        exit 1
    fi
done

fixture_directory="Tests/fixtures"
mkdir -p "$fixture_directory"
scratch=$(mktemp -d /tmp/TranscriberASRFixtures.XXXXXX)
trap 'rm -rf "$scratch"' EXIT

say_wave() {
    local voice=$1
    local output=$2
    local text=$3
    say -v "$voice" --file-format=WAVE --data-format=LEI16@16000 -o "$output" "$text"
}

canonical_wave() {
    local input=$1
    local output=$2
    ffmpeg -hide_banner -loglevel error -y -i "$input" \
        -ar 16000 -ac 1 -c:a pcm_s16le "$output"
}

say_wave Milena "$scratch/ru.wav" \
    'Коллеги, давайте зафиксируем решение по архитектуре захвата звука.'
canonical_wave "$scratch/ru.wav" "$fixture_directory/ru_short.wav"

say_wave Samantha "$scratch/en.wav" \
    'Let us agree on the audio capture architecture before the next sprint.'
canonical_wave "$scratch/en.wav" "$fixture_directory/en_short.wav"

say_wave Milena "$scratch/mixed-ru-start.wav" 'Обсудим'
say_wave Samantha "$scratch/mixed-en.wav" 'API gateway and retry policy'
say_wave Milena "$scratch/mixed-ru-end.wav" 'завтра.'
ffmpeg -hide_banner -loglevel error -y \
    -i "$scratch/mixed-ru-start.wav" \
    -i "$scratch/mixed-en.wav" \
    -i "$scratch/mixed-ru-end.wav" \
    -filter_complex '[0:a][1:a][2:a]concat=n=3:v=0:a=1[out]' \
    -map '[out]' -ar 16000 -ac 1 -c:a pcm_s16le "$fixture_directory/mixed_short.wav"

say_wave Samantha "$scratch/pause-start.wav" 'The first decision is recorded.'
say_wave Samantha "$scratch/pause-end.wav" 'The second decision follows after the pause.'
ffmpeg -hide_banner -loglevel error -y \
    -i "$scratch/pause-start.wav" \
    -f lavfi -t 4 -i 'anullsrc=r=16000:cl=mono' \
    -i "$scratch/pause-end.wav" \
    -filter_complex '[0:a][1:a][2:a]concat=n=3:v=0:a=1[out]' \
    -map '[out]' -ar 16000 -ac 1 -c:a pcm_s16le "$fixture_directory/long_pause.wav"

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -t 5 -i 'anullsrc=r=16000:cl=mono' \
    -ar 16000 -ac 1 -c:a pcm_s16le "$fixture_directory/silence.wav"

echo "generated 5 synthetic ASR fixtures in $fixture_directory"
