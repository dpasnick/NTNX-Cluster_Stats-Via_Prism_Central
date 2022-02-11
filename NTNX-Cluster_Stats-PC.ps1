#################################################################################################
#
# NTNX-Cluster_Stats-PC.ps1
# Modified: 08/25/21
# Version:  2.1
#
# Description: This script utalizes several API calls from both Prism Central and Prism Element 
#              to pull the following cluster summary information.
#               - Cluster UUID
#               - Cluster Name
#               - Cluster IOPS (average over the last hour)
#               - Cluster Latency (average over the last hour)
#               - Cluster CPU Utilization (average over the last hour)
#               - Cluster Memory Utilization (average over the last hour)
#               - Storage Utalization Total  (average over the last hour)
#               - RF2 Standards Storage Utalization Total (immediate at time of script run)
#                 -- Note: due to manual calculations in the script raw data pulled from 
#                          individual Prism Element instances.
#
# Requires: 
#           - Administrative account (either local or AD) as required by specific Rest API calls.
#             - Assumes both PC and Prism administrative accounts are the same.
#           - CSV file listing the Prism Central instance IP addressed which is outlined on line 32
#              -- Required column heading is 'PCVIP'
#              -- Variable: $fileCSV
#           - Filename and path for saved Excep spreadsheet output.
#              - Variable: $filepath
#
#################################################################################################

#$ErrorActionPreference = "silentlycontinue"

# Clusters to be run (CSV file pulls IP Address from column with the name of 'PC'
$fileCSV = $(get-location).Path + "\Nutanix-PC_Lookup.csv"

# Path and name of the saved Excel spreadsheet
$filepath = $(get-location).Path + "\Nutanix_Cluster_Summary-PC-Report-$Today.xlsx"

# CHANGE THESE LINES to set authentication (requires administrator credentials - either local or AD)
#$username = "admin"


# ------------------- Change Variables Above ------------------- 

# Variable to determine if script failed to run
$failedRun = $null

# Initial Screen Messaging
clear;
Write-Host "Cluster Stats via Prism Central Run: $dateToday"
Write-Host "This script will use '$fileCSV' to pull cluster information.`n" -ForegroundColor Yellow

# Username input - either local account or AD account if cluster is configured
$username = Read-Host -Prompt 'Enter cluster(s) administrative username.'

# Ask for password
$securePassword = Read-Host -Prompt "Enter $username password." -AsSecureString
$password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword))

# Create the HTTP Basic Authorization header
$pair = $username + ":" + $password
$bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
$base64 = [System.Convert]::ToBase64String($bytes)
$basicAuthValue = "Basic $base64"

# Setup the request headers
$headers = @{
    'Accept' = 'application/json'
    'Authorization' = $basicAuthValue
    'Content-Type' = 'application/json'
}

Add-Type @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                return true;
            }
        }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Set a sensible timeout
$timeout = 5

# Set date for log file
$dateToday = (Get-Date).toshortdatestring().Replace("/","-")


# Functions
# Function to connect to PC and pull raw storage date to calculate NT standards
function getRF2storage ($ip, $cluster) {
    # Individual Cluster PE API URL
    $uriRF2storage = "https://" + $ip + ":9440/PrismGateway/services/rest/v1/storage_pools"
    
    # Individual Cluster PE API Call
    $resultRF2storage = (Invoke-RestMethod -Uri $uriRF2storage -Headers $headers -Method GET -TimeoutSec $timeout)

    # Calculate Total Storage Usage (RF2 & .80)
    $totalCapacity = ((($resultRF2storage.entities.capacity / 2) / 1099511627776) * .80)

    # Calculate Total Storage Usage (RF2)
    $usedCapacity = (($resultRF2storage.entities.usageStats.'storage.usage_bytes' / 2) / 1099511627776)

    # Total Usage Considering RF2 Standards
    $resultRF2storage = [math]::Round((($usedCapacity / $totalCapacity) * 100))

    # Return Value
    return $resultRF2storage
}
# End Functions


Write-Output "`nRun on $dateToday"


# Create Array Objects For Pulling All Data
$updatePCresults = New-Object System.Collections.ArrayList($null)
$updateCLUSTERmetaResults = New-Object System.Collections.ArrayList($null)


# Import all clusters to be upgraded from the CSV file
$csv = Import-Csv "$fileCSV"


# Attempt to connect to all PC instances and pull stats
try {

    # Run through each Prism Central Instance and pull API payloads.
    foreach ($PC in $csv) {
        $ip = $($PC.PCVIP)

        Write-Host "`nConnecting to Prism Central instance $ip ...`n" -foregroundColor Yellow
        Write-Host "  - Triggering REST API for $ip..." -foregroundColor Green
    
        # Body Values for POST Rest Method for Invoike Rest Method   
        $postParams_CPU = (@{downsampling_interval=300; entity_type="cluster"; group_member_attributes=@(@{attribute="cluster_name"}; @{attribute="hypervisor_cpu_usage_ppm"; operation="AVG"}); group_member_sort_attribute="cluster_name"; group_member_sort_order="ASCENDING"} | ConvertTo-Json)
        $postParams_Memory = (@{downsampling_interval=300; entity_type="cluster"; group_member_attributes=@(@{attribute="cluster_name"}; @{attribute="hypervisor_memory_usage_ppm"; operation="AVG"}); group_member_sort_attribute="cluster_name"; group_member_sort_order="ASCENDING"} | ConvertTo-Json)
        $postParams_Storage = (@{downsampling_interval=300; entity_type="cluster"; group_member_attributes=@(@{attribute="cluster_name"}; @{attribute="percentage_used_storage"};); group_member_sort_attribute="cluster_name"; group_member_sort_order="ASCENDING"} | ConvertTo-Json)
        $postParams_Latency = (@{downsampling_interval=300; entity_type="cluster"; group_member_attributes=@(@{attribute="cluster_name"}; @{attribute="controller_avg_io_latency_usecs"; operation="AVG"}); group_member_sort_attribute="cluster_name"; group_member_sort_order="ASCENDING"} | ConvertTo-Json)
        $postParams_IOPS = (@{downsampling_interval=300; entity_type="cluster"; group_member_attributes=@(@{attribute="cluster_name"}; @{attribute="controller_num_iops"; operation="AVG"}); group_member_sort_attribute="cluster_name"; group_member_sort_order="ASCENDING"} | ConvertTo-Json)
        $getUUIDcluster_body = (@{kind="cluster"} | ConvertTo-Json)

        # Set API URL Calls
        $uriPC = "https://" + $ip + ":9440/api/nutanix/v3/groups"
        $uriCLUSTERdetails = "https://" + $ip + ":9440/api/nutanix/v3/clusters/list"

        # Invoke REST method for Prisn Central
        $resultPC_CPU = (Invoke-RestMethod -Uri $uriPC -Headers $headers -Method POST -Body $postParams_CPU -TimeoutSec $timeout)
        $resultPC_Memory = (Invoke-RestMethod -Uri $uriPC -Headers $headers -Method POST -Body $postParams_Memory -TimeoutSec $timeout)
        $resultPC_Storage = (Invoke-RestMethod -Uri $uriPC -Headers $headers -Method POST -Body $postParams_Storage -TimeoutSec $timeout)
        $resultPC_Latency = (Invoke-RestMethod -Uri $uriPC -Headers $headers -Method POST -Body $postParams_Latency -TimeoutSec $timeout)
        $resultPC_IOPS = (Invoke-RestMethod -Uri $uriPC -Headers $headers -Method POST -Body $postParams_IOPS -TimeoutSec $timeout)
        $resultCLUSTERmeta = (Invoke-RestMethod -Uri $uriCLUSTERdetails -Headers $headers -Method POST -Body $getUUIDcluster_body -TimeoutSec $timeout)
    

        # Grab list of Cluster Names, External IPs and UUID Values for Main Results Table
        for ($i=0; $i -lt ($resultCLUSTERmeta.entities.count); $i++) {
            $CLUSTERmeta_Lookup = [ordered]@{
                cluster_Name = $resultCLUSTERmeta.entities.status.name[$i];
                cluster_IP = $resultCLUSTERmeta.entities.spec.resources.network.external_ip[$i];
                cluster_UUID = $resultCLUSTERmeta.entities.metadata.uuid[$i];            
            }
            $updateCLUSTERmetaResults.Add((New-Object PSObject -Property $CLUSTERmeta_Lookup)) | Out-Null
        }

        
        # Grab Statistics From Each Cluster Incorporating UUID From Above
        $hostcount=1
        for ($i=0; $i -lt ($resultPC_CPU.group_results.entity_results.data.values.values.count/2); $i++) {
        
            # Set Individual Cluster IP and UUID for Results and NT Storage Standard Usage
            $clusterIP = $updateCLUSTERmetaResults.where{$_.cluster_Name -eq $resultPC_CPU.group_results.entity_results.data.values.values[$hostcount-1]}.cluster_IP
            $clusterUUID = $updateCLUSTERmetaResults.where{$_.cluster_Name -eq $resultPC_CPU.group_results.entity_results.data.values.values[$hostcount-1]}.cluster_UUID
        
            # Calculate NT Storage Usage from Individual Cluster Stats - Function Call
            $RF2Storage = getRF2storage $clusterIP $resultPC_CPU.group_results.entity_results.data.values.values[$hostcount-1]
        
            # Put Results Into an Array
            $pcInfo = [ordered]@{
                UUID = $clusterUUID;
                External_IP = $clusterIP;
                Cluster = $resultPC_CPU.group_results.entity_results.data.values.values[$hostcount-1];
                IOPS = ($resultPC_IOPS.group_results.entity_results.data.values.values[$hostcount]).ToString();
                Latency = ($resultPC_Latency.group_results.entity_results.data.values.values[$hostcount] / 1000).ToString("#.##") + 'ms';
                CPU = ($resultPC_CPU.group_results.entity_results.data.values.values[$hostcount] / 10000).ToString("#.##") + '%';
                Memory = ($resultPC_Memory.group_results.entity_results.data.values.values[$hostcount] / 10000).ToString("#.##") + '%';
                Storage = ($resultPC_Storage.group_results.entity_results.data.values.values[$hostcount]).ToString() + '%';
                RF2_Storage = $RF2Storage.ToString() + '%';
            }
            $hostcount=$hostcount + 2

            # Update Master Array Object with Individual Cluster Information
            $updatePCresults.Add((New-Object PSObject -Property $pcInfo)) | Out-Null
            Start-Sleep -m 250
        }
        Write-Host "  - Completed REST API Call for $ip..." -foregroundColor Green
        Start-Sleep -m 100

    }

    Write-Output $updatePCresults | ft

# If error connecting or while running stop script and catch errors
} catch {

    Write-Host "`n`n*************************************************************************" -ForegroundColor Red
    Write-Host "Error Type: " $_.Exception.Message -ForegroundColor Red
    Write-Host "Error Line: " $_.InvocationInfo.ScriptLineNumber -ForegroundColor Red
    Write-Host "Failed For: " $ip -ForegroundColor Red
    Write-Host "*************************************************************************`n`n" -ForegroundColor Red

    $failedRun = "True"

}


# Save to Excel
if (!$failedRun) {
    $excelApp = New-Object -ComObject Excel.Application
    $excelApp.Visible = $True
    $workBook = $excelApp.Workbooks.Add()

    $workSheet = $workBook.Worksheets.Item(1)
    $workSheet.Rows.HorizontalAlignment = -4131 
    $workSheet.Rows.Font.Size = 10
    $workSheet.Name = "Cluster Stats"
    $row = $col = 1
    $hostXLHead = ("UUID","External_IP","Cluster","IOPS","Latency","CPU","Memory","Storage","RF2_Storage")
    $hostXLHead | %( $_  ){ $workSheet.Cells.Item($row,$col) = $_ ; $col++ }
    $workSheet.Rows.Item(1).Font.Bold = $True
    $workSheet.Rows.Item(1).HorizontalAlignment = -4108
    $workSheet.Rows.Item(1).Borders.Item(9).Weight = 2
    $workSheet.Rows.Item(1).Borders.Item(9).LineStyle = 1

    $i = 0; $row++; $col = 1
    FOREACH( $updateResult in $updatePCResults ){ 
        $i = 0
        DO{ 
            $workSheet.Cells.Item($row,$col) = $updateResult.($hostXLHead[$i])
            $col++
            $i++ 
        }UNTIL($i -ge $hostXLHead.Count)
        $row++; $col=1
        Start-Sleep -m 200
    } 
    $workSheet.UsedRange.EntireColumn.AutoFit()

    #Save Excel Workbook
    $Date = Get-Date
    $Today = (Get-Date).toshortdatestring().Replace("/","-")
    #$filepath = $(get-location).Path + "/Reports/Nutanix_Cluster_Summary-PC-Report-$Today.xlsx"
    $excelApp.DisplayAlerts = $False
    $workBook.SaveAs($filepath)
    $excelApp.Quit()
    Write-Host "`nFile Saved to: $filepath" -foregroundColor Yellow
}
# End Excel

# Cleanup
Remove-Variable username -ErrorAction SilentlyContinue
Remove-Variable securePassword -ErrorAction SilentlyContinue
Remove-Variable password -ErrorAction SilentlyContinue
# End Cleanup
