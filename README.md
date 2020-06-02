# cycle_vmss
Reimaging VMSS virtual machines while maintaining availability

## Overview
In Azure, you have [Virtual Machine Scale Sets](https://docs.microsoft.com/en-us/azure/virtual-machine-scale-sets/overview).  Scale sets are a wonderful wrapper around maintaining multiple virtual machines that you want to be identical.

One way to run your own application on this is via [Extensions](https://docs.microsoft.com/en-us/azure/virtual-machines/extensions/features-windows).  Extensions run after the virtual machine is created and booted up.  Azure has a little agent that runs on the machine, grabs the extensions' configurations, and runs them.

When you write your application to run on a VMSS, you have three options: have the application update itself, update the application on reimage, orupdate the application manually.  Well, I set about to go about the problem the latter method, by updating the application on reimage.  Let me describe the process.

1. I am running the [custom script extension][script-extension] on my VMSS.  This script which is open-sourced (TBD) installs a windows service.  This service is then brought up and the script exits.  In this case, the VMSS is for working a service bus queue using a queue listener (competing consumers pattern). For brevity's sake, the script pulls down a zip file, extracts it, and installs the exe in it as a service using `installutil`.  It also sets up the service with recovery options.  More on that in the (TBD) repository. 

2. This works great until I want to upgrade the service.  How do I go about this?  Well, I need to replace the service's zip file in the storage account container where the custom script extension gets the file.  Then, for completeness, I need to reimage the vm so that it starts from scratch with the new service.

3.  I wanted to do this automatically in my CI/CD pipeline while also maintaining availability.  To do this, I've started writing this script.

## How it works
First off, my service reports health.  It does this using the health reporting extension and exposing a /health endpoint that returns 200 when the service is healthy.  cycle-servers.ps1 goes through each instance in the VMSS and reimages them one by one, not starting the next one until the current one is reimaged and healthy again.  This ensures uptime in that only one VM is being reimaged at a time.

## Prerequisites
This script uses the Azure CLI.  Get it [here](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest).  Before running this script, ensure the machine you are running on is authenticated.  You can do this by logging in (`az login`) on your local machine or by using the [Azure CLI task](https://github.com/microsoft/azure-pipelines-tasks/blob/master/Tasks/AzureCLIV2/Readme.md) in Azure DevOps.  Other methods for authenticating are enumerated [here](https://docs.microsoft.com/en-us/cli/azure/authenticate-azure-cli?view=azure-cli-latest).

## Use it!
There are 3 parameters:
- `ResourceGroupName`: Resource Group Name the VMSS belongs to
- `ScaleSetName`: VMSS Resource Name
- `TimeoutMinutes` (optional): Specifies timeout for each VMSS.  Upon timeout, process aborts.  Default: 30 minutes.
- `IgnoreInitialHealth` (switch): If provided, it will not ensure the VMSS is healthy before reimaging.  Skip this if you are trying to fix a bug where there is 1 or more VMs that will never be healthy.
- `IgnoreAvailability` (switch): The script checks to make sure there is more than one VM running so that the service will always be available.  If this is provided, it will not perform this check.  If there is only one machine and this is not provided, it will scale to two machines before proceeding.

# Health Score
The health score of a machine is a bitwise operation.  There are three factors: ProvisioningState, PowerState, and HealthState.  All three must be in a good state to proceed.


[script-extension]: https://docs.microsoft.com/en-us/azure/virtual-machines/windows/tutorial-automate-vm-deployment?toc=https%3A%2F%2Fdocs.microsoft.com%2Fen-us%2Fazure%2Fvirtual-machines%2Fextensions%2Ftoc.json&bc=https%3A%2F%2Fdocs.microsoft.com%2Fen-us%2Fazure%2Fbread%2Ftoc.json 
