# ==============================================================================================
# ESXi Upgrade Compatibility Tool (8.0 U3 -> 9.x) 
# ==============================================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$vCenterName,

    [Parameter(Mandatory = $true)]
    [string]$TargetVersion
)

function Get-ClusterHosts {
    param([string]$ClusterName)
    $Cluster = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $Cluster) {
        Write-Error "Cluster '$ClusterName' niet gevonden!"
        return $null
    }
    return Get-VMHost -Location $Cluster | Where-Object { $_.ConnectionState -eq "Connected" }
}

function Get-VCGComparison {
    param(
        [string]$VID, [string]$DID, [string]$SVID, [string]$SDID,
        [string]$DeviceName, [string]$Ver, [string]$HostName
    )

    $Uri = "https://compatibilityguide.broadcom.com/compguide/programs/viewResults?limit=10&page=1"
    
    $BodyObj = @{
        programId = "io"
        filters   = @(
            @{ displayKey = "vid"; filterValues = @($VID) },
            @{ displayKey = "did"; filterValues = @($DID) },
            @{ displayKey = "svid"; filterValues = @($SVID) },
            @{ displayKey = "maxSsid"; filterValues = @($SDID) },
            @{ displayKey = "productReleaseVersion"; filterValues = @("ESXi $Ver") }
        )
        keyword = @()
        date    = @{ startDate = $null; endDate = $null }
    }
    
    $JsonBody = $BodyObj | ConvertTo-Json -Depth 10

    try {
        $SearchRes = Invoke-RestMethod -Uri $Uri -Method Post -Body $JsonBody -Headers @{"content-type"="application/json";"user-persona"="live"} -TimeoutSec 15
        
        if ($SearchRes.data.count -gt 0) {
            $ProdID = $SearchRes.data.fieldValues.uuid[0]
            $EscapedVer = [uri]::EscapeDataString("ESXi $Ver")
            $DetailUri = "https://compatibilityguide.broadcom.com/compguide/programs/viewDetails?programId=io&id=$ProdID&filterBy=$EscapedVer"
            
            $Details = Invoke-RestMethod -Uri $DetailUri -Method Post -Body "" -Headers @{"user-persona"="live"; "accept"="application/json"}
            
            return $Details.data.details.subsections.fieldValues | ForEach-Object {
                [PSCustomObject]@{
                    HostName      = $HostName
                    ESXiVersion   = $Ver
                    Device        = $DeviceName
                    DriverName    = $_.driverName
                    DriverVersion = $_.driverVersion
                    Firmware      = ($_.firmwareVersion + " " + $_.additionalFirmwareVersion).Trim()
                    BCL_Link      = "https://compatibilityguide.broadcom.com/detail.php?deviceid=$ProdID"
                }
            }
        } else {
            return [PSCustomObject]@{
                HostName      = $HostName
                ESXiVersion   = $Ver
                Device        = $DeviceName
                DriverName    = "--- NOT SUPPORTED ---"
                DriverVersion = "N/A"
                Firmware      = "N/A"
                BCL_Link      = "N/A"
            }
        }
    } catch {
        return $null
    }
}

function Get-VCGCPUStatus {
    param([string]$CpuId, [string]$Ver, [string]$HostName, [string]$FullCpuName)
    
    $DetailUri = "https://compatibilityguide.broadcom.com/compguide/programs/viewDetails?programId=cpu&id=$CpuId"
    
    try {
        $Details = Invoke-RestMethod -Uri $DetailUri -Method Post -Body "" -Headers @{"user-persona"="live"; "accept"="application/json"}
        
        $SupportedReleaseField = $Details.data.details.subsections | Where-Object { $_.order -eq 2 } | ForEach-Object { $_.fieldValues }
        
        if (-not $SupportedReleaseField) {
             $SupportedReleaseField = $Details.data.details.subsections.fields | Where-Object { $_.displayKey -eq "esxi" } | Select-Object -ExpandProperty fieldValues
        }

        $IsSupported = $SupportedReleaseField -match $Ver
        $Status = if ($IsSupported) { "SUPPORTED" } else { "--- NOT SUPPORTED ---" }

        return [PSCustomObject]@{
            HostName      = $HostName
            ESXiVersion   = $Ver
            Device        = "CPU: $FullCpuName"
            DriverName    = $Status
            DriverVersion = "N/A"
            Firmware      = "N/A"
            BCL_Link      = "https://compatibilityguide.broadcom.com/detail?program=cpu&productId=$CpuId&persona=live"
        }
    } catch {
        return $null
    }
}

function Get-CpuMatchHints {
    param([string]$FullCpuName)

    $Hints = [ordered]@{
        Vendor           = $null
        ProductLine      = $null
        ModelNumber      = $null
        CodeNames        = @()
        ExpectedPatterns = @()
    }

    if ($FullCpuName -match "\bAMD\b") { $Hints.Vendor = "AMD" }
    elseif ($FullCpuName -match "\bIntel\b") { $Hints.Vendor = "Intel" }

    if ($FullCpuName -match "\bEPYC\b") { $Hints.ProductLine = "EPYC" }
    elseif ($FullCpuName -match "\bXeon\b") { $Hints.ProductLine = "Xeon" }

    if ($FullCpuName -match "EPYC\s+([A-Z0-9]+)") {
        $Hints.ModelNumber = $Matches[1]
        if ($Hints.ModelNumber -match "(\d{4})") {
            $ModelDigits = $Matches[1]
            $FamilyDigit = $ModelDigits.Substring(0, 1)
            $GenerationDigit = $ModelDigits.Substring(3, 1)

            if ($FamilyDigit -in @("7", "8", "9")) {
                $SeriesNumber = "$($FamilyDigit)00$GenerationDigit"
                $Hints.ExpectedPatterns += @(
                    "AMD EPYC $SeriesNumber",
                    "EPYC $SeriesNumber",
                    $SeriesNumber
                )
            }
        }
    }
    elseif ($FullCpuName -match "Xeon.*?\b([0-9]{4,5}[A-Z]*)\b") {
        $Hints.ModelNumber = $Matches[1]
        if ($Hints.ModelNumber -match "^(\d{4,5})([A-Z+]*)$") {
            $ModelDigits = $Matches[1]
            $ModelSuffix = $Matches[2]

            if ($ModelDigits.Length -ge 2) {
                $SkuPrefix = $ModelDigits.Substring(0, 2)

                switch -Regex ($SkuPrefix) {
                    "^(85|65|55)$" {
                        $Hints.CodeNames += "Emerald Rapids-SP"
                        $Hints.ExpectedPatterns += @("8500/6500/5500", "6500/5500", "Emerald-Rapids-SP", "Emerald Rapids")
                    }
                    "^(84|64|54|44|34)$" {
                        $Hints.CodeNames += "Sapphire Rapids-SP"
                        $Hints.ExpectedPatterns += @("8400/6400/5400", "6400/5400", "Sapphire-Rapids-SP", "Sapphire Rapids")
                    }
                    "^(83|63|53|43)$" {
                        if ($ModelSuffix -match "H") {
                            $Hints.CodeNames += "Cooper Lake-SP"
                            $Hints.ExpectedPatterns += @("8300/6300/5300", "6300/5300", "Cooper-Lake-SP", "Cooper Lake")
                        }
                        else {
                            $Hints.CodeNames += "Ice Lake-SP"
                            $Hints.ExpectedPatterns += @("8300/6300/5300", "6300/5300", "Ice-Lake-SP", "Ice Lake")
                        }
                    }
                    "^(62|52|42|32|82)$" {
                        $Hints.CodeNames += "Cascade Lake-SP"
                        $Hints.ExpectedPatterns += @("8200/6200/5200", "6200/5200", "Cascade-Lake-SP", "Cascade Lake")
                    }
                    "^(61|51|41|31|81)$" {
                        $Hints.CodeNames += "Skylake-SP"
                        $Hints.ExpectedPatterns += @("8100/6100/5100", "6100/5100", "Skylake-SP", "Skylake")
                    }
                }
            }
        }
    }

    return [PSCustomObject]$Hints
}

function Get-ScoredCpuCandidates {
    param($CPUList, [string]$FullCpuName)

    $Hints = Get-CpuMatchHints -FullCpuName $FullCpuName
    $SearchTerm = ($FullCpuName -replace "\(R\)|\(TM\)|CPU|@.*$|Processor|Intel|AMD", "").Trim()
    $Words = $SearchTerm -split "\s+" | Where-Object { $_.Length -gt 2 -and $_ -notin @("EPYC", "Xeon", "Core") }

    $ScoredMatches = foreach ($Series in $CPUList) {
        $SeriesName = $Series.cpuSeries.name
        $Score = 0
        $Reasons = @()

        if ($Hints.Vendor -and $SeriesName -like "*$($Hints.Vendor)*") {
            $Score += 20
            $Reasons += "vendor:$($Hints.Vendor)"
        }

        if ($Hints.ProductLine -and $SeriesName -like "*$($Hints.ProductLine)*") {
            $Score += 25
            $Reasons += "line:$($Hints.ProductLine)"
        }

        foreach ($Pattern in $Hints.ExpectedPatterns) {
            if ($SeriesName -like "*$Pattern*") {
                $Score += if ($Pattern -match "Lake|Rapids|Skylake") { 150 } else { 100 }
                $Reasons += "pattern:$Pattern"
            }
        }

        if ($Hints.ModelNumber -and $SeriesName -like "*$($Hints.ModelNumber)*") {
            $Score += 75
            $Reasons += "model:$($Hints.ModelNumber)"
        }

        foreach ($Word in $Words) {
            if ($SeriesName -like "*$Word*") {
                $Score += if ($Word -match "\d") { 40 } else { 5 }
                $Reasons += "word:$Word"
            }
        }

        if ($Score -gt 0) {
            [PSCustomObject]@{
                Score     = $Score
                CpuSeries = $SeriesName
                UUID      = $Series.uuid
                Reasons   = $Reasons -join ", "
                RawObject = $Series
            }
        }
    }

    return $ScoredMatches
}

function Find-VCGCPU {
    param($CPUList, [string]$FullCpuName)

    $BestMatch = Get-ScoredCpuCandidates -CPUList $CPUList -FullCpuName $FullCpuName |
        Sort-Object Score -Descending |
        Select-Object -First 1

    if ($BestMatch -and $BestMatch.Score -ge 75) {
        return $BestMatch.RawObject
    }

    return $null
}

function Export-CompatibilityReport {
    param([System.Collections.ArrayList]$ReportData, [string]$ClusterName)
    $Timestamp = Get-Date -Format "yyyyMMdd_HHmm"
    $FileName = "ESXi_Upgrade_Check_$($ClusterName)_$($Timestamp).csv"
    $ReportData | Export-Csv -Path $FileName -NoTypeInformation -Delimiter ";" -Encoding UTF8
    Write-Host "`n[OK] Rapport opgeslagen: $FileName" -ForegroundColor Green
}

# --- AANGEPASTE OVERLAP LOGICA VOOR CPU ---
function Export-FirmwareOverlapReport {
    param($ReportData, [string]$ClusterName, [string]$TargetVersion)
    
    $OverlapResults = $ReportData | Group-Object HostName, Device | ForEach-Object {
        $DeviceEntries = $_.Group
        $DeviceName = $DeviceEntries[0].Device
        
        # Check of dit een CPU entry is
        if ($DeviceName -like "CPU:*") {
            $TargetStatus = $DeviceEntries | Where-Object { $_.ESXiVersion -eq $TargetVersion } | Select-Object -ExpandProperty DriverName
            $IsSupported = ($TargetStatus -eq "SUPPORTED")

            [PSCustomObject]@{
                HostName       = $DeviceEntries[0].HostName
                Device         = $DeviceName
                CommonFirmware = "N/A (CPU Check)"
                UpgradeNeeded  = if ($IsSupported) { "No - CPU is Supported" } else { "YES - CPU NOT SUPPORTED FOR $TargetVersion" }
                BCL_Link       = $DeviceEntries[0].BCL_Link
            }
        }
        else {
            # Originele Hardware Logica
            $FW_v8 = $DeviceEntries | Where-Object { $_.ESXiVersion -eq "8.0 U3" } | ForEach-Object { $_.Firmware -split " " } | Select-Object -Unique
            $FW_v9 = $DeviceEntries | Where-Object { $_.ESXiVersion -eq $TargetVersion } | ForEach-Object { $_.Firmware -split " " } | Select-Object -Unique
            $CommonFirmware = $FW_v8 | Where-Object { $FW_v9 -contains $_ -and $_ -ne "N/A" }

            [PSCustomObject]@{
                HostName       = $DeviceEntries[0].HostName
                Device         = $DeviceName
                CommonFirmware = if ($CommonFirmware) { $CommonFirmware -join ", " } else { "NO OVERLAP FOUND" }
                UpgradeNeeded  = if ($CommonFirmware) { "No - Common FW available" } else { "Yes - Firmware change required" }
                BCL_Link       = $DeviceEntries[0].BCL_Link
            }
        }
    }

    $Timestamp = Get-Date -Format "yyyyMMdd_HHmm"
    $FileName = "Firmware_Upgrade_Strategy_$($ClusterName)_$($Timestamp).csv"
    $OverlapResults | Export-Csv -Path $FileName -NoTypeInformation -Delimiter ";" -Encoding UTF8
    Write-Host "[OK] Strategie rapport opgeslagen: $FileName" -ForegroundColor Cyan
}

# --- MAIN EXECUTION ---
$vCenterName = Read-Host 'Enter vCenter FQDN'
Connect-VIServer -Server $vCenterName

Write-Host "Ophalen VCG CPU Masterlijst..." -ForegroundColor Gray
$CpuBodyObj = @{ programId = "cpu"; filters = @(); keyword = @(); date = @{ startDate = $null; endDate = $null } } | ConvertTo-Json

try {
    $GlobalCPUList = (Invoke-RestMethod -Uri "https://compatibilityguide.broadcom.com/compguide/programs/viewResults?limit=500&page=1" -Method Post -Body $CpuBodyObj -Headers @{"content-type"="application/json";"user-persona"="live"}).data.fieldValues
} catch {
    Write-Error "Kon CPU Masterlijst niet ophalen."
}

$Clusters = Get-Cluster
foreach ($cluster in $Clusters) {
    $ClusterName = $cluster.Name
    $TargetVersions = @("8.0 U3", $TargetVersion)
    $Hosts = Get-ClusterHosts -ClusterName $ClusterName

    if ($Hosts) {
        $FullReport = foreach ($ESXiHost in $Hosts) {
            Write-Host "`n>>> Processing Host: $($ESXiHost.Name)" -ForegroundColor Cyan
            
            # --- CPU CHECK ---
            $FullCpuName = $ESXiHost.ExtensionData.Summary.Hardware.CpuModel
            $SearchTerm = ($FullCpuName -replace "\(R\)|\(TM\)|CPU|@.*$|Processor|Intel|AMD", "").Trim()
            
            $MatchedCpu = $null
            if ($GlobalCPUList) {
                $MatchedCpu = Find-VCGCPU -CPUList $GlobalCPUList -FullCpuName $FullCpuName
            }

            if ($MatchedCpu) {
                Write-Host "    VCG CPU Series match: $($MatchedCpu.cpuSeries.name)" -ForegroundColor Gray
            }
            else {
                $CpuHints = Get-CpuMatchHints -FullCpuName $FullCpuName
                if ($CpuHints.ExpectedPatterns.Count -gt 0) {
                    Write-Warning "Geen passende VCG CPU Series gevonden voor CPU: $FullCpuName. Geprobeerde hints: $($CpuHints.ExpectedPatterns -join ', ')"
                }
                else {
                    Write-Warning "Geen passende VCG CPU Series gevonden voor CPU: $FullCpuName"
                }
            }

            foreach ($Ver in $TargetVersions) {
                if ($MatchedCpu) {
                    Write-Host "    Checking $Ver for CPU: $SearchTerm..." -NoNewline
                    $CpuRes = Get-VCGCPUStatus -CpuId $MatchedCpu.uuid -Ver $Ver -HostName $ESXiHost.Name -FullCpuName $FullCpuName
                    if ($CpuRes) {
                        $StatusColor = if ($CpuRes.DriverName -eq "SUPPORTED") { "Green" } else { "Red" }
                        Write-Host " [$($CpuRes.DriverName)]" -ForegroundColor $StatusColor
                        $CpuRes
                    }
                }
            }

            # --- HARDWARE CHECK ---
            $esxcli = Get-EsxCli -VMHost $ESXiHost -V2
            $HardwarePCIList = $esxcli.hardware.pci.list.Invoke()
            $UniqueHardwareList = $HardwarePCIList | Where-Object {
                $_.DeviceClassName -match "Network|Ethernet|Storage|RAID|SCSI|Fibre Channel" -and
                $_.DeviceClassName -notmatch "Bridge|Peripheral|Hub"
            } | Group-Object VendorID, DeviceID, SubVendorID, SubDeviceID | ForEach-Object { $_.Group[0] }

            foreach ($Hw in $UniqueHardwareList) {
                $VID  = ("{0:X4}" -f [int]$Hw.VendorID).ToLower()
                $DID  = ("{0:X4}" -f [int]$Hw.DeviceID).ToLower()
                $SVID = ("{0:X4}" -f [int]$Hw.SubVendorID).ToLower()
                $SDID = ("{0:X4}" -f [int]$Hw.SubDeviceID).ToLower()

                foreach ($Ver in $TargetVersions) {
                    Write-Host "    Checking $Ver for $($Hw.DeviceName)..." -NoNewline
                    $Res = Get-VCGComparison -VID $VID -DID $DID -SVID $SVID -SDID $SDID -DeviceName $Hw.DeviceName -Ver $Ver -HostName $ESXiHost.Name
                    if ($Res) { Write-Host " [OK]" -ForegroundColor Green; $Res } else { Write-Host " [NO DATA]" -ForegroundColor Yellow }
                }
            }
        }

        if ($FullReport) {
            Export-CompatibilityReport -ReportData $FullReport -ClusterName $ClusterName
            Export-FirmwareOverlapReport -ReportData $FullReport -ClusterName $ClusterName -TargetVersion $TargetVersion
        }
    }
}
Disconnect-VIServer -Server * -Confirm:$false 