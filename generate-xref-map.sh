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
    if [[ "$status_code" -ne 200 ]]; then
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
        href="${href#UnityEngine.}"
        href="${href#UnityEditor.}"
        # Handle #ctor
        href="${href//\.#ctor/-ctor}"
        # Convert op_Implicit and capture the parameter type without the namespace or contents inside { }, and add T to the end
        if [[ "$href" =~ \.op_Implicit\((.*)\) ]]; then
            local param="${BASH_REMATCH[1]}"
            # Strip the namespace in parameter name
            param="${param##*.}"
            # Rewrite implicit operator and append T to the end, and remove everything after T
            href="${href/\.op_Implicit\(*\)/-operator_${param}T}"
            href="${href/T*/T}"
        fi
        # Convert any other operators
        if [[ "$href" =~ \.op_ ]]; then
            case "$href" in
            *.op_Equality) href="${href//\.op_Equality/-operator_eq}" ;;
            *.op_Inequality) href="${href//\.op_Inequality/-operator_ne}" ;;
            *.op_LessThan) href="${href//\.op_LessThan/-operator_lt}" ;;
            *.op_GreaterThan) href="${href//\.op_GreaterThan/-operator_gt}" ;;
            *)
                local operator="${href#*\.op_}"
                operator="${operator,,}"
                href="${href/\.op_*/-operator_${operator}}"
                ;;
            esac
        fi
        # Handle nested generics with multiple backticks by removing them and the numbers following
        href="${href//\`\`[0-9]*/}"
        # Handle simple generics single backticks by replacing them with an underscore followed by numbers
        href="${href//\`([0-9]+)/_\1}"
        # Remove everything between { } and parameter list from method signatures
        href="${href//\{*/\}/}"
        href="${href//(*//}"
        # Regex to match the base part and the last part by the last dot
        if [[ "$comment_id" =~ ^[FPMTE]: ]]; then
            if [[ "$href" =~ ^(.*)\.(.*)$ ]]; then
                local base_part="${BASH_REMATCH[1]}"
                local last_part="${BASH_REMATCH[2]}"
                parent_href="$base_part"
                href="$base_part.$last_part"
            fi
        fi
    fi
    if [[ "$href" =~ -ctor ]]; then
        # remove -ctor and everything after -ctor
        alt_href="${href%-ctor*}"
    elif [[ "$href" =~ -operator ]]; then
        # remove -operator and everything after -operator
        alt_href="${href%-operator*}"
    else
        # else replace . with -
        alt_href="${href/\.([^.]*)$/-\1}"
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

function append_reference_to_yaml {
    local file="$1"
    uid="$2"
    name="$3"
    href="$4"
    comment_id="$5"
    full_name="$6"
    name_with_type="$7"
    cat <<EOF >>"$file"
- uid: $uid
  name: $name
  href: $href
  commentId: $comment_id
  fullName: $full_name
  nameWithType: $name_with_type
EOF
}

function generate_xref_map {
    local version="$1"
    local generated_metadata_path="$2"
    local output_folder="$3"
    local output_file="$output_folder/$version/xrefmap.yml"
    mkdir -p "$(dirname "$output_file")"
    echo '### YamlMime:XRefMap' >"$output_file"
    echo '' >>"$output_file"
    echo 'references:' >>"$output_file"
    for file in "$generated_metadata_path"/*.yml; do
        if head -n 1 "$file" | grep -q "### YamlMime:ManagedReference"; then
            while IFS= read -r item; do
                uid=$(echo "$item" | yq '.uid')
                full_name=$(normalize_text "$(echo "$item" | yq '.fullName')")
                name=$(normalize_text "$(echo "$item" | yq '.name')")
                comment_id=$(echo "$item" | yq '.commentId')
                name_with_type=$(echo "$item" | yq '.nameWithType')
                href=$(rewrite_href "$uid" "$comment_id" "$version")
                echo "$comment_id -> $href"
                append_reference_to_yaml "$output_file" "$uid" "$name" "$href" "$comment_id" "$full_name" "$name_with_type"
            done < <(yq eval -o=j -I=0 '.items[]' "$file")
        fi
    done
    echo "Unity $version XRef Map generated successfully!"
}

generate_xref_map "$1" "$2" "$3"
