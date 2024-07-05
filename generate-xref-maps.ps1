Write-Host "Generating Unity XRef maps"

# Ensure normalized execution environment
Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "This script requires PowerShell 7.0 or above for parallel processing."
    exit 1
}

if (-not (Get-Module -ListAvailable -Name PowerShell-Yaml)) {
    Install-Module -Name PowerShell-Yaml -Force -Scope CurrentUser
}

Import-Module -Name PowerShell-Yaml

$UnityCsReferenceLocalPath = Join-Path $PWD "UnityCsReference"
$OutputFolder = Join-Path $PWD "_site"
$DocfxLocalDir = Join-Path $PWD ".docfx"
$DocfxPath = Join-Path $DocfxLocalDir "docfx.json"

if (-not (Test-Path -Path $UnityCsReferenceLocalPath)) {
    git clone "https://github.com/Unity-Technologies/UnityCsReference" $UnityCsReferenceLocalPath
}

if (Test-Path -Path $OutputFolder) {
    Remove-Item -Path $OutputFolder -Recurse -Force | Out-Null
}

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

try {
    $branchesOutput = git -C $UnityCsReferenceLocalPath branch -r

    if (-not $branchesOutput) {
        Write-Error "Failed to find UnityCsReference repository branches!"
        exit 1
    }
}
catch {
    Write-Error "Error fetching branches: $_"
    exit 1
}

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

$versions = @()

foreach ($branch in $branches) {
    if ($branch -match '\d{4}\.\d+') {
        $version = $branch
        $versions += $version
    }
}

Set-Content -Path "$OutputFolder/index.html" -Value "<html><head><title>Unity XRef Maps for DocFX</title></head><body><ul>"
$versions = $versions | Sort-Object -Descending

foreach ($version in $versions) {
    Add-Content -Path "$OutputFolder/index.html" -Value "<li><a href=""$version/xrefmap.yml"">$version</a></li>"
}

Add-Content -Path "$outputFolder/index.html" -Value "</ul></body></html>"

function generateXRefMap {
    param (
        [string]$version,
        [string]$GeneratedMetadataPath,
        [string]$outputFolder
    )

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
                    # Write-Warning "$uid -> $url"
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
                        # Write-Host "$fullName -> $href"
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
        references             = $references | Sort-Object uid
    } | ConvertTo-Yaml

    $outputFilePath = Join-Path $outputFolder "$version/xrefmap.yml"
    Write-Host "$version Writing XRef map to $outputFilePath"
    New-Item -ItemType Directory -Path (Split-Path $outputFilePath) -Force
    Set-Content -Path $outputFilePath -Value $xrefMapContent
}

Write-Host "Processing XRef metadata..."

$versionMetadata = @()

foreach ($version in $versions) {
    $versionFolder = Join-Path $DocfxLocalDir "xref/$Version"

    if (-not (Test-Path -Path $versionFolder)) {
        git -C $UnityCsReferenceLocalPath clean -ffdx
        git -C $UnityCsReferenceLocalPath checkout "origin/$Version"
        Write-Host "Generating metadata for $Version..."

        try {
            # for versions between 2019.1 and 2021.3 add Debug configuration property
            if ($version -ge "2019.1" -and $version -le "2021.3") {
                docfx metadata $DocfxPath --output $versionFolder --logLevel error --property Configuration=Debug
            }
            else {
                docfx metadata $DocfxPath --output $versionFolder --logLevel error
            }
        }
        catch {
            Write-Error "Failed generating DocFX metadata for $Version `nDetails: $_"
            return
        }

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -Path $versionFolder)) {
            Write-Error "DocFX metadata generation failed for $Version"
            return
        }
    }
    else {
        Write-Host "Metadata generation for $Version already exists. Skipping..."
    }

    $versionMetadata += [PSCustomObject]@{
        Version      = $Version
        MetadataPath = $versionFolder
    }
}

$versionMetadata | ForEach-Object -Parallel {
    generateXRefMap -version $_.Version -GeneratedMetadataPath $_.MetadataPath -outputFolder $using:OutputFolder
}

Write-Host "Unity XRef maps generated successfully!"
