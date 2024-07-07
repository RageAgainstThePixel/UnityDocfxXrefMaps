#!/bin/bash

set -e

version=$1
generatedMetadataPath=$2
outputFolder=$3
references=()

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

# Ensure yq is installed
if ! command -v yq &>/dev/null; then
    echo "Installing yq..."
    pip install yq
fi

echo "Generating XRef map for Unity $version"
files=$(find "$generatedMetadataPath" -name '*.yml')

for file in $files; do
    echo "Processing file: $file"
    echo "File content:"
    cat "$file"
    echo "End of file content"

    firstLine=$(head -n 1 "$file")
    if [[ "$firstLine" == "### YamlMime:ManagedReference" ]]; then
        echo "Processing file: $file"
        items=$(tail -n +1 "$file" | yq -r '.items' || echo "null")
        echo "Items content: $items"

        if [[ "$items" == "null" || -z "$items" ]]; then
            echo "No valid items found in the YAML content for file $file"
            continue
        fi

        for item in $(echo "${items}" | jq -c '.[]' 2>/dev/null); do
            if [[ -z "$item" || "$item" == "null" ]]; then
                echo "Skipping invalid item"
                continue
            fi

            fullName=$(echo "$item" | jq -r '.fullName' | sed 's/[()<].*//g' | sed 's/`/_/g' | sed 's/#ctor/ctor/g')
            name=$(echo "$item" | jq -r '.name' | sed 's/[()<].*//g' | sed 's/`/_/g' | sed 's/#ctor/ctor/g')
            uid=$(echo "$item" | jq -r '.uid')
            commentId=$(echo "$item" | jq -r '.commentId')
            href=$(rewriteHref "$uid" "$commentId" "$version")

            if [ -n "$href" ]; then
                references+=("{\"uid\": \"$uid\", \"name\": \"$name\", \"href\": \"$href\", \"commentId\": \"$commentId\", \"fullName\": \"$fullName\", \"nameWithType\": \"$(echo "$item" | jq -r '.nameWithType')\"}")
                echo "$fullName -> $href"
            else
                echo "Failed to process item: $fullName"
            fi
        done
    fi
done

# Convert references to YAML
referencesYaml=$(printf "%s\n" "${references[@]}" | jq -s '.' | yq -P)
xrefMapContent=$(yq -n --arg references "$referencesYaml" "{ \"### YamlMime:XRefMap\": null, \"sorted\": true, \"references\": \$references | sort_by(.uid) }")
outputFilePath="$outputFolder/$version/xrefmap.yml"
mkdir -p "$(dirname "$outputFilePath")"
echo "$xrefMapContent" >"$outputFilePath"
echo "Unity $version XRef Map generated successfully!"
