#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
scratch_dir="$project_dir/.build-cli-release"
output_path="$project_dir/dist/onisplit"

swift build \
    --package-path "$project_dir" \
    --scratch-path "$scratch_dir" \
    --configuration release \
    --product onisplit

mkdir -p "$project_dir/dist"
cp "$scratch_dir/release/onisplit" "$output_path"
codesign --force --sign - "$output_path"

echo "Built $output_path"
