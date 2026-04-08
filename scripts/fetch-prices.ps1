# fetch-prices.ps1
# Queries the Azure Retail Prices API for AVD VM SKU pricing across all supported regions.
# Outputs prices.json in the repo root.
# https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices

$ErrorActionPreference = 'Stop'

$regions = @(
    'eastus', 'westus2', 'westeurope', 'northeurope',
    'uksouth', 'australiaeast', 'southeastasia', 'japaneast'
)

$skus = @(
    'Standard_D2s_v5', 'Standard_D4s_v5', 'Standard_D8s_v5', 'Standard_D16s_v5',
    'Standard_E2s_v5', 'Standard_E4s_v5', 'Standard_E8s_v5', 'Standard_E16s_v5',
    'Standard_NV6ads_A10_v5', 'Standard_NV12ads_A10_v5', 'Standard_NV18ads_A10_v5', 'Standard_NV36ads_A10_v5',
    'Standard_NC4as_T4_v3', 'Standard_NC8as_T4_v3', 'Standard_NC16as_T4_v3', 'Standard_NC64as_T4_v3',
    'Standard_NC6s_v3', 'Standard_NC12s_v3', 'Standard_NC24s_v3'
)

$baseUrl = 'https://prices.azure.com/api/retail/prices'
$hoursPerMonth = 730
$pricing = @{}
$errors = @()

foreach ($region in $regions) {
    Write-Host "Fetching prices for $region..."
    $regionPrices = @{}

    foreach ($sku in $skus) {
        $filter = "armRegionName eq '$region' and armSkuName eq '$sku' and serviceName eq 'Virtual Machines' and priceType eq 'Consumption'"
        $url = "${baseUrl}?`$filter=$filter"

        $attempt = 0
        $maxRetries = 3
        $success = $false

        while (-not $success -and $attempt -lt $maxRetries) {
            $attempt++
            try {
                $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30
                $items = $response.Items | Where-Object {
                    $_.type -eq 'Consumption' -and
                    $_.unitOfMeasure -eq '1 Hour' -and
                    $_.retailPrice -gt 0 -and
                    $_.productName -notmatch 'Windows' -and
                    $_.skuName -notmatch 'Spot|Low Priority'
                }

                if ($items) {
                    $hourly = ($items | Select-Object -First 1).retailPrice
                    $monthly = [math]::Round($hourly * $hoursPerMonth)
                    $regionPrices[$sku] = $monthly
                }
                else {
                    Write-Warning "No price found for $sku in $region"
                    $errors += "$sku in ${region}: no matching price"
                }
                $success = $true
            }
            catch {
                if ($attempt -lt $maxRetries -and $_.Exception.Message -match '429|Too Many') {
                    Write-Host "  Rate limited on $sku, retrying in 5s (attempt $attempt/$maxRetries)..."
                    Start-Sleep -Seconds 5
                }
                else {
                    Write-Warning "API error for $sku in ${region}: $_"
                    $errors += "$sku in ${region}: $($_.Exception.Message)"
                    $success = $true  # don't retry non-429 errors
                }
            }
        }

        # Small delay between requests to avoid rate limiting
        Start-Sleep -Milliseconds 200
    }

    $pricing[$region] = $regionPrices
}

# Build output object
$output = [ordered]@{
    lastUpdated = (Get-Date -Format 'yyyy-MM-dd')
    source       = 'Azure Retail Prices API'
    sourceUrl    = 'https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices'
    note         = 'Pay-as-you-go Linux (base compute) monthly rates. AVD Windows licensing is per-user via M365. Hourly rate x 730 = monthly.'
    regions      = $pricing
}

$outPath = Join-Path $PSScriptRoot '..' 'prices.json'
$output | ConvertTo-Json -Depth 4 | Set-Content -Path $outPath -Encoding utf8

Write-Host "`nPrices written to $outPath"
Write-Host "Last updated: $($output.lastUpdated)"
Write-Host "Regions: $($pricing.Keys.Count), SKUs per region: $($skus.Count)"

if ($errors.Count -gt 0) {
    Write-Warning "`n$($errors.Count) errors encountered:"
    $errors | ForEach-Object { Write-Warning "  $_" }
    exit 1
}
