#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <image-repository> <image-tag>" >&2
    exit 2
fi

echo
echo "Start build images, Repo: $1, Tag: $2"
echo
for dir in ts-*; do
    if [[ -d $dir ]]; then
        if [[ -n $(ls "$dir" | grep -i Dockerfile) ]]; then
            echo "build ${dir}"
            docker build -t "$1/${dir}:$2" "$dir"
        fi
    fi
done
