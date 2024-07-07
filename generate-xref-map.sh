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

    for file_path in "$generated_metadata_path"/*.yml; do
        local first_line
        first_line=$(head -n 1 "$file_path")

        if [[ "$first_line" == "### YamlMime:ManagedReference" ]]; then
            echo "Processing $file_path"
            local yaml_content
            yaml_content=$(tail -n +1 "$file_path")
            local items
            items=$(echo "$yaml_content" | yq eval '.items' -)

            if [[ -n "$items" ]]; then
                for item in $(echo "$items" | jq -c '.[]'); do
                    local full_name name href
                    full_name=$(normalize_text "$(echo "$item" | jq -r '.fullName')")
                    name=$(normalize_text "$(echo "$item" | jq -r '.name')")
                    href=$(rewrite_href "$(echo "$item" | jq -r '.uid')" "$(echo "$item" | jq -r '.commentId')" "$version")
                    echo "$full_name -> $href"
                    references+=("$(jq -n --arg uid "$(echo "$item" | jq -r '.uid')" \
                        --arg name "$name" \
                        --arg href "$href" \
                        --arg commentId "$(echo "$item" | jq -r '.commentId')" \
                        --arg fullName "$full_name" \
                        --arg nameWithType "$(echo "$item" | jq -r '.nameWithType')" \
                        '{ uid: $uid, name: $name, href: $href, commentId: $commentId, fullName: $fullName, nameWithType: $nameWithType }')")
                done
            fi
        fi
    done

    local xref_map_content
    xref_map_content=$(jq -n \
        --arg version "$version" \
        --argjson references "$(printf '%s\n' "${references[@]}" | jq -s '.')" \
        '{ "### YamlMime:XRefMap": null, sorted: true, references: $references }')

    local output_file_path="$output_folder/$version/xrefmap.yml"
    mkdir -p "$(dirname "$output_file_path")"
    echo "$xref_map_content" | yq eval -P >"$output_file_path"

    echo "Unity $version XRef Map generated successfully!"
}

generate_xref_map "$1" "$2" "$3"
