#!/usr/bin/env bash
# Fetch the face ML models that the offline fork bundles in the APK.
# Run once on the build machine (needs internet). The app itself never
# downloads models. Files are verified against pinned sha256 values taken
# from rust/crates/ml/src/assets.rs.
set -euo pipefail

dest="$(cd "$(dirname "$0")/.." && pwd)/assets/ml_models"
mkdir -p "$dest"

fetch() {
    local name="$1" sha="$2"
    local out="$dest/$name"
    if [[ -f "$out" ]] && echo "$sha  $out" | shasum -a 256 -c - >/dev/null 2>&1; then
        echo "ok      $name"
        return
    fi
    echo "fetch   $name"
    curl -fL --retry 3 -o "$out.tmp" "https://models.ente.com/$name"
    echo "$sha  $out.tmp" | shasum -a 256 -c - >/dev/null
    mv "$out.tmp" "$out"
}

fetch yolov5s_face_640_640_static_b1.onnx e047647409403d52696035ecd445792173e50d7fbdcccac97b958a585db9aa3d
fetch mobilefacenet_portable_static_b1.onnx 0763fc33f54e138476194da95987e133b3e976075a6b1d3e1b2caedb251b1a36
