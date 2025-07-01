# Function to get compute SKUs and quantities for a given resource group
class ComputeResource{
    [string]$ServiceName
    [string]$ResourceGroupId
    [int]$Quantity
    [string]$SKU    
}
function Get-ComputeSkusInResourceGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupId,
        
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )
    
    # Create a list of strings
    $list = [System.Collections.Generic.List[ComputeResource]]::new()


    try {
        # Extract resource group name from the full resource ID
        $resourceGroupName = ($ResourceGroupId -split '/')[-1] 
     
        # Get all compute resources in the resource group
        $computeResources = Get-AzResource -ResourceGroupName $resourceGroupName | Where-Object {
            $_.ResourceType -match 'Microsoft\.Compute|Microsoft\.ContainerService|Microsoft\.Databricks|Microsoft\.HDInsight|Microsoft\.MachineLearningServices|Microsoft\.Batch|Microsoft\.ServiceFabric'
        }
        
        if ($computeResources) {
            # Group by resource type and SKU
            $skuSummary = @{
            }
            
            foreach ($resource in $computeResources) {
                $resourceType = $resource.ResourceType
                $sku = "Unknown"
                $quantity = 1
                
                # Get detailed resource information to extract SKU
                try {
                    $resourceDetails = Get-AzResource -ResourceId $resource.ResourceId
                    
                    # Extract SKU based on resource type
                    switch -Regex ($resourceType) {
                        "Microsoft\.Compute/virtualMachines" {
                            $vmDetails = Get-AzVM -ResourceGroupName $resourceGroupName -Name $resource.Name -ErrorAction SilentlyContinue
                            if ($vmDetails) {
                                $sku = $vmDetails.HardwareProfile.VmSize
                            }
                        }
                        "Microsoft\.Compute/virtualMachineScaleSets" {
                            $vmssDetails = Get-AzVmss -ResourceGroupName $resourceGroupName -VMScaleSetName $resource.Name -ErrorAction SilentlyContinue
                            if ($vmssDetails) {
                                $sku = $vmssDetails.Sku.Name
                                $quantity = $vmssDetails.Sku.Capacity
                            }
                        }
                        "Microsoft\.ContainerService/managedClusters" {
                            $aksDetails = Get-AzAksCluster -ResourceGroupName $resourceGroupName -Name $resource.Name -ErrorAction SilentlyContinue
                            if ($aksDetails -and $aksDetails.AgentPoolProfiles) {
                                foreach ($pool in $aksDetails.AgentPoolProfiles) {
                                    $poolSku = "$($pool.VmSize) (AKS Node Pool: $($pool.Name))"
                                    $poolQuantity = $pool.Count
                                    
                                    $key = "$resourceType|$poolSku"
                                    if ($skuSummary.ContainsKey($key)) {
                                        $skuSummary[$key].Quantity += $poolQuantity
                                        $skuSummary[$key].Resources += $resource.Name
                                    } else {
                                        $skuSummary[$key] = @{
                                            ResourceType = $resourceType
                                            SKU = $poolSku
                                            Quantity = $poolQuantity
                                            Resources = @($resource.Name)
                                        }
                                    }
                                }
                                continue
                            }
                        }
                        "Microsoft\.Databricks/workspaces" {
                            $sku = "Databricks Workspace"
                        }
                  
                    }
                    
                    # Add to summary (skip if already processed in AKS section)
                    if ($resourceType -notmatch "Microsoft\.ContainerService/managedClusters" -or -not $aksDetails) {
                        $key = "$resourceType|$sku"
                        if ($skuSummary.ContainsKey($key)) {
                            $skuSummary[$key].Quantity += $quantity
                            $skuSummary[$key].Resources += $resource.Name
                        } else {
                            $skuSummary[$key] = @{
                                ResourceType = $resourceType
                                SKU = $sku
                                Quantity = $quantity
                                Resources = @($resource.Name)
                            }
                        }
                    }
                }
                catch {
                    Write-Warning "Could not get details for resource: $($resource.Name) - $($_.Exception.Message)"
                }
            }
            
            $skuSummary.GetEnumerator() | Sort-Object {$_.Value.ResourceType}, {$_.Value.SKU} | ForEach-Object {
                $info = $_.Value
                if ($info.ResourceType -eq "Microsoft.Compute/virtualMachines") {
          
                    # Write-host "$($ServiceName)$($info.SKU)$($info.Quantity)"
                    $list.add([ComputeResource]@{
                        ServiceName = $ServiceName
                        ResourceGroupId = $resourceGroupName
                        SKU = $info.SKU
                        Quantity = $info.Quantity
                    })
                }
            }       
     
        }
        else {
            Write-Host "No compute resources found in resource group: $resourceGroupName" -ForegroundColor Yellow
            Write-Host ""
        }
    }
    catch {
        Write-Error "Error analyzing resource group '$ResourceGroupId': $($_.Exception.Message)"
    }
    # Output the list of compute resources
    if ($list.Count -gt 0) {
        $list | Format-Table -AutoSize
    }
}

# Get all Databricks workspaces and display their managed resource group IDs
$workspaces = Get-AzDatabricksWorkspace



if ($workspaces) {
   
    foreach ($workspace in $workspaces) {    
  
        Get-ComputeSkusInResourceGroup -ResourceGroupId $workspace.ManagedResourceGroupId -ServiceName $workspace.Name 
    }
} else {
    Write-Host "No Databricks workspaces found in the current subscription." -ForegroundColor Yellow
}
