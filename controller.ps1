Param(
    [string]$action,
    [string]$vmID
)

Disable-AzContextAutosave -Scope Process | Out-Null

$subId = $vmId.Split('/')[2]

try {
    $AzureContext = (Connect-AzAccount -Identity -Subscription $subId).context
}
catch {
    Write-Output "There is no system-assigned user identity. Aborting."; 
    exit
}

if($action -eq "Start"){
    Start-AzVM -Id "$vmID"
} elseif ($action -eq "Stop"){
    Stop-AzVM -Id "$vmID" -Force
}