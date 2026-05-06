# ==============================================================================================
# ESXi Upgrade Compatibility Tool (8.0 U3 -> 9.x) - Inclusief CPU & Correcte Strategie
# ==============================================================================================

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

function Export-CompatibilityReport {
    param([System.Collections.ArrayList]$ReportData, [string]$ClusterName)
    $Timestamp = Get-Date -Format "yyyyMMdd_HHmm"
    $FileName = "ESXi_Upgrade_Check_$($ClusterName)_$($Timestamp).csv"
    $ReportData | Export-Csv -Path $FileName -NoTypeInformation -Delimiter ";" -Encoding UTF8
    Write-Host "`n[OK] Rapport opgeslagen: $FileName" -ForegroundColor Green
}

# --- AANGEPASTE OVERLAP LOGICA VOOR CPU ---
function Export-FirmwareOverlapReport {
    param($ReportData, [string]$ClusterName)
    
    $OverlapResults = $ReportData | Group-Object HostName, Device | ForEach-Object {
        $DeviceEntries = $_.Group
        $DeviceName = $DeviceEntries[0].Device
        
        # Check of dit een CPU entry is
        if ($DeviceName -like "CPU:*") {
            $TargetStatus = $DeviceEntries | Where-Object { $_.ESXiVersion -eq "9.0" } | Select-Object -ExpandProperty DriverName
            $IsSupported = ($TargetStatus -eq "SUPPORTED")

            [PSCustomObject]@{
                HostName       = $DeviceEntries[0].HostName
                Device         = $DeviceName
                CommonFirmware = "N/A (CPU Check)"
                UpgradeNeeded  = if ($IsSupported) { "No - CPU is Supported" } else { "YES - CPU NOT SUPPORTED FOR 9.0" }
                BCL_Link       = $DeviceEntries[0].BCL_Link
            }
        }
        else {
            # Originele Hardware Logica
            $FW_v8 = $DeviceEntries | Where-Object { $_.ESXiVersion -eq "8.0 U3" } | ForEach-Object { $_.Firmware -split " " } | Select-Object -Unique
            $FW_v9 = $DeviceEntries | Where-Object { $_.ESXiVersion -eq "9.0" }    | ForEach-Object { $_.Firmware -split " " } | Select-Object -Unique
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
Connect-VIServer -Server "XXXXX"

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
    $TargetVersions = @("8.0 U3", "9.0") 
    $Hosts = Get-ClusterHosts -ClusterName $ClusterName

    if ($Hosts) {
        $FullReport = foreach ($ESXiHost in $Hosts) {
            Write-Host "`n>>> Processing Host: $($ESXiHost.Name)" -ForegroundColor Cyan
            
            # --- CPU CHECK ---
            $FullCpuName = $ESXiHost.ExtensionData.Summary.Hardware.CpuModel
            $SearchTerm = ($FullCpuName -replace "\(R\)|\(TM\)|CPU|@.*$|Processor|Intel|AMD", "").Trim()
            $Words = $SearchTerm -split " " | Where-Object { $_.Length -gt 2 }
            
            $MatchedCpu = $null
            if ($GlobalCPUList) {
                foreach ($Series in $GlobalCPUList) {
                    $MatchCount = 0
                    foreach ($Word in $Words) { if ($Series.cpuSeries.name -like "*$Word*") { $MatchCount++ } }
                    if ($MatchCount -ge 1) { $MatchedCpu = $Series; break }
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
            Export-FirmwareOverlapReport -ReportData $FullReport -ClusterName $ClusterName
        }
    }
}
Disconnect-VIServer -Server * -Confirm:$false 