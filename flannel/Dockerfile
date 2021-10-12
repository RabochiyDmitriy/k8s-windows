FROM mcr.microsoft.com/powershell:nanoserver-ltsc2022 as base

WORKDIR /utils
RUN curl https://github.com/rancher/wins/releases/download/v0.0.4/wins.exe -Lo wins.exe
RUN curl https://github.com/mikefarah/yq/releases/download/2.4.1/yq_windows_amd64.exe -Lo yq.exe

WORKDIR /cni
RUN curl https://github.com/containernetworking/plugins/releases/download/v0.8.7/cni-plugins-windows-amd64-v0.8.7.tgz -Lo cni.tgz
RUN tar -x -m -f cni.tgz
RUN del cni.tgz

WORKDIR /flannel 
RUN curl https://github.com/coreos/flannel/releases/download/v0.14.0/flanneld.exe -Lo flanneld.exe
RUN curl https://github.com/RabochiyDmitriy/k8s-windows/blob/main/flannel/setup.exe -Lo setup.exe
FROM mcr.microsoft.com/powershell:nanoserver-ltsc2022

# wins.exe doesn't work in nanoserver with default ContainerUser.
USER ContainerAdministrator

ENV PATH="C:\Program Files\PowerShell;C:\utils;C:\Windows\system32;C:\Windows;"
COPY --from=base /utils /utils
COPY --from=base /cni /cni/
ADD https://raw.githubusercontent.com/microsoft/SDN/master/Kubernetes/windows/hns.psm1 /k/flannel/hns.psm1
COPY --from=base /flannel /k/flannel/
