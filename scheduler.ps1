function findSlot($timeFrame, $slots) {
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

function calculateAverageIntensity($slots) {
    $total = 0
    foreach ($slot in $slots) {
        $total += $slot.intensity
    }
    $average = $total / $slots.Length
    return $average
}

function bestSlot($slots,$minutes,$startTime,$endTime) {
    $targetedSlots = findSlot -slots $slots -timeFrame $minutes
    # Convert timedate to correct format
    $startTimeFormatted = $startTime | Get-Date -UFormat "%Y-%m-%dT%H:%MZ"
    $endTimeFormatted = $endTime | Get-Date -UFormat "%Y-%m-%dT%H:%MZ"
    $targetedSlots = $targetedSlots | Where-Object { $_.startTime -ge $startTimeFormatted -and $_.endTime -le $endTimeFormatted }
    $chosenSlot = $targetedSlots | sort-object intensity | Select-Object -First 1
    $averageIntensity = calculateAverageIntensity -slots $targetedSlots
    $chosenSlot | Add-Member -Name "averageIntensity" -Value $averageIntensity -MemberType NoteProperty
    return $chosenSlot
}

function greenSlots($slots){
    $greenSlots = [PSCustomObject] @{}
    foreach ($time in $times) {
        $greenSlotName = $time
        $greenSlotInt = [int]$greenSlotName.Replace('m', '')
        $slotsForTime = findSlot -timeFrame $greenSlotInt -slots $slots
        $greenSlotBest = $slotsForTime | Sort-Object intensity | Select-Object -First 1
        $greenSlots | Add-Member -Name $time -Value $greenSlotBest -MemberType NoteProperty
    }
    return $greenSlots
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
    $greenSlots = greenSlots($slots)
    $slotsFound += [PSCustomObject]@{
        azureRegion = $region.azureRegion
        ciRegion    = $region.ciRegion
        slots = $slots
        greenSlots   = $greenSlots
    }
}

$resourceGraphQuery = @"
resources
| where ['tags'] contains "csLength"
| extend csLength=tags.csLength
| extend csFrequency=tags.csFrequency
| extend csLastRun=tags.csLastRun
| extend csStartTime=tags.csStartTime
| extend csEndTime=tags.csEndTime
| extend csLastWindow=tags.csLastWindow
| project id, name, type, location, csLength, csFrequency, csLastRun, csStartTime, csEndTime, csLastWindow
"@
$queryResults = Search-AzGraph -Query $resourceGraphQuery

if ($queryResults.length -gt 0) {
    Write-Debug ("Returned {0} Resources" -f $queryResults.length)
    foreach ($resource in $queryResults) {
        Write-Debug ("Reviewing {0} that has csLength of {1} and csFrequency of {2}." -f $resource.name, $resource.csLength, $resource.csFrequency)
        if($resource.csLastRun -eq $null){
            Write-Debug ("This resource does not have a last run value.")
            $resource.csLastRun = (Get-Date).Date.AddDays(($resource.csFrequency).substring(($resource.csFrequency).length-2,1))
            # New-AzTag -ResourceId $resource.Id -Tag @{csLastRun = $resource.csLastRun}
        } else {
            $resource.csLastRun = $resource.csLastRun | Get-Date
        }
        switch (($resource.csFrequency).substring(($resource.csFrequency).length-1,1)) {
            "d" { 
                if($resource.csStartTime -eq $null){
                    $resource.csStartTime = "00:00"
                }
                if($resource.csEndTime -eq $null)
                {
                    $resource.csEndTime = "00:00"
                }
                if($resource.csLastWindow -eq $null)
                {
                    # Calculate last window
                    $lastPossibleHour = ($resource.csStartTime).Split(':')[0]
                    $lastPossibleMinute = ($resource.csStartTime).Split(':')[1]
                    $lastPossible = Get-Date -Day $resource.csLastRun.Day -Month $resource.csLastRun.Month -Hour $lastPossibleHour -Minute $lastPossibleMinute -Second 00 -Millisecond 00
                    $resource.csLastWindow = $lastPossible
                }

                # Are we outside of the last window
                $lastWindowStart = $resource.csLastWindow
                $lastWindowEnd = $resource.csLastWindow.AddDays([int]$resource.csFrequency.Replace('d',''))
                $now = Get-Date
                # Is now outside of our window?
                if(!(($lastWindowStart -le $now) -and ($now -lt $lastWindowEnd))){
                    # Yes it is! Go find a slot
                    $startTime = Get-Date -Hour ($resource.csStartTime).Split(':')[0] -Minute ($resource.csStartTime).Split(':')[1] -Second 0 -Millisecond 0
                    $endTime = Get-Date -Hour ($resource.csEndTime).Split(':')[0] -Minute ($resource.csEndTime).Split(':')[1] -Second 0 -Millisecond 0
                    
                    # Are the times in the past?
                    if(($startTime -le $now) -and ($endTime -le $now)){
                        $startTime = $startTime.AddDays(1)
                        $endTime = $endTime.AddDays(1)
                    }

                    # May have an odd condition where 00:00 is the same day
                    if($startTime -eq $endTime){
                        $endTime = $endTime.AddDays(1)
                    }

                    $bestSlot = bestSlot -slots ($slotsFound | Where-Object {$_.azureRegion -eq $resource.location}).slots `
                    -minutes ($resource.csLength).Replace('m','') `
                    -startTime $startTime `
                    -endTime $endTime

                    # Check for a pre-existing schedule
                    $vmScheduleName = "{0} Scheduled Start" -f $resource.name
                    $schedule = Get-AzAutomationSchedule -Name $vmScheduleName `
                    -ResourceGroupName 'liam-rg-greendog' `
                    -AutomationAccountName 'liam-rg-greendog-aa' `
                    -ErrorAction SilentlyContinue

                    if(($schedule -eq $null) -or ($schedule.StartTime -ne $bestSlot.startTime)){
                        New-AzAutomationSchedule -ResourceGroupName 'liam-rg-greendog' `
                        -AutomationAccountName 'liam-rg-greendog-aa' `
                        -Name $vmScheduleName `
                        -StartTime $bestSlot.startTime `
                        -OneTime
                        
                        Unregister-AzAutomationScheduledRunbook -ResourceGroupName 'liam-rg-greendog' `
                        -AutomationAccountName 'liam-rg-greendog-aa' `
                        -ScheduleName $vmScheduleName `
                        -ErrorAction SilentlyContinue `
                        -RunbookName $vmScheduleName `
                        -Force
                        
                        Register-AzAutomationScheduledRunbook -Name 'CI-Controller' `
                        -ResourceGroupName 'liam-rg-greendog' `
                        -AutomationAccountName 'liam-rg-greendog-aa' `
                        -ScheduleName $vmScheduleName `
                        -Parameters @{
                            vmID = $resource.id
                            action = "Start"
                        }
                    }

                    $vmScheduleName = "{0} Scheduled Stop" -f $resource.name
                    $schedule = Get-AzAutomationSchedule -Name $vmScheduleName `
                    -ResourceGroupName 'liam-rg-greendog' `
                    -AutomationAccountName 'liam-rg-greendog-aa' `
                    -ErrorAction SilentlyContinue
                    if(($schedule -eq $null) -or ($schedule.StartTime -ne $bestSlot.endTime)){
                        New-AzAutomationSchedule -ResourceGroupName 'liam-rg-greendog' `
                        -AutomationAccountName 'liam-rg-greendog-aa' `
                        -Name $vmScheduleName `
                        -StartTime $bestSlot.endTime `
                        -OneTime

                        Unregister-AzAutomationScheduledRunbook -ResourceGroupName 'liam-rg-greendog' `
                        -AutomationAccountName 'liam-rg-greendog-aa' `
                        -ScheduleName $vmScheduleName `
                        -ErrorAction SilentlyContinue `
                        -RunbookName $vmScheduleName `
                        -Force

                        Register-AzAutomationScheduledRunbook -Name 'CI-Controller' `
                        -ResourceGroupName 'liam-rg-greendog' `
                        -AutomationAccountName 'liam-rg-greendog-aa' `
                        -ScheduleName $vmScheduleName `
                        -Parameters @{
                            vmID = $resource.id
                            action = "Stop"
                        }
                    }
                }

                # $lastPossibleHour = ($resource.csStartTime).Split(':')[0]
                # $lastPossibleMinute = ($resource.csStartTime).Split(':')[1]
                # $lastPossible = Get-Date -Day $resource.csLastRun.Day -Month $resource.csLastRun.Day
                # $desiredWindow = Get-Date 
                # Was the last time we ran in the last day?
                # if($resource.csLastRun -lt $)
             }
            Default {}
        }
    }
}