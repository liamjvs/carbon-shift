# Carbon Shift

## Tags

| Tag Name | Tag Value | Description | Required? |
--- | --- | --- | --- 
| csLength | <600m | Value in minutes to the nearest hour of how long the workload runs for | Yes
| csFrequency | 1d, 1w, 1m, 1q | How often the workload will be scheduled | Yes 
| csLastRun | 2022-03-01T03:00:00 | Datestamp of when the workload last run | No
| csFluid | true/false | Can the workload move if CI is better in the other region? | No
| csStartTime | 00:00:00 | When should this workload be run? | No
| csEndTime | 00:00:00 | When should this workload be run? | No