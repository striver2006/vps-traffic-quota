<#
.SYNOPSIS
  编译并打包 Windows 版 VPSQuota 安装程序（支持 x64 和 arm64）。
.USAGE
  .\build-installer.ps1 [-Arch <x64|arm64|all>] [-SelfContained]
#>
[CmdletBinding()]
param(
    [ValidateSet("x64", "arm64", "all")]
    [string]$Arch = "all",
    [bool]$SelfContained = $true
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$Architectures = if ($Arch -eq "all") { @("x64", "arm64") } else { @($Arch) }
$DistDir = Join-Path $ScriptDir "dist"
if (Test-Path $DistDir) { Remove-Item -Recurse -Force $DistDir }
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

$IsccPath = "iscc"
if (-not (Get-Command "iscc" -ErrorAction SilentlyContinue)) {
    $CommonPaths = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
        "${env:LocalAppData}\Programs\Inno Setup 6\ISCC.exe"
    )
    foreach ($p in $CommonPaths) {
        if (Test-Path $p) { $IsccPath = $p; break }
    }
}

foreach ($targetArch in $Architectures) {
    $rid = if ($targetArch -eq "arm64") { "win-arm64" } else { "win-x64" }
    $outDir = Join-Path $ScriptDir "publish-$targetArch"
    if (Test-Path $outDir) { Remove-Item -Recurse -Force $outDir }

    Write-Host "==> 发布 $rid (SelfContained: $SelfContained)..." -ForegroundColor Cyan
    $selfContainedArg = if ($SelfContained) { "--self-contained", "true" } else { "--self-contained", "false" }
    dotnet publish VpsQuota\VpsQuota.csproj -c Release -r $rid @selfContainedArg -o $outDir

    # 打包免安装 zip
    $zipName = "VPSQuota-win-$targetArch.zip"
    $zipPath = Join-Path $DistDir $zipName
    Write-Host "==> 生成便携包: $zipName..." -ForegroundColor Cyan
    Compress-Archive -Path "$outDir\*" -DestinationPath $zipPath -Force

    # 编译 Inno Setup 安装包
    if (Get-Command $IsccPath -ErrorAction SilentlyContinue -or (Test-Path $IsccPath)) {
        Write-Host "==> 制作安装包: VPSQuota-Setup-win-$targetArch.exe..." -ForegroundColor Cyan
        & $IsccPath "/DAppArch=$targetArch" "/DSourceDir=publish-$targetArch" "installer.iss"
    } else {
        Write-Warning "未找到 Inno Setup (ISCC.exe)，跳过安装包编译。可运行 choco install innosetup 安装。"
    }
}

Write-Host "==> 打包完成。产物目录: $DistDir" -ForegroundColor Green
Get-ChildItem $DistDir | Select-Object Name, Length, LastWriteTime
