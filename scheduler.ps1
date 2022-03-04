function findSlot([int]$timeFrame, $slots) {
    $adjacent = $timeFrame / 30
    $mergedSlots = @()
    foreach ($slot in $slots) {
        $startTime = $slot.from
        $endTime = $slot.to
        $intensity = 0
        $currentIndex = $slots.IndexOf($slot)
        for ($i = 0; $i -lt ($adjacent); $i++) {
            $intensity += [int]$slots[($currentIndex + $i)].intensity.forecast
            $endTime = $slots[($currentIndex + $i)].to
        }
        $averageIntensity = $intensity / $adjacent
        if ($endTime -ne $null) {
            $object = [PSCustomObject]@{
                startTime = $startTime
                endTime   = $endTime
                intensity = $averageIntensity
            }
            Write-Debug ("We have combined slot starting at {0}, finishing at {1} and total intensity of {2}" -f $startTime, $endTime, $averageIntensity)
            $mergedSlots += $object
        }
    }
    return $mergedSlots
}

function getSlots($ciRegion) {    
    Write-Debug ("Requesting data for region {0} for date {1}." -f $ciRegion, $dateNow)
    $uri = ("https://api.carbonintensity.org.uk/regional/intensity/{0}/fw48h/regionid/{1}" -f $dateNow, $region.ciRegion)
    Write-Debug ("REST URI: {0}" -f $uri)
    $data = Invoke-RestMethod -Method Get -Uri $uri -Headers @{Accept = 'application/json' }
    if ($data.Length -gt 0) {
        Write-Debug "Successfully got data."
    }
    else {
        Write-Error "Error getting data."
    }
    return $data.data.data
}

$regions = @(
    [PSCustomObject]@{
        azureRegion = 'uksouth'
        ciRegion    = 13
    },
    @{
        azureRegion = 'ukwest'
        ciRegion    = 7
    }
)

# Create Times
$maxTime = "600" #10 hours
$times = @()
for ($i = 30; $i -le $maxTime; $i = $i + 30) {
    $times += ("{0}m" -f $i)
}

$slotsFound = @()
$dateNow = Get-Date -f o
foreach ($region in $regions) {
    $slots = getSlots($region.ciRegion)
    Write-Debug "Working out best times to run."
    $greenSlots = [PSCustomObject] @{}
    foreach ($time in $times) {
        $greenSlotName = $time
        $greenSlotInt = [int]$greenSlotName.Replace('m', '')
        $slotsForTime = findSlot -timeFrame $greenSlotInt -slots $slots
        $greenSlotBest = $slotsForTime | Sort-Object intensity | Select-Object -First 1
        $greenSlots | Add-Member -Name $time -Value $greenSlotBest -MemberType NoteProperty
    }
    $slotsFound += [PSCustomObject]@{
        azureRegion = $region.azureRegion
        ciRegion    = $region.ciRegion
        bestSlots   = $greenSlots
    }
}

# $resourceGraphQuery = @"
# resources
# | where ['tags'] contains "csLength"
# | extend csLength=tags.csLength
# | extend csFrequency=tags.csFrequency
# | extend csLastRun=tags.csLastRun
# | extend csStartTime=tags.csStartTime
# | extend csEndTime=tags.csEndTime
# | project id, name, type, location, csLength, csFrequency, csLastRun, csStartTime, csEndTime
# "@
# $queryResults = Search-AzGraph -Query $resourceGraphQuery

# if ($queryResults -gt 0) {
#     Write-Debug ("Returned {0} Resources" -f $queryResults.length)
#     foreach ($resource in $queryResults) {
#         Write-Debug ("Reviewing {0} that has csLength of {1} and csFrequency of {2}." -f $resource.name, $resource.csLength, $resource.csFrequency)
#         if($resource.csLastRun -eq $null){
#             Write-Debug ("This resource does not have a last run value.")
#             $resource.csLastRun = (Get-Date).Date.AddDays(-1)
#             New-AzTag -ResourceId $resource.Id -Tag @{csLastRun = $resource.csLastRun}
#         }
#         switch ($resource.csFrequency).substring(($resource.csFrequency).length-1,1) {
#             "d" { 
#                 if($resource.csStartTime -eq $null){
#                     $resource.csStartTime = "00:00"
#                 }
#                 $lastPossibleHour = ($resource.csStartTime).Split(':')[0]
#                 $lastPossibleMinute = ($resource.csStartTime).Split(':')[1]
#                 $lastPossible = Get-Date -Day $resource.csLastRun.Day -Month $resource.csLastRun.Day
#                 $desiredWindow = Get-Date 
#                 # Was the last time we ran in the last day?
#                 if($resource.csLastRun -lt $)
#              }
#             Default {}
#         }
#     }
# }