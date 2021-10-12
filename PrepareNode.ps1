<#
.SYNOPSIS
Assists with preparing a Windows VM prior to calling kubeadm join

.DESCRIPTION
This script assists with joining a Windows node to a cluster.
- Downloads Kubernetes binaries (kubelet, kubeadm) at the version specified
- Registers wins as a service in order to run kube-proxy and cni as DaemonSets.
- Registers kubelet as an nssm service. More info on nssm: https://nssm.cc/

.PARAMETER KubernetesVersion
Kubernetes version to download and use

.PARAMETER ContainerRuntime
Container that Kubernetes will use. (Docker or containerD)

.EXAMPLE
PS> .\PrepareNode.ps1 -KubernetesVersion v1.22.2 -ContainerRuntime Docker

#>

$requiredWindowsFeatures = @(
    "Containers"
    )

$removedWindowsFeatures = @(
    "Windows-Defender",
    "WoW64-Support"
    )


function ValidateWindowsFeatures {
    $allFeaturesInstalled = $true
    foreach ($feature in $requiredWindowsFeatures) {
        $f = Get-WindowsFeature -Name $feature
        if (-not $f.Installed) {
            Write-Warning "Windows feature: '$feature' is not installed."
            $allFeaturesInstalled = $false
        }
    }
    return $allFeaturesInstalled
}

if (-not (ValidateWindowsFeatures)) {
    Write-Output "Installing required windows features..."

    foreach ($feature in $requiredWindowsFeatures) {
        Install-WindowsFeature -Name $feature
    }

    Write-Output "Please reboot and re-run this script."
    exit 0
}

function RemoveWindowsFeatures {
    $removedFeaturesInstalled = $true
    foreach ($feature in $removedWindowsFeatures) {
        $f = Get-WindowsFeature -Name $feature
        if ($f.Installed) {
            Write-Warning "Windows feature: '$feature' is installed, removing it now"
            $removedFeaturesInstalled = $false
        }
    }
    return $removedFeaturesInstalled
}

if (-not (RemoveWindowsFeatures)) {
    Write-Output "Removing required windows features..."

    foreach ($feature in $removedWindowsFeatures) {
        UnInstall-WindowsFeature -Name $feature -Remove
    }

    Write-Output "Please reboot and re-run this script."
    exit 0
}


If(-not(Get-InstalledModule DockerMsftProvider -ErrorAction silentlycontinue)){
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Install-Module DockerMsftProvider -Repository PSGallery -Confirm:$False -Force
}

If(-not(Get-Package DockerMsftProvider -ErrorAction silentlycontinue)){
    Install-Package -Name Docker -ProviderName DockerMsftProvider -Confirm:$False -Force
    Get-WindowsFeature | ? installstate -eq "Available" | Uninstall-WindowsFeature -Remove
    Set-Service Docker -StartupType 'Automatic'
    Write-Output "Please reboot last time and re-run this script again."
    exit 0
}


Param(
    [parameter(Mandatory = $true, HelpMessage="Kubernetes version to use")]
    [string] $KubernetesVersion,
    [parameter(HelpMessage="Container runtime that Kubernets will use")]
    [ValidateSet("containerD", "Docker")]
    [string] $ContainerRuntime = "Docker"
)
$ErrorActionPreference = 'Stop'

function DownloadFile($destination, $source) {
    Write-Host("Downloading $source to $destination")
    curl.exe --silent --fail -Lo $destination $source

    if (!$?) {
        Write-Error "Download $source failed"
        exit 1
    }
}

if ($ContainerRuntime -eq "Docker") {
    if (-not(Test-Path "//./pipe/docker_engine")) {
        Write-Error "Docker service was not detected - please install start Docker before calling PrepareNode.ps1 with -ContainerRuntime Docker"
        exit 1
    }
} elseif ($ContainerRuntime -eq "containerD") {
    if (-not(Test-Path "//./pipe/containerd-containerd")) {
        Write-Error "ContainerD service was not detected - please install and start containerD before calling PrepareNode.ps1 with -ContainerRuntime containerD"
        exit 1
    }
}

if (!$KubernetesVersion.StartsWith("v")) {
    $KubernetesVersion = "v" + $KubernetesVersion
}
Write-Host "Using Kubernetes version: $KubernetesVersion"
$global:Powershell = (Get-Command powershell).Source
$global:PowershellArgs = "-ExecutionPolicy Bypass -NoProfile"
$global:KubernetesPath = "$env:SystemDrive\k"
$global:StartKubeletScript = "$global:KubernetesPath\StartKubelet.ps1"
$global:NssmInstallDirectory = "$env:ProgramFiles\nssm"
$kubeletBinPath = "$global:KubernetesPath\kubelet.exe"

mkdir -force "$global:KubernetesPath"
$env:Path += ";$global:KubernetesPath"
[Environment]::SetEnvironmentVariable("Path", $env:Path, [System.EnvironmentVariableTarget]::Machine)

DownloadFile $kubeletBinPath https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/kubelet.exe
DownloadFile "$global:KubernetesPath\kubeadm.exe" https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/kubeadm.exe
DownloadFile "$global:KubernetesPath\wins.exe" https://github.com/rancher/wins/releases/download/v0.0.4/wins.exe

if ($ContainerRuntime -eq "Docker") {
    # Create host network to allow kubelet to schedule hostNetwork pods
    # NOTE: For containerd the 0-containerd-nat.json network config template added by
    # Install-containerd.ps1 joins pods to the host network.
    Write-Host "Creating Docker host network"
    docker network create -d nat host
} elseif ($ContainerRuntime -eq "containerD") {
    DownloadFile "c:\k\hns.psm1" https://github.com/Microsoft/SDN/raw/master/Kubernetes/windows/hns.psm1
    Import-Module "c:\k\hns.psm1"
    # TODO(marosset): check if network already exists before creatation
    New-HnsNetwork -Type NAT -Name nat
}

Write-Host "Registering wins service"
wins.exe srv app run --register
start-service rancher-wins

mkdir -force C:\var\log\kubelet
mkdir -force C:\var\lib\kubelet\etc\kubernetes
mkdir -force C:\etc\kubernetes\pki
New-Item -path C:\var\lib\kubelet\etc\kubernetes\pki -type SymbolicLink -value C:\etc\kubernetes\pki\

$StartKubeletFileContent = '$FileContent = Get-Content -Path "/var/lib/kubelet/kubeadm-flags.env"
$global:KubeletArgs = $FileContent.TrimStart(''KUBELET_KUBEADM_ARGS='').Trim(''"'')

$global:containerRuntime = {{CONTAINER_RUNTIME}}

if ($global:containerRuntime -eq "Docker") {
    $netId = docker network ls -f name=host --format "{{ .ID }}"

    if ($netId.Length -lt 1) {
    docker network create -d nat host
    }
}

$cmd = "C:\k\kubelet.exe $global:KubeletArgs --cert-dir=$env:SYSTEMDRIVE\var\lib\kubelet\pki --config=/var/lib/kubelet/config.yaml --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf --hostname-override=$(hostname) --pod-infra-container-image=`"k8s.gcr.io/pause:3.6`" --enable-debugging-handlers --cgroups-per-qos=false --enforce-node-allocatable=`"`" --network-plugin=cni --resolv-conf=`"`" --log-dir=/var/log/kubelet --logtostderr=false --image-pull-progress-deadline=20m"

Invoke-Expression $cmd'
$StartKubeletFileContent = $StartKubeletFileContent -replace "{{CONTAINER_RUNTIME}}", "`"$ContainerRuntime`""
Set-Content -Path $global:StartKubeletScript -Value $StartKubeletFileContent

Write-Host "Installing nssm"
$arch = "win32"
if ([Environment]::Is64BitOperatingSystem) {
    $arch = "win64"
}

mkdir -Force $global:NssmInstallDirectory
DownloadFile nssm.zip https://k8stestinfrabinaries.blob.core.windows.net/nssm-mirror/nssm-2.24.zip
tar C $global:NssmInstallDirectory -xvf .\nssm.zip --strip-components 2 */$arch/*.exe
Remove-Item -Force .\nssm.zip

$env:path += ";$global:NssmInstallDirectory"
$newPath = "$global:NssmInstallDirectory;" +
[Environment]::GetEnvironmentVariable("PATH", [EnvironmentVariableTarget]::Machine)

[Environment]::SetEnvironmentVariable("PATH", $newPath, [EnvironmentVariableTarget]::Machine)

Write-Host "Registering kubelet service"
nssm install kubelet $global:Powershell $global:PowershellArgs $global:StartKubeletScript

if ($ContainerRuntime -eq "Docker") {
    nssm set kubelet DependOnService docker
} elseif ($ContainerRuntime -eq "containerD") {
    nssm set kubelet DependOnService containerd
}

New-NetFirewallRule -Name kubelet -DisplayName 'kubelet' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 10250
