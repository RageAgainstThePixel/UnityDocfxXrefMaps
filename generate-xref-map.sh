#!/bin/bash

set -e

function normalize_text {
    local text="$1"
    text="${text%%[\(\<]*}"    # Remove everything after ( or <
    text="${text//\`/_}"       # Replace ` with _
    text="${text//#ctor/ctor}" # Replace #ctor with ctor
    echo "$text"
}

function validate_url {
    local url="$1"
    status_code=$(curl --head --silent --output /dev/null --write-out "%{http_code}" "$url")
    [[ "$status_code" -eq 200 ]]
}

function rewrite_href {
    local uid="$1"
    local comment_id="$2"
    local version="$3"

    local href="$uid"
    local alt_href=""

    if [[ "$comment_id" =~ ^N: ]]; then
        href="index"
    else
        href=$(echo "$href" | sed -E 's/^UnityEngine\.|^UnityEditor\.//g')
        if [[ "$comment_id" =~ ^F:.* ]]; then
            if [[ "$href" =~ \.([a-zA-Z][a-zA-Z0-9_]*)$ ]] && [[ "${BASH_REMATCH[1]}" =~ ^[a-z] ]]; then
                href=$(echo "$href" | sed -E "s/\.${BASH_REMATCH[1]}/-${BASH_REMATCH[1]}/")
            fi
        elif [[ "$comment_id" =~ ^M:.*\.#ctor$ ]]; then
            href="${href//\.#ctor/-ctor}"
        else
            href="${href//$()[0-9]/}"
            href="${href//\`/}"
            if [[ "$comment_id" =~ ^M:|^P:|^E: ]]; then
                href="${href%.*}-${href##*.}"
            fi
        fi
    fi

    local url="https://docs.unity3d.com/$version/Documentation/ScriptReference/$href.html"

    if validate_url "$url"; then
        echo "$url"
    else
        if [[ "$href" =~ - ]]; then
            alt_href="${href//-/\.}"
        else
            alt_href="${href//\./-}"
        fi
        local alt_url="https://docs.unity3d.com/$version/Documentation/ScriptReference/$alt_href.html"
        if validate_url "$alt_url"; then
            echo "$alt_url"
        else
            echo "https://docs.unity3d.com/$version/Documentation/ScriptReference/index.html"
        fi
    fi
}

function generate_xref_map {
    local version="$1"
    local generated_metadata_path="$2"
    local output_folder="$3"
    references=()

    # Iterate over every YAML file in the generated metadata path
    for file in "$generated_metadata_path"/*.yml; do
        yq --exit-status 'tag == "!!map" or tag== "!!seq"' "$file" >/dev/null
        # Validate if the file contains "### YamlMime:ManagedReference" on the first line
        first_line=$(head -n 1 "$file")

        if [[ "$first_line" == "### YamlMime:ManagedReference" ]]; then
            echo "Processing $file"
            readarray items < <(yq eval -o=j -I=0 '.items[]' "$file")

            if [[ ${#items[@]} -eq 0 ]]; then
                echo "No items found in $file"
                continue
            fi

            for item in "${items[@]}"; do
                full_name=$(normalize_text "$(echo "$item" | yq '.fullName')")
                name=$(normalize_text "$(echo "$item" | yq '.name')")
                uid=$(echo "$item" | yq '.uid')
                comment_id=$(echo "$item" | yq '.commentId')
                name_with_type=$(echo "$item" | yq '.nameWithType')
                href=$(rewrite_href "$uid" "$comment_id" "$version")
                echo "$full_name -> $href"
                # Append result to references array as JSON objects (using jq for structured building)
                references+=("$(jq -n \
                    --arg uid "$uid" \
                    --arg name "$name" \
                    --arg href "$href" \
                    --arg commentId "$comment_id" \
                    --arg fullName "$full_name" \
                    --arg nameWithType "$name_with_type" \
                    '{ uid: $uid, name: $name, href: $href, commentId: $commentId, fullName: $fullName, nameWithType: $nameWithType }')")
            done
        fi
    done

    # Compile all references data into the final output YAML
    xref_map_content=$(jq -n \
        --argjson references "$(printf '%s\n' "${references[@]}" | jq -s '.')" \
        '{ "### YamlMime:XRefMap": null, sorted: true, references: $references }')

    # Generate the output file
    local output_file_path="$output_folder/$version/xrefmap.yml"
    mkdir -p "$(dirname "$output_file_path")"
    echo "$xref_map_content" | yq eval -P >"$output_file_path"

    echo "Unity $version XRef Map generated successfully!"
}

generate_xref_map "$1" "$2" "$3"
