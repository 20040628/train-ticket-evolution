#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <image-repository> <image-tag>" >&2
    exit 2
fi

echo
echo "Start pushing images tagged $2 (using the current Docker login)"
echo
for dir in ts-*; do
    if [[ -d "$dir" ]] && find "$dir" -maxdepth 1 -iname 'Dockerfile' -print -quit | grep -q .; then
        docker push "$1/${dir}:$2"
    fi
done
