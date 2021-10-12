FROM mcr.microsoft.com/powershell:nanoserver-ltsc2022

ENV PATH="C:\Program Files\PowerShell;C:\utils;C:\Windows\system32;C:\Windows;"

# wins.exe doesn't work in nanoserver with default ContainerUser.
USER ContainerAdministrator

COPY wins.exe /utils/wins.exe
COPY yq.exe /utils/yq.exe
COPY /cni /cni/
ADD https://raw.githubusercontent.com/microsoft/SDN/master/Kubernetes/windows/hns.psm1 /k/flannel/hns.psm1
COPY setup.exe /k/flannel/setup.exe
COPY flanneld.exe /k/flannel/flanneld.exe
