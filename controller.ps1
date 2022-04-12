Param(
    [string]$action,
    [string]$vmID
)

Disable-AzContextAutosave -Scope Process | Out-Null


# Log Analytics Functions
Function buildLogAnalyticsSignature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource) {
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId, $encodedHash
    return $authorization
}

# Create the function to create and post the request
Function postLogAnalyticsData($body, $logType) {
    if ($null -eq $global:law) {
        $global:law = getLAWDetails
    }
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = buildLogAnalyticsSignature `
        -customerId ($global:law).workspaceId `
        -sharedKey ($global:law).workspaceKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + ($global:law).workspaceId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

    $headers = @{
        "Authorization"        = $signature;
        "Log-Type"             = $logType;
        "x-ms-date"            = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    }

    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode
}

function getLAWDetails() {
    $lawRG = (Get-AutomationVariable -Name "LAW_RG")
    $lawName = (Get-AutomationVariable -Name "LAW_Name")
    $lawObject = Get-AzOperationalInsightsWorkspace -ResourceGroupName $lawRG -Name $lawName
    $key = ($lawObject | Get-AzOperationalInsightsWorkspaceSharedKey).PrimarySharedKey
    $customerId = $lawObject.CustomerId
    return @{
        workspaceId  = $customerId
        workspaceKey = $key
    }
}

$subId = $vmId.Split('/')[2]

try {
    $AzureContext = (Connect-AzAccount -Identity -Subscription $subId).context
}
catch {
    Write-Output "There is no system-assigned user identity. Aborting."; 
    exit
}

if($action -eq "Start"){
    Start-AzVM -Id $vmID
	$timeNow =  (Get-Date -Format "dd/MM/yyyy hh:mm")
	Update-AzTag -ResourceId $vmID -Tag @{csLastRun = $timeNow} -Operation Merge
} elseif ($action -eq "Stop"){
    Stop-AzVM -Id $vmID -Force
}

$body = @{
    vmId = $vmID
    action = $action
}
$body = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 100 -Compress))
postLogAnalyticsData -body $body -logType "csRuns"
