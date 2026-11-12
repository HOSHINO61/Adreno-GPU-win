# Runs on windows-latest: builds the driver package from Linux artifacts,
# creates the catalog, test-signs everything and compiles the installers.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$env_ = @{}; Get-Content versions.env | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object { $env_[$Matches[1]] = $Matches[2] }
$run = if ($env:RUN_NUMBER) { $env:RUN_NUMBER } else { '0' }
$version = "0.1.$run"

$stage = Join-Path $root 'stage'; $drv = Join-Path $stage 'driver'; $dist = Join-Path $root 'dist'
Remove-Item -Recurse -Force $stage, $dist -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $drv, $dist | Out-Null

# ---- collect binaries
$a64 = Join-Path $root 'bin\bin-arm64\out\arm64'
Copy-Item "$a64\virtio_wddm_rs.sys", "$a64\dx11um_virtio.dll", "$a64\dx12um_virtio.dll", `
          "$a64\vulkan_freedreno.dll", "$a64\droidvm_vulkan.dll" $drv
Copy-Item package\freedreno_icd.aarch64.json $drv

# ---- INF
$inf = Get-Content package\virtio_wddm_rs.inx -Raw
$inf = $inf.Replace('%%BUILDDATE%%', (Get-Date).ToUniversalTime().ToString('MM/dd/yyyy'))
# Local fork: start above the upstream build numbering (upstream build-43 is
# 20.15.1.43) so a fresh fork build still wins the PnP driver ranking when an
# older upstream package is already staged on the machine.
$inf = $inf.Replace('%%VERSION%%', "20.15.1.$([int]$run + 1000)")
foreach ($extra in Get-ChildItem bin -Directory -Filter 'bin-*' | Where-Object Name -ne 'bin-arm64') {
    # Optional ARM64EC / x86 user-mode drivers (later stages).
    $hook = Join-Path package "$($extra.Name).ps1"
    if (Test-Path $hook) { $inf = & $hook -Inf $inf -Bin $extra.FullName -Driver $drv }
}
[IO.File]::WriteAllText((Join-Path $drv 'virtio_wddm_rs.inf'), $inf.Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.Encoding]::ASCII)

# ---- tools: Inf2Cat from the WDK NuGet, signtool from the installed SDK
$nuget = Join-Path $root 'wdk-nuget'
if (-not (Test-Path $nuget)) {
    $v = $env_['NUGET_VER']
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/microsoft.windows.wdk.x64/$v/microsoft.windows.wdk.x64.$v.nupkg" -OutFile wdk.zip
    Expand-Archive wdk.zip $nuget; Remove-Item wdk.zip
}
$inf2cat = Get-ChildItem $nuget -Recurse -Filter Inf2Cat.exe | Select-Object -First 1
$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter signtool.exe |
    Where-Object FullName -match '\\x64\\' | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $inf2cat -or -not $signtool) { throw "Inf2Cat=$inf2cat signtool=$signtool" }

# ---- certificate: repo secret if present, otherwise a fresh test cert
$subject = 'CN=DroidVM GPU Test (unofficial build)'
$pfx = Join-Path $stage 'sign.pfx'
$pw = if ($env:SIGN_PFX_PASSWORD) { $env:SIGN_PFX_PASSWORD } else { [guid]::NewGuid().ToString() }
if ($env:SIGN_PFX_BASE64) {
    [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:SIGN_PFX_BASE64))
    $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($pfx, $pw)
} else {
    $cert = New-SelfSignedCertificate -Subject $subject -Type CodeSigningCert -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(5) `
        -CertStoreLocation Cert:\CurrentUser\My
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password (ConvertTo-SecureString $pw -AsPlainText -Force) | Out-Null
}
Export-Certificate -Cert $cert -FilePath (Join-Path $stage 'DroidVM-GPU-Test.cer') | Out-Null

function Sign($files) {
    & $signtool.FullName sign /fd SHA256 /f $pfx /p $pw $files
    if ($LASTEXITCODE) { throw "signtool failed on $files" }
}
Sign (Get-ChildItem $drv -Include *.sys, *.dll -Recurse).FullName

& $inf2cat.FullName /driver:$drv /os:10_GE_ARM64 /uselocaltime
if ($LASTEXITCODE) { throw 'Inf2Cat failed' }
Sign (Join-Path $drv 'virtio_wddm_rs.cat')

# ---- installers
Copy-Item package\install.ps1, package\uninstall.ps1, package\setup.iss, package\uninstall.iss, package\README-install.txt $stage
Copy-Item LICENSE (Join-Path $stage 'LICENSE.txt')
$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { choco install innosetup -y --no-progress | Out-Null; $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
Push-Location $stage
foreach ($iss in 'setup.iss', 'uninstall.iss') { & $iscc /Q "/DAppVersion=$version" $iss; if ($LASTEXITCODE) { throw "ISCC $iss failed" } }
Pop-Location
# ---- diagnostic variant: same package, KMD built with bringup-diagnostics
$diagSys = Join-Path $a64 'virtio_wddm_rs_diag.sys'
if (Test-Path $diagSys) {
    $drvDiag = Join-Path $stage 'driver-diag'
    Copy-Item $drv $drvDiag -Recurse
    Remove-Item (Join-Path $drvDiag 'virtio_wddm_rs.cat')
    Copy-Item $diagSys (Join-Path $drvDiag 'virtio_wddm_rs.sys') -Force
    Sign (Join-Path $drvDiag 'virtio_wddm_rs.sys')
    & $inf2cat.FullName /driver:$drvDiag /os:10_GE_ARM64 /uselocaltime
    if ($LASTEXITCODE) { throw 'Inf2Cat (diag) failed' }
    Sign (Join-Path $drvDiag 'virtio_wddm_rs.cat')
    Push-Location $stage
    Rename-Item driver driver-normal; Rename-Item driver-diag driver
    & $iscc /Q "/DAppVersion=$version-diag" "/DOutName=DroidVM-GPU-Setup-diag" setup.iss
    if ($LASTEXITCODE) { throw 'ISCC diag failed' }
    Rename-Item driver driver-diag; Rename-Item driver-normal driver
    Pop-Location
    Sign (Join-Path $stage 'DroidVM-GPU-Setup-diag.exe')
    Copy-Item (Join-Path $stage 'DroidVM-GPU-Setup-diag.exe') $dist
}
Sign (Join-Path $stage 'DroidVM-GPU-Setup.exe'), (Join-Path $stage 'DroidVM-GPU-Uninstall.exe')

Copy-Item (Join-Path $stage 'DroidVM-GPU-Setup.exe'), (Join-Path $stage 'DroidVM-GPU-Uninstall.exe') $dist
Copy-Item tools\DroidVM-GPU-Logs.cmd $dist
Compress-Archive -Path $drv, (Join-Path $stage 'DroidVM-GPU-Test.cer'), package\install.ps1, package\uninstall.ps1 -DestinationPath (Join-Path $dist 'DroidVM-GPU-driver.zip')
Get-ChildItem $dist -File | ForEach-Object { "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name } |
    Set-Content (Join-Path $dist 'SHA256SUMS.txt')

$rev = Get-ChildItem bin -Recurse -Filter REVISIONS.md | Select-Object -First 1
@"
**Неофициальная** сборка драйвера VirtIO-GPU для Windows 11 ARM64 (DroidVM).
Авторы драйвера: anonymix007 и команда DroidVM. Лицензия AGPL-3.0, не для продажи.

> Перед установкой сделайте клон диска ВМ. Подписано тестовым сертификатом
> (``$($cert.Thumbprint)``), установщик включает TESTSIGNING.

- ``DroidVM-GPU-Setup.exe`` — установка (сертификат + драйвер, перезагрузка)
- ``DroidVM-GPU-Setup-diag.exe`` — то же, но драйвер ядра пишет шаги запуска в реестр (HKLM\\SYSTEM\\CurrentControlSet\\Services\\VirtioGpu\\Parameters\\Bringup)
- ``DroidVM-GPU-Uninstall.exe`` — откат
- ``DroidVM-GPU-driver.zip`` — тот же пакет для ручной установки (pnputil)

Состав: ARM64 — KMD, D3D11 (DXVK), D3D12 (vkd3d-proton), Vulkan (Turnip), Vulkan-Loader.
Пара KMD/UMD собрана из разных коммитов (UMD — со своим ``virtio_wddm_uapi.h``,
KMD — со своим ``uapi.rs``); совместимость проверена по разбору размеров private data
в adapter.rs (+12/+32 байта). **На устройстве ещё не тестировалось.**

Venus (vulkan_virtio.dll) в публичных исходниках не собирается под Windows — не включён.

Исходники:
$(if ($rev) { Get-Content $rev.FullName -Raw })
"@ | Set-Content (Join-Path $dist 'RELEASE_NOTES.md') -Encoding utf8
Get-ChildItem $dist
