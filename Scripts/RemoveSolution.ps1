param
(
    [Parameter(Mandatory=$false)]
    [string]$configFile
)

if (!(test-path $configFile))
{
    throw "Configuration file $configFile could not be found."
}

$config = get-content $configFile -raw | ConvertFrom-Json 

Select-AzureRmSubscription -SubscriptionId $config.storage.tier0StorageAccount.subscriptionId

$tier2RGs = $config.storage.tier2StorageAccounts 

foreach ($rg in $tier2RGs)
{
    
    if ($rg.subscriptionId.ToString().StartsWith("^"))
    {
        $subId = (invoke-expression ($rg.subscriptionId).tostring().replace('^',''))
    }
    else
    {
        $subId = $rg.subscriptionId
    }

    if ($rg.resourcegroup.ToString().StartsWith("^"))
    {
        $rgName = (invoke-expression ($rg.resourcegroup).tostring().replace('^',''))
    }
    else
    {
        $rgName = $rg.resourcegroup
    }

    write-verbose "Deleting resource group $rgName from subscription $subId" -Verbose

    Select-AzureRmSubscription -SubscriptionId $subId

    $rgObject = Get-AzureRmResourceGroup -Name $rgName -ErrorAction SilentlyContinue
    if ($rgObject -ne $null)
    {
        $rgName
        Remove-AzureRmResourceGroup -name $rgName -Force
    }

} 
