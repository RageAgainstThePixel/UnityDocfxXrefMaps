# Ensure normalized execution environment
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "Generating Unity XRef maps"

# Install the PowerShell-Yaml module if it's not already installed
if (-not (Get-Module -ListAvailable -Name PowerShell-Yaml)) {
    Install-Module -Name PowerShell-Yaml -Force -Scope CurrentUser
}

# Import the PowerShell-Yaml module
Import-Module -Name PowerShell-Yaml

Write-Host "Imported PowerShell-Yaml module"

$UnityCsReferenceLocalPath = "UnityCsReference"
$OutputFolder = Join-Path $PWD "_site"

# Verify we have the correct directories
if (-not (Test-Path -Path $UnityCsReferenceLocalPath)) {
    Write-Error "Directory not found: $UnityCsReferenceLocalPath"
    exit 1
}

Write-Host "Found UnityCsReference directory: $UnityCsReferenceLocalPath"

# Create output directory if it doesn't exist
if (-not (Test-Path -Path $OutputFolder)) {
    Write-Host "Creating output directory: $OutputFolder"
    New-Item -ItemType Directory -Path $OutputFolder -Force
}

function Normalize-Text {
    param (
        [string]$text
    )
    if ($text -contains '(') { $text = $text.Substring(0, $text.IndexOf('(')) }
    if ($text -contains '<') { $text = $text.Substring(0, $text.IndexOf('<')) }
    $text = $text -replace '`', '_'
    $text = $text -replace '#ctor', 'ctor'
    return $text
}

function validateUrl {
    param (
        [string]$url
    )
    try {
        $response = Invoke-WebRequest -Uri $url -Method Head -ErrorAction Stop
        return $response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

function rewriteHref {
    param (
        [string]$uid,
        [string]$commentId,
        [string]$version
    )

    $href = $uid

    # Handle namespaces pointing to documentation index
    if ($commentId -match "^N:") {
        $href = "index"
    }
    else {
        # Trim UnityEngine and UnityEditor namespaces from href
        $HrefNamespacesToTrim = @("UnityEditor", "UnityEngine")
        foreach ($namespaceToTrim in $HrefNamespacesToTrim) {
            $href = $href -replace "$namespaceToTrim\.", ""
        }

        # Adjust handling for enums
        if ($commentId -match "^F:.*") {
            # If the comment ID indicates a field, check if it's part of an enum
            $isEnum = $href -match "\.([a-zA-Z][a-zA-Z0-9_]*)$"

            if ($isEnum) {
                # is enum member is lowercase, then use - instead of .
                $enumMember = $Matches[1]

                if ($enumMember -cmatch "^[a-z]") {
                    $href = $href -replace "\.$enumMember$", "-$enumMember"
                }
            }
        }
        else {
            # Fix href of constructors
            if ($commentId -match "^M:.*\.#ctor$") {
                $href = $href -replace "\.\#ctor$", "-ctor"
            }

            # Fix href of generics
            $href = $href -replace "``\d", ""
            $href = $href -replace '`', ""  # remove just backticks for generics

            # Fix href of methods (both instance and static)
            if ($commentId -match "^M:") {
                # Handle methods without replacing dots in the name part
                $href = $href -replace "\(.*\)$", ""  # Remove parenthesis and parameters
            }
            else {
                # Handle properties and non-enum fields
                if ($commentId -match "^(P|M|E):" -and $href.LastIndexOf('.') -ne -1) {
                    $href = $href.Substring(0, $href.LastIndexOf('.')) + "-" + $href.Substring($href.LastIndexOf('.') + 1)
                }
            }
        }
    }

    $url = "https://docs.unity3d.com/$version/Documentation/ScriptReference/$href.html"

    if (validateUrl -url $url) {
        return $url
    }
    else {
        # Attempt alternative URL by switching between last index of '.' and '-'
        # use match instead of -contains
        if ($href -match "-") {
            $alternativeHref = $href -replace "-", "."
        }
        else {
            $alternativeHref = $href -replace "\.", "-"
        }

        $alternativeUrl = "https://docs.unity3d.com/$version/Documentation/ScriptReference/$alternativeHref.html"

        if (validateUrl -url $alternativeUrl) {
            return $alternativeUrl
        }
        else {
            Write-Warning "$uid -> $url"
            return $null
        }
    }
}

# Index HTML initial content
Set-Content -Path "$OutputFolder/index.html" -Value "<html><body><ul>"

# Debug statement to capture branches before enumeration
Write-Host "Fetching branches..."
try {
    $branchesOutput = git -C $UnityCsReferenceLocalPath branch -r
    Write-Host "Branches output: $branchesOutput"
    if (-not $branchesOutput) {
        Write-Error "Failed to fetch branches or no branches found."
        exit 1
    }
}
catch {
    Write-Error "Error fetching branches: $_"
    exit 1
}

# Break down the branch fetching and enumeration for better diagnostics
try {
    $branches = $branchesOutput | Select-String -Pattern 'origin/\d{4}\.\d+$' | ForEach-Object { $_.Matches.Value.Trim() }
    if (-not $branches) {
        Write-Error "No matching branches found with the pattern 'origin/\d{4}\.\d+$'"
        exit 1
    }
}
catch {
    Write-Error "Error processing branch output: $_"
    exit 1
}

foreach ($branch in $branches) {
    Write-Host "Processing branch: $branch"

    # Parse version from branch name
    if ($branch -match 'origin/(\d{4}\.\d+)') {
        $version = $Matches[1]

        Write-Host "Processing branch: $branch, version: $version"

        try {
            git -C $UnityCsReferenceLocalPath checkout --force $branch
            git -C $UnityCsReferenceLocalPath reset --hard
        }
        catch {
            Write-Error "Failed to checkout/reset branch: $branch"
            continue
        }

        # Run docfx metadata
        Write-Host "Running DocFX for version $version"
        docfx metadata ./.docfx/docfx.json --output ./.docfx/api/$version

        if ($LASTEXITCODE -ne 0) {
            Write-Error "DocFX metadata generation failed for $version"
            continue
        }

        # Path to generated metadata
        $GeneratedMetadataPath = Join-Path $PWD ".docfx/api/$version"

        # Generate XRef map YAML
        Write-Host "Generating XRef map for version $version"
        $references = @()
        Get-ChildItem -Path $GeneratedMetadataPath -Filter '*.yml' | ForEach-Object {
            $filePath = $_.FullName
            $firstLine = Get-Content $filePath -First 1
            if ($firstLine -eq "### YamlMime:ManagedReference") {
                $yaml = Get-Content $filePath -Raw | ConvertFrom-Yaml
                $items = $yaml.items

                foreach ($item in $items) {
                    try {
                        $fullName = Normalize-Text $item.fullName
                        $name = Normalize-Text $item.name
                        $href = rewriteHref -uid $item.uid -commentId $item.commentId -version $version

                        if ($href -ne $null) {
                            Write-Host "$fullName -> $href"

                            $references += [PSCustomObject]@{
                                Uid          = $item.uid
                                Name         = $name
                                Href         = $href
                                CommentId    = $item.commentId
                                FullName     = $fullName
                                NameWithType = $item.nameWithType
                            }
                        }
                    }
                    catch {
                        Write-Error "Error processing item: $item `nDetails: $_"
                    }
                }
            }
        }

        Write-Host "Sorting references"

        $xrefMapContent = @{
            "### YamlMime:XRefMap" = $null
            sorted                 = $true
            references             = $references | Sort-Object Uid
        } | ConvertTo-Yaml

        $relativeOutputFilePath = "$version/xrefmap.yml"
        $outputFilePath = Join-Path $OutputFolder $relativeOutputFilePath

        Write-Host "Writing XRef map to $outputFilePath"
        New-Item -ItemType Directory -Path (Split-Path $outputFilePath) -Force
        Set-Content -Path $outputFilePath -Value $xrefMapContent
        Add-Content -Path "$OutputFolder/index.html" -Value "<li><a href=""$relativeOutputFilePath"">$version</a></li>"
    }
}

Add-Content -Path "$OutputFolder/index.html" -Value "</ul></body></html>"

Write-Host "Unity XRef maps generated successfully!"