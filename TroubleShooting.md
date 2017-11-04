# Troubleshooting

This guide is a work in progress and will be updated frequently to include new ways to troubleshoot this solution.

How to restart the copy process starting from Tier 2 distribution
-----------------------------------------------------------------

1) Define some variables in Powershell that will help:

```powershell
$configStorageAccountResourceGroupName = "PMC-OS-Images-Solution-rg"
$configStorageAccountName = "pmctier0sa01"
$jobsTableName = "imageManagementJobs"
$jobsLogTableName = "imageManagementJobLogs"
```

2) Two options to identify your copy process jobs

	2.1) Identify the Job Id by opening the Configuration Table (usually called imageManagementConfiguration) located at Tier 0 (or Configuration) storage account with Storage Explorer.
		2.1.1) After identifiying which job, copy the content of RowKey (that's the job Id)

		OR

	2.2) Run the following cmdlets to get the list of jobs from Powershell
		
```powershell
		$jobTable = Get-AzureStorageTableTable -ResourceGroup $configStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $jobsTableName
		Get-AzureStorageTableRowAll -table $jobTable
```

2) Store the rowKey attribute value from the job you wish to restart the tier 2 process, in this example I have the following value:

	```powershell
	$jobId = "82cb707e-91a5-4c9e-a24f-719971d27109"
	```

3) Run the following command line and copy the content of the message that starts with {jobId:
	
```powershell
	$log = Get-AzureRmImgMgmtLog -ConfigStorageAccountResourceGroupName $configStorageAccountResourceGroupName -ConfigStorageAccountName $configStorageAccountName -jobId $jobId | select rowkey,message | ? { $_.message -like ('*jobId":*')}
	
	$log

```

	Output Example:


	| RowKey | message |
	| --- | --- |
	| 8057f39a-e6c8-43c0-8421-eec416e206df | {"jobId":"82cb707e-91a5-4c9e-a24f-719971d27109","imageResourceGroupName":"Images-RG01","imageName":"WinServerCore2016-Img01","osType":"Windows","vhdName":"WinServerCore2016-OsDisk.vhd"} |
	| 92410572-c00f-4a2e-be89-d884c28613d0 | Starting tier1 distribution. Runbook Start-ImageManagementTier1Distribution with parameters: {"jobId":"82cb707e-91a5-4c9e-a24f-719971d27109","Tier0SubscriptionId":"4a49ea85-ce71-4800-b854-5d18e557921e","ConfigStorageAccountName":"pmctier0sa01","ConfigStorageAccountResourceGroupName":"PMC-OS-Images... |

4) Copy the contents of message attribute that starts with "{jobId"
	
	In this example the content to be copied is:
	{"jobId":"82cb707e-91a5-4c9e-a24f-719971d27109","imageResourceGroupName":"Images-RG01","imageName":"WinServerCore2016-Img01","osType":"Windows","vhdName":"WinServerCore2016-OsDisk.vhd"}

	If you want to store the message content in a variable, identify which line (starts with 0) and assign to a variable, for example:
	
	```powershell
	$queueMessage = $log[0].message
	```

5) Place this content in the queue using azure Storage Explorer or Powershell and wait or restart the Start-ImageManagementTier2Distribution using the same values for the paramters from the failed job.


Getting log information from the Tier 2 Distribution Runbook
------------------------------------------------------------

High level steps to start querying:

1) Sign in to Azure from PowerShell
2) Define some variables 
4) Obtain the job Id
3) Execute the log query cmdlet, in this example we are querying 

Code
```powershell
# Sign in
Add-AzureRmAccount

# Define some variables
$configStorageAccountResourceGroupName = "PMC-OS-Images-Solution-rg"
$configStorageAccountName = "pmctier0sa01"
$jobsTableName = "imageManagementJobs"
$jobsLogTableName = "imageManagementJobLogs"

# Obtain the copy vhd job table
$jobTable = Get-AzureStorageTableTable -ResourceGroup $configStorageAccountResourceGroupName -StorageAccountName $configStorageAccountName -tableName $jobsTableName

# List all jobs
Get-AzureStorageTableRowAll -table $jobTable

# Define the job id to work with
$jobId= "<row key of the job you want to query>"

# Run the query cmdlet
Get-AzureRmImgMgmtLog -ConfigStorageAccountResourceGroupName $configStorageAccountResourceGroupName -ConfigStorageAccountName $configStorageAccountName -jobId $jobId -Level All -step tier2Distribution | sort timestamp | select timestamp,step,message
```