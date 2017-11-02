<#
.SYNOPSIS
    GenerateTier2StorageJson.ps1 - This sample script generates a storage account to be onboarded.
.DESCRIPTION
    GenerateTier2StorageJson.ps1 - This sample script generates a storage account to be onboarded. This is meant to be executed when a new subscription needs to be onboarded
    in the image process solution, it requires a subscription Id, which regions to create the storage accounts and an individual starting Id for each storage account, the output
    will be one storage account per region per subscription. This output is a JSON file with the individual tier 2 storage account entries, which needs to be copied excluding the []'s,
    into the SetupInfoHON.json file at the end of the section tier2StorageAccounts, please remember that this is a JSON file and needs to be JSON compliant so extra attention is needed
    regarding commas, brakets and curly brakets.

    This script just generates the output necessary to be copied inside the SetupInfoHON.json file, it does not create any resource in Azure. After the setup file is updated with 
    the new content, it is required to execute the Setup.ps1 script again, in order to add the storage accounts to support a new subscription(s)/region(s).

.PARAMETER subscriptionId
    Individual subscription id to be onboarded, meaning that the storage account(s) json definitions will be generated there. Quantity of storage accounts will depend on the number of regions
    supported by this subscription.
.PARAMETER subscriptionListFile
    Subscription id list file to be onboarded, meaning that the storage account(s) json definitions will be generated there. Quantity of storage accounts will depend on the number of regions
    supported by each subscription inside of the file.
.PARAMETER regionList
    Array of regions supported by the subscription, if there is one region, only one storage account item definition will be generated, if there is two, two storage accounts and so on.
.PARAMETER startingIdNumber
    Since this solution supports expansions, an unique Id for each storage account to be created is required, this is because the Setup.ps1 script checks this Id agains the Configuration Table,
    if this Id is there, the creation of that storage account will be skipped because that means that it was previously created. Best practice is to open the SetupInfoHON.json file,
    look at the tier2StorageAccounts section and look the last number used, add one to that number and then you will have the necessary sequence to just append to the file.
.PARAMETER setupInfoFile
    Points to the setup info file used by the Azure Image Management Automation solution, if this argument is passed, this script will update the file directly and place the additional
    storage entries in the correct section. 
.PARAMETER outputFile
    This is the JSON file containing the output for the storage accounts, as mentioned in the description, copy the contents to the correct section of the setup file and execute
    the setup script again in order to have the new storage accounts in the target regions and subcription.
.EXAMPLE
    Single Subscription
    .\GenerateTier2StorageJson.ps1 -subscriptionId "123456" -regionList "westus","eastus","brazilsouth" -startingIdNumber 20 -outputFile .\test1.json
.EXAMPLE
    Subscription list from file
    .\GenerateTier2StorageJson.ps1 -subscriptionListFile .\subs.csv -regionList "westus","eastus","brazilsouth" -startingIdNumber 20 -outputFile .\test2.json
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory=$true,ParameterSetName="subscriptionId")]
    [string]$subscriptionId,

    [Parameter(Mandatory=$true,ParameterSetName="subscriptionFile")]
    [string]$subscriptionListFile,

    [Parameter(Mandatory=$false)]
    [string]$setupInfoFile,

    [string[]]$regionList,
    
    [Parameter(Mandatory=$false)]
    [int]$startingIdNumber=-1,

    [string]$outputFile = "onboardStorageAccounts.json"
)

function createStorageAccountEntry
{
    param
    (
        [string]$id,
        [string]$region,
        [string]$subscriptionId
    )

    return New-Object -typename PSObject -Property @{"id"="$id";
                "storageAccountName"='^([StorageAccountName]::new("honosimg",[storageAccountTier]::tier2)).GetSaName($true)';
                "resourceGroup"='^$config.storage.tier0StorageAccount.resourceGroup';
                "location"=$region;
                "container"='^$config.storage.tier0StorageAccount.container';
                "subscriptionId"="$subscriptionId"}

}

if ($setupInfoFile -ne $null)
{
    if (!(Test-Path $setupInfoFile))
    {
        throw "Setup information $setupInfoFile file not found."
    }

    $outputFileName = [string]::Format("{0}.New-{1}{2}",[system.io.Path]::GetFileNameWithoutExtension($setupInfoFile),(get-date -Format s).tostring().replace(":","_"),[system.io.Path]::GetExtension($setupInfoFile))
    $outputFile = join-path -path ([system.io.Path]::GetDirectoryName($setupInfoFile)) $outputFileName

}

$onboardStorageAccounts = @()

switch ($PSCmdlet.ParameterSetName)
{
    "subscriptionId"
    {
        foreach ($region in $regionList)
        {
            if ($startingIdNumber -gt -1)
            {
                $onboardStorageAccounts += createStorageAccountEntry -id $startingIdNumber -region $region -subscriptionId $subscriptionId
                $startingIdNumber += 1
            }
            else
            {
                $onboardStorageAccounts += createStorageAccountEntry -id ([guid]::NewGuid().Guid) -region $region -subscriptionId $subscriptionId   
            }
        }
    }

    "subscriptionFile"
    {
        if (!(Test-Path $subscriptionListFile))
        {
            throw "Subscription file $subscriptionListFile not found."
        }

        $subscriptions = Get-Content $subscriptionListFile

        foreach ($sub in $subscriptions)
        {
            foreach ($region in $regionList)
            {
                if ($startingIdNumber -gt -1)
                {
                    $onboardStorageAccounts += createStorageAccountEntry -id $startingIdNumber -region $region -subscriptionId $sub
                    $startingIdNumber += 1
                }
                else
                {
                    $onboardStorageAccounts += createStorageAccountEntry -id ([guid]::NewGuid().Guid) -region $region -subscriptionId $sub   
                }
            }
        }
    }
}

if ([string]::IsNullOrEmpty($setupInfoFile))
{
    $onboardStorageAccounts | ConvertTo-Json  | Out-File $outputFile
}
else
{
    $config = Get-Content $setupInfoFile -Raw | ConvertFrom-Json

    foreach ($storage in $onboardStorageAccounts)
    {
        $config.storage.tier2StorageAccounts += $storage
    }

    # Generating a new SetupInfo file
    $config | ConvertTo-Json -Depth 99 | Out-File $outputFile
}
