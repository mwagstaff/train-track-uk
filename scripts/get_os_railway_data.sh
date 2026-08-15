#!/bin/bash

# Check for the existence of the OS_API_KEY environment variable
if [ -z "$OS_API_KEY" ]; then
    echo "Error: OS_API_KEY environment variable is not set."
    exit 1
fi

BASE="https://api.os.uk/features/ngd/ofa/v1"
BBOX="-0.25,51.35,0.05,51.55"
LIMIT=100

download_collection() {
    COLLECTION="$1"
    OUTPUT="$2"

    offset=0
    echo '{"type":"FeatureCollection","features":[]}' > "$OUTPUT"

    while true; do
        echo "Downloading $COLLECTION offset=$offset"

        RESPONSE=$(curl -s \
            -H "key: $OS_API_KEY" \
            "$BASE/collections/$COLLECTION/items?bbox=$BBOX&limit=$LIMIT&offset=$offset")

        COUNT=$(echo "$RESPONSE" | jq '.features | length')

        jq -s \
          '.[0].features += .[1].features | .[0]' \
          "$OUTPUT" <(echo "$RESPONSE") \
          > "$OUTPUT.tmp"

        mv "$OUTPUT.tmp" "$OUTPUT"

        if [ "$COUNT" -lt "$LIMIT" ]; then
            break
        fi

        offset=$((offset + LIMIT))
    done
}

download_collection \
    "trn-ntwk-railwaylink-1" \
    "railway-links-all.json"

download_collection \
    "trn-ntwk-railwaynode-1" \
    "railway-nodes-all.json"