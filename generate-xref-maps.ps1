# Ensure normalized execution environment
Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7.0 or above for parallel processing."
    exit 1
}

Write-Host "Generating Unity XRef maps"

# Install the PowerShell-Yaml module if it's not already installed
if (-not (Get-Module -ListAvailable -Name PowerShell-Yaml)) {
    Install-Module -Name PowerShell-Yaml -Force -Scope CurrentUser
}

# Import the PowerShell-Yaml module
Import-Module -Name PowerShell-Yaml

Write-Host "Imported PowerShell-Yaml module"

$UnityCsReferenceLocalPath = Join-Path $PWD "UnityCsReference"
$OutputFolder = Join-Path $PWD "_site"
$DocfxLocalDir = Join-Path $PWD ".docfx"

# Verify we have the correct directories
if (-not (Test-Path -Path $UnityCsReferenceLocalPath)) {
    # checkout the UnityCsReference repository
    git clone "https://github.com/Unity-Technologies/UnityCsReference" $UnityCsReferenceLocalPath
}

Write-Host "Found UnityCsReference directory: $UnityCsReferenceLocalPath"

# Create output directory if it doesn't exist
if (-not (Test-Path -Path $OutputFolder)) {
    Write-Host "Creating output directory: $OutputFolder"
    New-Item -ItemType Directory -Path $OutputFolder -Force
}


# Debug statement to capture branches before enumeration
Write-Host "Fetching branches..."
try {
    $branchesOutput = git -C $UnityCsReferenceLocalPath branch -r

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
    $branches = $branchesOutput | Select-String -Pattern 'origin/\d{4}\.\d+$' | ForEach-Object {
        $_.Matches.Value.Trim()
    } | ForEach-Object {
        $_ -replace 'origin/', ''
    }

    if (-not $branches) {
        Write-Error "No matching branches found with the pattern 'origin/\d{4}\.\d+$'"
        exit 1
    }
}
catch {
    Write-Error "Error processing branch output: $_"
    exit 1
}

$metadataList = @()

foreach ($branch in $branches) {
    # Parse version from branch name
    if ($branch -match '\d{4}\.\d+') {
        $version = $Matches[0]

        Write-Host "Processing version: $version"

        try {
            git -C $UnityCsReferenceLocalPath checkout --force "origin/$branch"
            git -C $UnityCsReferenceLocalPath reset --hard
            git -C $UnityCsReferenceLocalPath clean -ffdx
        }
        catch {
            Write-Error "Failed to checkout/reset branch: $branch"
            continue
        }

        $DocfxPath = Join-Path $DocfxLocalDir "docfx.json"
        $versionFolder = Join-Path $DocfxLocalDir "api/$version"

        # if the version folder already exists, skip metadata generation but add to the list

        if (-not (Test-Path -Path $versionFolder)) {
            Write-Host "Generating docfx metadata for version $version using $DocfxPath -> $versionFolder"

            # if 2019.1+ add --property Configuration=Debug
            if ($version -ge "2019.1") {
                # if 2023.1+ remove the Configuration property and add TargetFramework netstandard2.1
                if ($version -ge "2022.3") {
                    docfx metadata $DocfxPath --output $versionFolder
                }
                else {
                    Write-Host "Generating metadata for version $version with Configuration=Debug"
                    docfx metadata $DocfxPath --output $versionFolder --property Configuration=Debug
                }
            }
            else {
                Write-Host "Generating metadata for version $version without any property"
                docfx metadata $DocfxPath --output $versionFolder
            }

            if ($LASTEXITCODE -ne 0) {
                Write-Error "DocFX metadata generation failed for $version"
                continue
            }
        }

        $metadataList += [PSCustomObject]@{
            Version               = $version
            GeneratedMetadataPath = Join-Path $DocfxLocalDir "api/$version"
        }
    }
}

Write-Host "Generating XRef map index..."

# Index HTML initial content
Set-Content -Path "$OutputFolder/index.html" -Value "<html><body><ul>"

$metadataList | ForEach-Object -Parallel {
    $version = $_.Version
    $GeneratedMetadataPath = $_.GeneratedMetadataPath
    $outputFolder = $using:OutputFolder

    Write-Host "Generating XRef map for version $version | $GeneratedMetadataPath -> $outputFolder"
    $references = @()
    $files = Get-ChildItem -Path $GeneratedMetadataPath -Filter '*.yml'
    $references += $files | ForEach-Object -Parallel {
        function normalizeText {
            param (
                [string]$text
            )
            if ($null -ne $text -match '(\(|<)') { $text = $text.Split('(<)')[0] }
            $text = $text -replace '[`]', '_' -replace '#ctor', 'ctor'
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
            $altHref = $null

            $nsTrimRegex = [regex]::new("^UnityEngine\.|^UnityEditor\.")

            if ($commentId -match "^N:") {
                $href = "index"
            }
            else {
                $href = $nsTrimRegex.Replace($href, "")

                if ($commentId -match "^F:.*") {
                    $isEnum = $href -match "\.([a-zA-Z][a-zA-Z0-9_]*)$"
                    if ($isEnum -and $Matches[1] -cmatch "^[a-z]") {
                        $href = $href -replace "\.$($Matches[1])$", "-$($Matches[1])"
                    }
                }
                elseif ($commentId -match "^M:.*\.#ctor$") {
                    $href = $href -replace "\.\#ctor$", "-ctor"
                }
                else {
                    $href = $href -replace "``\d", "" -replace '`', ""

                    if ($commentId -match "^M:" -or $commentId -match "^(P|E):" -and $href.LastIndexOf('.') -ne -1) {
                        $href = $href.Substring(0, $href.LastIndexOf('.')) + "-" + $href.Substring($href.LastIndexOf('.') + 1)
                    }
                }
            }

            $url = "https://docs.unity3d.com/$version/Documentation/ScriptReference/$href.html"

            if (validateUrl -url $url) {
                return $url
            }
            else {
                if ($href -match "-") {
                    $altHref = $href -replace "-", "."
                }
                else {
                    $altHref = $href -replace "\.", "-"
                }

                $altUrl = "https://docs.unity3d.com/$version/Documentation/ScriptReference/$altHref.html"

                if (validateUrl -url $altUrl) {
                    return $altUrl
                }
                else {
                    Write-Warning "$uid -> $url"
                    return $null
                }
            }
        }

        $filePath = $_.FullName
        $referencesLocal = @()
        $firstLine = Get-Content $filePath -TotalCount 1

        if ($firstLine -eq "### YamlMime:ManagedReference") {
            $yaml = Get-Content $filePath -Raw | ConvertFrom-Yaml
            $items = $yaml.items

            foreach ($item in $items) {
                try {
                    $fullName = normalizeText $item.fullName
                    $name = normalizeText $item.name
                    $href = rewriteHref -uid $item.uid -commentId $item.commentId -version $using:version

                    if ($null -ne $href) {
                        Write-Host "$fullName -> $href"
                        $referencesLocal += [PSCustomObject]@{
                            uid          = $item.uid
                            name         = $name
                            href         = $href
                            commentId    = $item.commentId
                            fullName     = $fullName
                            nameWithType = $item.nameWithType
                        }
                    }
                }
                catch {
                    Write-Error "Error processing item: $item `nDetails: $_"
                    continue
                }
            }
        }

        return $referencesLocal
    }

    Write-Host "$version Sorting references"

    $xrefMapContent = @{
        "### YamlMime:XRefMap" = $null
        sorted                 = $true
        references             = $references | Sort-Object Uid
    } | ConvertTo-Yaml

    $relativeOutputFilePath = "$version/xrefmap.yml"
    $outputFilePath = Join-Path $outputFolder $relativeOutputFilePath

    Write-Host "$version Writing XRef map to $outputFilePath"
    New-Item -ItemType Directory -Path (Split-Path $outputFilePath) -Force
    Set-Content -Path $outputFilePath -Value $xrefMapContent
    Add-Content -Path "$outputFolder/index.html" -Value "<li><a href=""$relativeOutputFilePath"">$version</a></li>"
}

Add-Content -Path "$outputFolder/index.html" -Value "</ul></body></html>"
Write-Host "Unity XRef maps generated successfully!"
