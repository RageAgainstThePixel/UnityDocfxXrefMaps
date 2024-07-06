#!/bin/bash

set -xe

# check if yq is installed
if ! command -v yq &>/dev/null; then
    pip install yq
fi

echo "Starting generate-xref-map.sh"
echo "Version: $1"
echo "Generated Metadata Path: $2"
echo "Output Folder: $3"

version=$1
generatedMetadataPath=$2
outputFolder=$3
references=()
files=$(find "$generatedMetadataPath" -name '*.yml')

echo "Generating XRef map for Unity $version"

for file in $files; do
    firstLine=$(head -n 1 "$file")
    if [[ "$firstLine" == "### YamlMime:ManagedReference" ]]; then
        yaml=$(yq eval '.' "$file" -o json)

        # Debugging: Print the content of yaml
        echo "YAML content for file $file:"
        echo "$yaml"

        items=$(echo "$yaml" | jq -r '.items[]')

        # Debugging: Check if items is properly retrieved
        if [[ -z "$items" ]]; then
            echo "No items found in the YAML content for file $file"
            continue
        fi

        while IFS= read -r item; do
            # Debugging: Print the current item being processed
            echo "Processing item: $item"

            fullName=$(echo "$item" | jq -r '.fullName | select(. != null)' | sed 's/[()<].*//g' | sed 's/`/_/g' | sed 's/#ctor/ctor/g')
            name=$(echo "$item" | jq -r '.name | select(. != null)' | sed 's/[()<].*//g' | sed 's/`/_/g' | sed 's/#ctor/ctor/g')
            uid=$(echo "$item" | jq -r '.uid')
            commentId=$(echo "$item" | jq -r '.commentId')
            href=$(rewriteHref "$uid" "$commentId" "$version")

            if [ -n "$href" ]; then
                references+=("{\"uid\": \"$uid\", \"name\": \"$name\", \"href\": \"$href\", \"commentId\": \"$commentId\", \"fullName\": \"$fullName\", \"nameWithType\": \"$(echo "$item" | jq -r '.nameWithType')\"}")
                echo "$fullName -> $href"
            else
                echo "Failed to process item: $item"
            fi
        done <<<"$items"
    fi
done

# Convert references to JSON and then to YAML
referencesJson=$(printf "%s\n" "${references[@]}" | jq -s '.')
xrefMapContent=$(jq -n --argjson references "$referencesJson" '{ "### YamlMime:XRefMap": null, "sorted": true, "references": $references | sort_by(.uid) }' | yq -P)
outputFilePath="$outputFolder/$version/xrefmap.yml"
mkdir -p "$(dirname "$outputFilePath")"
echo "$xrefMapContent" >"$outputFilePath"
echo "Unity $version XRef Map generated successfully!"

rewriteHref() {
    uid=$1
    commentId=$2
    version=$3

    href=$uid
    nsTrimRegex="^UnityEngine\.|^UnityEditor\."

    if [[ $commentId =~ ^N: ]]; then
        href="index"
    else
        href=$(echo "$href" | sed -E "s/$nsTrimRegex//")

        if [[ $commentId =~ ^F:.* ]]; then
            if [[ $href =~ \.([a-zA-Z][a-zA-Z0-9_]*)$ ]] && [[ ${BASH_REMATCH[1]} =~ ^[a-z] ]]; then
                href=$(echo "$href" | sed -E "s/\.$(${BASH_REMATCH[1]})$/\-${BASH_REMATCH[1]}/")
            fi
        elif [[ $commentId =~ ^M:.*\.#ctor$ ]]; then
            href=$(echo "$href" | sed -E "s/\.\#ctor$/-ctor/")
        else
            href=$(echo "$href" | sed 's/``[0-9]//g' | sed 's/`//g')
            if [[ $commentId =~ ^M: || $commentId =~ ^(P|E): ]] && [[ $href =~ \.[a-z] ]]; then
                href=$(echo "$href" | sed -r "s/\.([a-zA-Z]+)$/-\1/")
            fi
        fi
    fi

    url="https://docs.unity3d.com/$version/Documentation/ScriptReference/$href.html"
    if validateUrl "$url"; then
        echo "$url"
    else
        if [[ $href =~ "-" ]]; then
            altHref=${href//-/.}
        else
            altHref=${href//./-}
        fi

        altUrl="https://docs.unity3d.com/$version/Documentation/ScriptReference/$altHref.html"
        if validateUrl "$altUrl"; then
            echo "$altUrl"
        else
            echo "https://docs.unity3d.com/$version/Documentation/ScriptReference/index.html"
        fi
    fi
}

validateUrl() {
    url=$1
    httpCode=$(curl -o /dev/null -s -w "%{http_code}\n" -I "$url")
    [[ $httpCode -eq 200 ]]
}
