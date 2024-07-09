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
    if [[ "$status_code" -eq 200 ]]; then
        echo -e "\e[32mValidating $url - Status: $status_code OK\e[0m" >&2
    else
        echo -e "\e[33mValidating $url - Status: $status_code FAIL\e[0m" >&2
    fi
    [[ "$status_code" -eq 200 ]]
}

function rewrite_href {
    local uid="$1"
    local comment_id="$2"
    local version="$3"
    local base_url="https://docs.unity3d.com/$version/Documentation/ScriptReference/"
    local href="$uid"
    local alt_href=""
    local parent_href=""
    if [[ "$comment_id" =~ ^N: ]]; then
        echo "${base_url}index.html"
        return
    else
        # Remove UnityEngine and UnityEditor namespaces
        href=$(echo "$href" | sed -E 's/^UnityEngine\.|^UnityEditor\.//g')
        # Handle #ctor
        href="${href//\.#ctor/-ctor}"
        # Convert op_Implicit and capture the parameter type without the namespace or contents inside { }, and add T to the end
        if [[ "$href" =~ \.op_Implicit\((.*)\) ]]; then
            local param="${BASH_REMATCH[1]}"
            # Strip the namespace in parameter name
            param=$(echo "$param" | sed -E 's/.*\.//g')
            # Rewrite implicit operator and append T to the end, and remove everything after T
            href=$(echo "$href" | sed -E "s/\.op_Implicit\(.*\)/-operator_${param}T/; s/(T).*/\1/")
        fi
        # Convert any other operator
        if [[ "$href" =~ \.op_ ]]; then
            if [[ "$href" =~ \.op_Equality ]]; then
                href=$(echo "$href" | sed -E 's/\.op_Equality/-operator_eq/; s/(eq).*/\1/')
            elif [[ "$href" =~ \.op_Inequality ]]; then
                href=$(echo "$href" | sed -E 's/\.op_Inequality/-operator_ne/; s/(ne).*/\1/')
            elif [[ "$href" =~ \.op_LessThan ]]; then
                href=$(echo "$href" | sed -E 's/\.op_LessThan/-operator_lt/; s/(lt).*/\1/')
            elif [[ "$href" =~ \.op_GreaterThan ]]; then
                href=$(echo "$href" | sed -E 's/\.op_GreaterThan/-operator_gt/; s/(gt).*/\1/')
            else
                href=$(echo "$href" | sed -E 's/\.op_/-operator_/; s/(operator_)(.*)/\1\L\2/; s/([a-z]+).*/\1/')
            fi
        fi
        # Handle nested generics with multiple backticks by removing them and the numbers following
        href=$(echo "$href" | sed -E 's/[`]{2,}[0-9]+//g')
        # Handle simple generics single backticks by replacing them with an underscore followed by numbers
        href=$(echo "$href" | sed -E 's/`([0-9]+)/_\1/g')
        # Remove everything between { } and parameter list from method signatures
        href=$(echo "$href" | sed -E 's/\{[^}]*\}|\(.*\)//g')
        # Regex to match the base part and the last part by the last dot
        local base_part_regex="^(.*)\.(.*)$"
        if [[ "$comment_id" =~ ^F: || "$comment_id" =~ ^P: || "$comment_id" =~ ^M: || "$comment_id" =~ ^T: || "$comment_id" =~ ^E: ]]; then
            if [[ "$href" =~ $base_part_regex ]]; then
                local base_part="${BASH_REMATCH[1]}"
                local last_part="${BASH_REMATCH[2]}"
                parent_href="$base_part"
                href="$base_part.$last_part"
            fi
        fi
    fi
    if [[ "$href" =~ -ctor ]]; then
        # remove -ctor and everything after -ctor
        alt_href=$(echo "$href" | sed -E 's/-ctor.*//')
    elif [[ "$href" =~ -operator ]]; then
        # remove -operator and everything after -operator
        alt_href=$(echo "$href" | sed -E 's/-operator.*//')
    else
        # else replace . with -
        alt_href=$(echo "$href" | sed -E 's/\.([^.]*)$/-\1/')
    fi
    local url="${base_url}${href}.html"
    local alt_url="${base_url}${alt_href}.html"
    local parent_url="${base_url}${parent_href}.html"
    if validate_url "$url"; then
        echo "$url"
    elif validate_url "$alt_url"; then
        echo "$alt_url"
    elif validate_url "$parent_url"; then
        echo "$parent_url"
    else
        echo "${base_url}index.html"
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
            echo "Processing $file"
            for item in "${items[@]}"; do
                uid=$(echo "$item" | yq '.uid')
                full_name=$(normalize_text "$(echo "$item" | yq '.fullName')")
                name=$(normalize_text "$(echo "$item" | yq '.name')")
                comment_id=$(echo "$item" | yq '.commentId')
                name_with_type=$(echo "$item" | yq '.nameWithType')
                echo "Processing $comment_id"
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
