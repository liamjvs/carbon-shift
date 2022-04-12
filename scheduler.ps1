
Disable-AzContextAutosave -Scope Process | Out-Null

# $Global:law = @{
#     workspaceId  = "069b325c-6d3f-4bfc-b17b-eed484875ad3"
#     workspaceKey = "ba434IwgbXEamXZKI7nqwM1VU6x+tCgYASS/VE6vyq3LhGHdq/IsmNg0/F907Lr1pE1dORnpQXcuj6ic68AqGg=="
# }

try {
    $AzureContext = (Connect-AzAccount -Identity -Subscription "679bfca2-ae52-45e8-b890-c26560f2eca0").context
}
catch {
    Write-Output "There is no system-assigned user identity. Aborting."; 
    exit
}

function findSlot($timeFrame, $slots) {
    $adjacent = $timeFrame / 30
    $mergedSlots = @()
    foreach ($slot in $slots) {
        $startTime = $slot.from | Get-Date
        $endTime = $slot.to | Get-Date
        $intensity = 0
        $currentIndex = $slots.IndexOf($slot)
        for ($i = 0; $i -lt ($adjacent); $i++) {
            $intensity += [int]$slots[($currentIndex + $i)].intensity.forecast
            if($null -ne ($slots[($currentIndex + $i)])){
                $endTime = $slots[($currentIndex + $i)].to | Get-Date
            } else {
                $endTime = $null
            }
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
    Write-Host ("Requesting data for region {0} for date {1}." -f $ciRegion, $dateNow)
    $uri = ("https://api.carbonintensity.org.uk/regional/intensity/{0}/fw48h/regionid/{1}" -f $dateNow, $region.ciRegion)
    Write-Host ("REST URI: {0}" -f $uri)
    $data = Invoke-RestMethod -Method Get -Uri $uri -Headers @{Accept = 'application/json' }
    if ($data.Length -gt 0) {
        Write-Host "Successfully got data."
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

function bestSlot($slots, $minutes, $startTime, $endTime) {
    $targetedSlots = findSlot -slots $slots -timeFrame $minutes
    # Convert timedate to correct format
    $startTimeFormatted = $startTime | Get-Date -UFormat "%Y-%m-%dT%H:%MZ"
    $endTimeFormatted = $endTime | Get-Date -UFormat "%Y-%m-%dT%H:%MZ"
    $targetedSlots = $targetedSlots | Where-Object { $_.startTime -ge $startTimeFormatted -and $_.endTime -le $endTimeFormatted }
    if ($targetedSlots.Length -gt 0) {
        $chosenSlot = $targetedSlots | sort-object intensity | Select-Object -First 1
        $averageIntensity = calculateAverageIntensity -slots $targetedSlots
        $chosenSlot | Add-Member -Name "averageIntensity" -Value $averageIntensity -MemberType NoteProperty
    }
    else {
        Write-Host ("No slots found for the window of {0} and {1}" -f $windowStart, $windowEnd)
        $chosenSlot = $null
    }
    return $chosenSlot
}

function greenSlots($slots) {
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

function sanitiseSlots($slots) {
    $sanitised = @()
    foreach ($slot in $slots) {
        $sanitised += $slot | select from, to, @{Name = 'intensity'; Expression = { $_.intensity.forecast } }, generationmix
    }
    return $sanitised
}

function sanitiseSlotsFound($slotsFound) {
    $sanitised = @()
    foreach ($region in $slotsFound) {
        $sanitisedSlots = sanitiseSlots($region.slots)
        foreach ($sanitisedSlot in $sanitisedSlots) {
            $sanitised += [PSCustomObject]@{
                azureRegion   = $region.azureRegion
                slotStart     = Get-Date $sanitisedSlot.from -AsUTC
                slotEnd       = Get-Date $sanitisedSlot.to -AsUTC
                intensity     = $sanitisedSlot.intensity
                generationMix = $sanitisedSlot.generationmix
            }
        }
    }
    return $sanitised
}

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
    $key = ($lawObject | Get-AzOperationalInsightsWorkspaceSharedKey -WarningAction Ignore).PrimarySharedKey
    $customerId = $lawObject.CustomerId
    return @{
        workspaceId  = $customerId
        workspaceKey = $key
    }
}

function publishSlotsToLAW($slots) {
    $table = "csSlots"
    $sanitisedSlots = sanitiseSlotsFound -slotsFound $slots
    $body = [System.Text.Encoding]::UTF8.GetBytes(($sanitisedSlots | ConvertTo-Json -Depth 100 -Compress))
    postLogAnalyticsData -logType $table -body $body
}
function publishGreenSlotsToLAW($slots) {
    $table = "csGreenSlots"
    $sanitisedSlots = @()
    foreach($slot in $slots){
        $slot.greenSlots.PSObject.Properties | ForEach-Object {
            $sanitisedSlots += [PSCustomObject]@{
                azureRegion   = $slot.azureRegion
                length     = $_.Name
                slotStart = $_.Value.startTime | Get-Date -AsUTC
                slotEnd       = $_.Value.endTime | Get-Date -AsUTC
                intensity     = $_.Value.intensity
            }
        }
    }
    $body = [System.Text.Encoding]::UTF8.GetBytes(($sanitisedSlots | ConvertTo-Json -Depth 100 -Compress))
    postLogAnalyticsData -logType $table -body $body
}

function publishScheduleToLAW($body) {
    $table = "csSchedule"
    $body = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 100 -Compress))
    postLogAnalyticsData -logType $table -body $body
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
    Write-Host "Working out best times to run."
    $greenSlots = greenSlots -slots $slots
    $slotsFound += [PSCustomObject]@{
        azureRegion = $region.azureRegion
        ciRegion    = $region.ciRegion
        slots       = $slots
        greenSlots  = $greenSlots
    }
}

# Push Results to LAW
Write-Host "Publishing slots to our Log Analytics Workspace"
$publishOutput = publishSlotsToLAW -slots $slotsFound
if($publishOutput -ne 200){
    Write-Error ("Error publishing results to Log Analytics Workspace - receiving error {0}." -f $publishOutput)
} else {
    Write-Host "Successfully published slots to our Log Analytics Workspace"
}
Write-Host "Publishing green slots to our Log Analytics Workspace"
$publishOutput = publishGreenSlotsToLAW -slots $slotsFound
if($publishOutput -ne 200){
    Write-Error ("Error publishing green results to Log Analytics Workspace - receiving error {0}." -f $publishOutput)
} else {
    Write-Host "Successfully published green slots to our Log Analytics Workspace"
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
    Write-Host ("Returned {0} Resources" -f $queryResults.length)
    $now = Get-Date

    # Get all current schedules from our Automation Account - saves constantly polling later on
    $automationAccountScheduledRunbooks = Get-AzAutomationScheduledRunbook -AutomationAccountName liam-rg-greendog-aa -ResourceGroupName liam-rg-greendog
    $automationAccountSchedules = Get-AzAutomationSchedule -AutomationAccountName liam-rg-greendog-aa -ResourceGroupName liam-rg-greendog

    foreach ($resource in $queryResults) {
        $tagsChanged = $false
        Write-Host ("Reviewing {0} that has csLength of {1} and csFrequency of {2}." -f $resource.name, $resource.csLength, $resource.csFrequency)

        $windowFrequency = [int]($resource.csFrequency).substring(($resource.csFrequency).length - 2, 1)

        # Set up resource as some tags may be missing i.e. new resource tagged
        if ($resource.csStartTime -eq $null) {
            $resource.csStartTime = "00:00"
        }

        if ($resource.csEndTime -eq $null) {
            $resource.csEndTime = "00:00"
        }

        if ($resource.csLastRun -eq $null) {
            Write-Host ("The resource '{0}' does not have a last run value." -f $resource.name)
            $resource.csLastRun = (Get-Date -Hour ($resource.csStartTime).Split(':')[0] -Minute ($resource.csStartTime).Split(':')[1] -Second 0).AddDays(-$windowFrequency)
            # New-AzTag -ResourceId $resource.Id -Tag @{csLastRun = $resource.csLastRun}
        } else {
            $resource.csLastRun = [datetime]::ParseExact($resource.csLastRun, 'dd/MM/yyyy HH:mm', $null)
        }

        if ($resource.csLastWindow -eq $null) {
            # Calculate last window
            $lastPossibleHour = ($resource.csStartTime).Split(':')[0]
            $lastPossibleMinute = ($resource.csStartTime).Split(':')[1]
            $lastPossible = (Get-Date -Hour ($resource.csStartTime).Split(':')[0] -Minute ($resource.csStartTime).Split(':')[1]).Date
            if ($lastPossible -gt $now) {
                $lastPossible = $lastPossible.AddDays(-$windowFrequency)
            }
            $resource.csLastWindow = $lastPossible
            Update-AzTag -ResourceId $resource.Id -Tag @{"csLastWindow"=(Get-Date $resource.csLastWindow -Format "dd/MM/yyyy HH:mm")} -Operation Merge
        }
        else {
            # Convert to DateTime
            $resource.csLastWindow = [datetime]::ParseExact($resource.csLastWindow, 'dd/MM/yyyy HH:mm', $null)

            # Is the csLastWindow out of candence? Do now subtract the window frequency.
            $lastGuess = (Get-Date $now -Hour ($resource.csStartTime).Split(':')[0] -Minute ($resource.csStartTime).Split(':')[1] -Second 00 -Millisecond 00)
            $lastGuess = $lastGuess.AddDays(-$windowFrequency)
            if($lastGuess.AddDays($windowFrequency) -lt $now){
                $lastGuess = $lastGuess.AddDays(1)
            }

            # if($lastGuess -gt $now){
            #     $lastGuess = $lastGuess.AddDays(-$windowFrequency)
            # }
            # if ($resource.csStartTime -eq $resource.csEndTime) {
            #     if ((Get-Date $resource.csStartTime) -le $now -and ((Get-Date $resource.csEndTime).AddDays($windowFrequency) -le $now)) {
            #         $lastGuess = $now | Get-Date -Hour ($resource.csStartTime).Split(':')[0] -Minute ($resource.csStartTime).Split(':')[1] -Second 0 -Millisecond 0
            #     }
            #     else {
            #         $lastGuess = $now.AddDays(-$windowFrequency) | Get-Date -Hour ($resource.csStartTime).Split(':')[0] -Minute ($resource.csStartTime).Split(':')[1] -Second 0 -Millisecond 0
            #     }
            # }
            # else {
            #     if ((Get-Date $resource.csStartTime) -le $now -and ((Get-Date $resource.csEndTime) -le $now)) {
            #         $lastGuess = $now | Get-Date -Hour ($resource.csStartTime).Split(':')[0] -Minute ($resource.csStartTime).Split(':')[1] -Second 0 -Millisecond 0
            #     }
            #     else {
            #         $lastGuess = $now.AddDays(-$windowFrequency) | Get-Date -Hour ($resource.csStartTime).Split(':')[0] -Minute ($resource.csStartTime).Split(':')[1] -Second 0 -Millisecond 0
            #     }
            # }
            if ($resource.csLastWindow -lt $lastGuess) {
                $resource.csLastWindow = $lastGuess
                Update-AzTag -ResourceId $resource.id -Tag @{ csLastWindow = (Get-Date $resource.csLastWindow -Format "dd/MM/yyyy HH:mm") } -Operation Merge
            }
        }

        # Work out the winow
        $windowStart = ($resource.csLastWindow).AddDays($windowFrequency) | Get-Date -Hour ($resource.csStartTime).Split(':')[0] -Minute ($resource.csStartTime).Split(':')[1] -Second 0 -Millisecond 0
        $windowEnd = $windowStart.AddDays($windowFrequency) | Get-Date -Hour ($resource.csEndTime).Split(':')[0] -Minute ($resource.csEndTime).Split(':')[1] -Second 0 -Millisecond 0
        
        # May have an condition where 00:00 is the same day
        if ($resource.csStartTime -ne $resource.csEndTime) {
            $windowEnd = $windowEnd.AddDays(-1)
        }

        Write-Host ("{0} has window start of {1} and window end of {2}." -f $resource.id, $windowStart, $windowEnd)

        # And confirm we haven't already run?
        if ($windowStart -gt $resource.csLastRun) {
            switch (($resource.csFrequency).substring(($resource.csFrequency).length - 1, 1)) {
                "d" {
                    # $startTime = Get-Date $windowStart | Get-Date -Hour ($resource.csStartTime).Split(':')[0] -Minute ($resource.csStartTime).Split(':')[1] -Second 0 -Millisecond 0
                    # $endTime = Get-Date $windowEnd | Get-Date -Hour ($resource.csEndTime).Split(':')[0] -Minute ($resource.csEndTime).Split(':')[1] -Second 0 -Millisecond 0
                                
                    # May have an condition where 00:00 is the same day
                    # if ($startTime -eq $endTime) {
                    #     $endTime = $endTime.AddDays(1)
                    # }
                        
                    $slotsInWindow = ($slotsFound | Where-Object { $_.azureRegion -eq $resource.location }).slots
                    
                    if ($slotsInWindow.Length -eq 0) {
                        Write-Error "There are no slots within the window"
                    }
                    else {
                        $bestSlot = bestSlot -slots $slotsInWindow `
                            -minutes ($resource.csLength).Replace('m', '') `
                            -startTime $windowStart `
                            -endTime $windowEnd
    
                        $modifiedSchedule = $false

                        if ($bestSlot -ne $null) {

                            Write-Host ("Best slot for {0} starts at {1}, ends at {2}." -f $resource.name, $bestSlot.startTime,$bestSlot.endTime)
                            # Check for a pre-existing schedule
                            $vmScheduleName = "{0} Scheduled Start" -f $resource.name
                            $schedule = $automationAccountSchedules | where-object { $_.Name -eq $vmScheduleName }

                            if (($schedule -eq $null) -or ($schedule.StartTime -ne $bestSlot.startTime)) {
                                $modifiedSchedule = $true
                                $scheduleCreated = New-AzAutomationSchedule -ResourceGroupName 'liam-rg-greendog' `
                                    -AutomationAccountName 'liam-rg-greendog-aa' `
                                    -Name $vmScheduleName `
                                    -StartTime $bestSlot.startTime `
                                    -OneTime
                                Write-Host "Created schedule with best slot exists."

                                if (($automationAccountScheduledRunbooks | Where-Object { $_.ScheduleName -eq $vmScheduleName }).Length -gt 0) {
                                    Unregister-AzAutomationScheduledRunbook -ResourceGroupName 'liam-rg-greendog' `
                                        -AutomationAccountName 'liam-rg-greendog-aa' `
                                        -ScheduleName $vmScheduleName `
                                        -RunbookName "CI-controller" `
                                        -Force `
                                        | Out-Null
                                    Write-Host "Unregistered Scheduled Runbook"
                                }
                            
                                Register-AzAutomationScheduledRunbook -Name 'CI-controller' `
                                    -ResourceGroupName 'liam-rg-greendog' `
                                    -AutomationAccountName 'liam-rg-greendog-aa' `
                                    -ScheduleName $vmScheduleName `
                                    -Parameters @{
                                        vmID   = $resource.id
                                        action = "Start"
                                    } `
                                    | Out-Null
                                Write-Host "Registered new Scheduled Runbook"
                            } else {
                                Write-Host "Schedule with best slot exists."
                            }
    
                            $vmScheduleName = "{0} Scheduled Stop" -f $resource.name
                            $schedule = $automationAccountSchedules | where-object { $_.Name -eq $vmScheduleName }
                            if (($schedule -eq $null) -or ($schedule.StartTime -ne $bestSlot.endTime)) {
                                $modifiedSchedule = $true
                                New-AzAutomationSchedule -ResourceGroupName 'liam-rg-greendog' `
                                    -AutomationAccountName 'liam-rg-greendog-aa' `
                                    -Name $vmScheduleName `
                                    -StartTime $bestSlot.endTime `
                                    -OneTime `
                                    | Out-Null
                            
                                if (($automationAccountScheduledRunbooks | Where-Object { $_.ScheduleName -eq $vmScheduleName }).Length -gt 0) {
                                    Unregister-AzAutomationScheduledRunbook -ResourceGroupName 'liam-rg-greendog' `
                                        -AutomationAccountName 'liam-rg-greendog-aa' `
                                        -ScheduleName $vmScheduleName `
                                        -RunbookName "CI-controller" `
                                        -Force `
                                        | Out-Null
                                }
                            
                                Register-AzAutomationScheduledRunbook -Name 'CI-controller' `
                                    -ResourceGroupName 'liam-rg-greendog' `
                                    -AutomationAccountName 'liam-rg-greendog-aa' `
                                    -ScheduleName $vmScheduleName `
                                    -Parameters @{
                                        vmID   = $resource.id
                                        action = "Stop"
                                    } `
                                    | Out-Null
                            }
                        } else {
                            Write-Host "Schedule with best slot exists."
                        }

                        # Push to LAW
                        if ($modifiedSchedule) {
                            $body = @{
                                vmID             = $resource.id
                                windowStart      = $windowStart
                                windowEnd        = $windowEnd
                                slotStart        = $bestSlot.startTime
                                slotEnd          = $bestSlot.endTime
                                intensity        = $bestSlot.intensity
                                averageIntensity = $bestSlot.averageIntensity
                            }
                            publishScheduleToLAW -body $body
                        }

                        # Check tags 
                        $currentTags = Get-AzTag -ResourceId $resource.id
                        $newTags = $currentTags
                        $newTags.Properties.TagsProperty.csLastWindow = $resource.csLastWindow
                        if ($currentTags -ne $newTags) {
                            Update-AzTag -ResourceId $resource.id -Tag $newTags.Properties.TagsProperty
                        }
                    }
                    
                }
            }
        }
    }
}