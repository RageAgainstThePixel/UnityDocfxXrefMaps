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
    echo "Validating $url"
    status_code=$(curl --head --silent --output /dev/null --write-out "%{http_code}" "$url")
    [[ "$status_code" -eq 200 ]]
}

function rewrite_href {
    local uid="$1"
    local comment_id="$2"
    local version="$3"

    local href="$uid"

    # Trim namespaces
    href=$(echo "$href" | sed -E 's/^UnityEngine\.|^UnityEditor\.//g')

    if [[ "$comment_id" =~ ^N: ]]; then
        href="index"
    else
        # Remove parameter list from method signatures
        href=$(echo "$href" | sed -E 's/\(.*\)//')

        # Remove sequences and backticks
        href="${href//$()[0-9]/}"
        href="${href//\`/}"

        # Regex to capture the last component for methods and properties
        local base_part_regex="^(.*)\.(.*)$"

        if [[ "$comment_id" =~ ^F: ]]; then
            # Field case
            if [[ "$href" =~ $base_part_regex ]]; then
                local base_part="${BASH_REMATCH[1]}"
                local last_part="${BASH_REMATCH[2]}"
                if [[ "$last_part" =~ ^[a-z] ]]; then
                    href="$base_part-$last_part"
                fi
            fi
        elif [[ "$comment_id" =~ ^M:.*\.#ctor$ ]]; then
            # Constructor case
            href="${href//\.#ctor/-ctor}"
        elif [[ "$comment_id" =~ ^P: ]]; then
            # Property case
            if [[ "$href" =~ $base_part_regex ]]; then
                local base_part="${BASH_REMATCH[1]}"
                local last_part="${BASH_REMATCH[2]}"
                href="$base_part-$last_part"
            fi
        elif [[ "$comment_id" =~ ^M: ]]; then
            # Method case
            if [[ "$href" =~ $base_part_regex ]]; then
                local base_part="${BASH_REMATCH[1]}"
                local last_part="${BASH_REMATCH[2]}"
                href="$base_part-$last_part"
            fi
        else
            # For other cases, just adopt existing transformation logic for other IDs
            href="${href//\./-}"
        fi
    fi

    local url="https://docs.unity3d.com/$version/Documentation/ScriptReference/$href.html"

    if validate_url "$url"; then
        echo "$url"
    else
        # Reverse changes for alt_href to double-check URL formation
        alt_href=$(echo "$href" | sed -E 's/(.*)-/\1./')
        local alt_url="https://docs.unity3d.com/$version/Documentation/ScriptReference/$alt_href.html"

        if validate_url "$alt_url"; then
            echo "$alt_url"
        else
            alt_href=$(echo "$href" | sed -E 's/(.*)\./\1-/')
            alt_url="https://docs.unity3d.com/$version/Documentation/ScriptReference/$alt_href.html"

            if validate_url "$alt_url"; then
                echo "$alt_url"
            else
                echo "https://docs.unity3d.com/$version/Documentation/ScriptReference/index.html"
            fi
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
        # Validate if the file contains "### YamlMime:ManagedReference" on the first line
        first_line=$(head -n 1 "$file")
        if [[ "$first_line" == "### YamlMime:ManagedReference" ]]; then
            readarray items < <(yq eval -o=j -I=0 '.items[]' "$file")
            if [[ ${#items[@]} -eq 0 ]]; then
                echo "No items found in $file"
                continue
            fi
            echo "::group::Processing $file"
            for item in "${items[@]}"; do
                uid=$(echo "$item" | yq '.uid')
                full_name=$(normalize_text "$(echo "$item" | yq '.fullName')")
                name=$(normalize_text "$(echo "$item" | yq '.name')")
                comment_id=$(echo "$item" | yq '.commentId')
                name_with_type=$(echo "$item" | yq '.nameWithType')
                echo "::group::Processing $comment_id"
                href=$(rewrite_href "$uid" "$comment_id" "$version")
                echo "$full_name -> $href"
                echo "::endgroup::"
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
            echo "::endgroup::"
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
