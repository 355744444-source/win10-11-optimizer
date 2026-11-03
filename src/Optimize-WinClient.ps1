#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 10 / 11 优化执行器：基线采集、分层优化、一键回滚。

.DESCRIPTION
    默认只读。任何写入都必须显式加 -Apply，建议先配合 -WhatIf 预览。

    脚本永久不触碰以下配置（属安全边界，不在自动化范围内）：
      * Microsoft Defender 实时防护
      * VBS / HVCI（内存完整性、内核隔离）
      * Windows Update 及其服务
      * BitLocker
      * 页面文件（虚拟内存）
      * Windows Search 索引服务
    这些项目只存在于配套文档的人工执行清单中，需走变更审批。

.PARAMETER Level
    Report = 只采集基线（默认，绝不写入）
    L1     = 零风险项
    L2     = 低风险项（含 L1）
    L3     = 需评估项（含 L1 + L2）

.PARAMETER Role
    机型：Office / Dev / Design / Personal，决定哪些项适用。可多选。

.PARAMETER Apply
    真正写入。不加则只打印计划。

.PARAMETER Rollback
    按最近一次变更清单还原。

.PARAMETER BackupDir
    变更清单与基线报告目录，默认 %ProgramData%\WinOpt。

.EXAMPLE
    .\Optimize-WinClient.ps1 -Level Report

.EXAMPLE
    .\Optimize-WinClient.ps1 -Level L1 -Role Office -Apply -WhatIf

.EXAMPLE
    .\Optimize-WinClient.ps1 -Level L1 -Role Office -Apply

.EXAMPLE
    .\Optimize-WinClient.ps1 -Rollback
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Report', 'L1', 'L2', 'L3')]
    [string]$Level = 'Report',

    [ValidateSet('Office', 'Dev', 'Design', 'Personal')]
    [string[]]$Role = @('Office'),

    [switch]$Apply,

    [switch]$Rollback,

    [string]$BackupDir = (Join-Path $env:ProgramData 'WinOpt'),

    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$script:Cmdlet = $PSCmdlet
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:Records = New-Object System.Collections.ArrayList
$script:Log = New-Object System.Collections.ArrayList
$script:TierRank = @{ 'L1' = 1; 'L2' = 2; 'L3' = 3 }

# ---------------------------------------------------------------- 基础工具

function Write-Log {
    param([string]$Message, [string]$Kind = 'INFO')
    $line = "[{0}] {1} {2}" -f $Kind.PadRight(5), (Get-Date -Format 'HH:mm:ss'), $Message
    [void]$script:Log.Add($line)
    switch ($Kind) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'SKIP'  { Write-Host $line -ForegroundColor DarkGray }
        default { Write-Host $line }
    }
}

function Get-HiveRoot {
    param([string]$Hive)
    if ($Hive -eq 'HKLM') { return [Microsoft.Win32.Registry]::LocalMachine }
    return [Microsoft.Win32.Registry]::CurrentUser
}

function Test-RegKey {
    param([string]$Hive, [string]$Path)
    $root = Get-HiveRoot $Hive
    $key = $root.OpenSubKey($Path, $false)
    if ($null -eq $key) { return $false }
    $key.Close()
    return $true
}

function Read-RegValue {
    param([string]$Hive, [string]$Path, [string]$Name)

    if ($null -eq $Name) { $Name = '' }
    $result = @{ Exists = $false; Value = $null; Kind = $null }

    $root = Get-HiveRoot $Hive
    $key = $root.OpenSubKey($Path, $false)
    if ($null -eq $key) { return $result }

    try {
        if ($key.GetValueNames() -contains $Name) {
            $result.Exists = $true
            $result.Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $result.Kind = $key.GetValueKind($Name).ToString()
        }
    }
    finally {
        $key.Close()
    }
    return $result
}

function Write-RegValue {
    param([string]$Hive, [string]$Path, [string]$Name, [string]$ValueKind, $Value)

    if ($null -eq $Name) { $Name = '' }

    $root = Get-HiveRoot $Hive
    $key = $root.CreateSubKey($Path)
    if ($null -eq $key) { throw "无法打开注册表键 $Hive`:\$Path" }
    try {
        $kind = [Microsoft.Win32.RegistryValueKind]$ValueKind
        if ($ValueKind -eq 'Binary') {
            $key.SetValue($Name, [byte[]]$Value, $kind)
        }
        elseif ($ValueKind -eq 'MultiString') {
            $key.SetValue($Name, [string[]]$Value, $kind)
        }
        else {
            $key.SetValue($Name, $Value, $kind)
        }
    }
    finally {
        $key.Close()
    }
}

function Remove-RegKeyTree {
    param([string]$Hive, [string]$Path)
    $root = Get-HiveRoot $Hive
    try { $root.DeleteSubKeyTree($Path, $false) } catch { }
}

function ConvertTo-StateValue {
    param($Value, [string]$Kind)
    if ($null -eq $Value) { return $null }
    if ($Kind -eq 'Binary') { return [Convert]::ToBase64String([byte[]]$Value) }
    if ($Kind -eq 'MultiString') { return (@($Value) -join '|||') }
    return [string]$Value
}

function ConvertFrom-StateValue {
    param($Value, [string]$Kind)
    if ($null -eq $Value) { return $null }
    if ($Kind -eq 'Binary') { return [Convert]::FromBase64String([string]$Value) }
    if ($Kind -eq 'MultiString') { return ([string]$Value -split '\|\|\|') }
    return $Value
}

# ---------------------------------------------------------------- 环境判定

function Get-OsInfo {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = 0
    [void][int]::TryParse([string]$cv.CurrentBuildNumber, [ref]$build)

    # Win11 的 ProductName 注册表值仍写作 "Windows 10"，必须以 Build 号为准
    $name = if ($build -ge 22000) { 'Windows 11' } else { [string]$cv.ProductName }

    return [pscustomobject]@{
        ProductName    = $name
        RawProductName = [string]$cv.ProductName
        DisplayVersion = [string]$cv.DisplayVersion
        Build          = $build
        UBR            = [string]$cv.UBR
        IsWin11        = ($build -ge 22000)
        Full           = '{0} {1} (Build {2}.{3})' -f $name, $cv.DisplayVersion, $build, $cv.UBR
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DesktopMachine {
    $bat = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    return ($null -eq $bat)
}

function Test-AllSsd {
    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.MediaType -ne 'Unspecified' -and $_.BusType -ne 'USB' }
        if (-not $disks) { return $false }
        $hdd = $disks | Where-Object { $_.MediaType -eq 'HDD' }
        return ($null -eq $hdd)
    }
    catch { return $false }
}

function Test-LowRam {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $gb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        return ($gb -le 8.1)
    }
    catch { return $false }
}

function Test-SystemDriveTight {
    try {
        $d = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        $freePct = [math]::Round(($d.Free / ($d.Free + $d.Used)) * 100, 1)
        return ($freePct -lt 15)
    }
    catch { return $false }
}

function Get-ActiveSchemeGuid {
    $out = (& powercfg.exe /getactivescheme) -join ' '
    $m = [regex]::Match($out, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value }
    return $null
}

# ---------------------------------------------------------------- 优化项定义

function Get-OptimizationItems {
    param([switch]$IncludeAll)

    $all = @(
        # ---------------- L1 零风险 ----------------
        @{
            Id       = 'L1-BackgroundApps'
            Tier     = 'L1'
            Kind     = 'Reg'
            Desc     = '关闭后台应用（不影响前台应用与系统组件）'
            Roles    = @('Office', 'Dev', 'Design', 'Personal')
            Hive     = 'HKCU'
            Path     = 'Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
            Name     = 'GlobalUserDisabled'
            ValueKind = 'DWord'
            Value    = 1
            Win11Only = $false
        }
        @{
            Id       = 'L1-DeliveryOptimization'
            Tier     = 'L1'
            Kind     = 'Reg'
            Desc     = '传递优化改为仅 HTTP，禁止 P2P 上传（省出口带宽）'
            Roles    = @('Office', 'Dev', 'Design')
            Hive     = 'HKLM'
            Path     = 'SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
            Name     = 'DODownloadMode'
            ValueKind = 'DWord'
            Value    = 0
            Win11Only = $false
        }
        @{
            Id       = 'L1-Win11Widgets'
            Tier     = 'L1'
            Kind     = 'Reg'
            Desc     = '关闭 Win11 小组件（Widgets / 资讯与兴趣）'
            Roles    = @('Office', 'Dev', 'Design', 'Personal')
            Hive     = 'HKLM'
            Path     = 'SOFTWARE\Policies\Microsoft\Dsh'
            Name     = 'AllowNewsAndInterests'
            ValueKind = 'DWord'
            Value    = 0
            Win11Only = $true
        }
        @{
            Id       = 'L1-Win11SearchHighlights'
            Tier     = 'L1'
            Kind     = 'Reg'
            Desc     = '关闭 Win11 搜索框亮点内容'
            Roles    = @('Office', 'Dev', 'Design', 'Personal')
            Hive     = 'HKCU'
            Path     = 'Software\Microsoft\Windows\CurrentVersion\SearchSettings'
            Name     = 'IsDynamicSearchBoxEnabled'
            ValueKind = 'DWord'
            Value    = 0
            Win11Only = $true
        }
        @{
            Id       = 'L1-Win11StartRecommendations'
            Tier     = 'L1'
            Kind     = 'Reg'
            Desc     = '关闭 Win11 开始菜单推荐区'
            Roles    = @('Office', 'Dev', 'Design', 'Personal')
            Hive     = 'HKCU'
            Path     = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            Name     = 'Start_IrisRecommendations'
            ValueKind = 'DWord'
            Value    = 0
            Win11Only = $true
        }
        @{
            Id       = 'L1-TipsSubscribed'
            Tier     = 'L1'
            Kind     = 'Reg'
            Desc     = '关闭系统"获取使用提示和建议"内容推送'
            Roles    = @('Office', 'Dev', 'Design', 'Personal')
            Hive     = 'HKCU'
            Path     = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            Name     = 'SubscribedContent-338389Enabled'
            ValueKind = 'DWord'
            Value    = 0
            Win11Only = $false
        }
        @{
            Id       = 'L1-SoftLanding'
            Tier     = 'L1'
            Kind     = 'Reg'
            Desc     = '关闭首次登录后的"软着陆"推荐页'
            Roles    = @('Office', 'Dev', 'Design', 'Personal')
            Hive     = 'HKCU'
            Path     = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            Name     = 'SoftLandingEnabled'
            ValueKind = 'DWord'
            Value    = 0
            Win11Only = $false
        }
        @{
            Id       = 'L1-Win11ClassicContextMenu'
            Tier     = 'L1'
            Kind     = 'Reg'
            Desc     = '恢复 Win11 经典右键菜单（纯体验项，可回滚）'
            Roles    = @('Office', 'Dev')
            Hive     = 'HKCU'
            Path     = 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
            Name     = ''
            ValueKind = 'String'
            Value    = ''
            Win11Only = $true
        }
        @{
            Id       = 'L1-VisualEffects'
            Tier     = 'L1'
            Kind     = 'Reg'
            Desc     = '关闭视觉动画与透明效果（仅低配机，高配机无感）'
            Roles    = @('Office', 'Design', 'Personal')
            Hive     = 'HKCU'
            Path     = 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
            Name     = 'VisualFXSetting'
            ValueKind = 'DWord'
            Value    = 2
            Win11Only = $false
            Condition = { Test-LowRam }
            ConditionText = '仅当物理内存 <= 8GB 时执行'
        }

        # ---------------- L2 低风险 ----------------
        @{
            Id       = 'L2-PowerPlan'
            Tier     = 'L2'
            Kind     = 'Cmd'
            Desc     = '台式机切换到高性能电源计划（笔记本保持平衡，不执行）'
            Roles    = @('Office', 'Dev', 'Design', 'Personal')
            Condition = { Test-DesktopMachine }
            ConditionText = '仅台式机执行'
            GetState = { Get-ActiveSchemeGuid }
            DoAction = {
                & powercfg.exe /setactive 'SCHEME_MIN'
                & powercfg.exe /setactive '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
            }
            UndoAction = {
                param($state)
                if ($state) { & powercfg.exe /setactive $state }
            }
        }
        @{
            Id       = 'L2-DisableSysMain'
            Tier     = 'L2'
            Kind     = 'Cmd'
            Desc     = '禁用 SysMain / Superfetch（仅全 SSD 机型）'
            Roles    = @('Office', 'Dev', 'Design', 'Personal')
            Condition = { Test-AllSsd }
            ConditionText = '仅当所有物理磁盘均为 SSD 时执行'
            GetState = { (Get-Service -Name 'SysMain' -ErrorAction Stop).StartupType.ToString() }
            DoAction = {
                Set-Service -Name 'SysMain' -StartupType 'Disabled' -ErrorAction Stop
                Stop-Service -Name 'SysMain' -Force -ErrorAction SilentlyContinue
            }
            UndoAction = {
                param($state)
                if ($state) { Set-Service -Name 'SysMain' -StartupType $state -ErrorAction SilentlyContinue }
            }
        }
        @{
            Id       = 'L2-ComponentCleanup'
            Tier     = 'L2'
            Kind     = 'Cmd'
            Desc     = '组件存储清理 DISM /StartComponentCleanup（不加 /ResetBase）'
            Roles    = @('Office', 'Dev', 'Design', 'Personal')
            Condition = { Test-SystemDriveTight }
            ConditionText = '仅当系统盘可用空间 < 15% 时执行'
            GetState = { 'not-applicable' }
            DoAction = {
                & Dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet
            }
            UndoAction = {
                param($state)
                Write-Host '  该操作不可回滚（未使用 /ResetBase，更新仍可卸载）' -ForegroundColor DarkGray
            }
        }

        # ---------------- L3 需评估 ----------------
        @{
            Id       = 'L3-DisableHibernate'
            Tier     = 'L3'
            Kind     = 'Cmd'
            Desc     = '关闭休眠与快速启动，释放 hiberfil.sys（有 BitLocker 风险）'
            Roles    = @('Personal')
            Condition = { $true }
            ConditionText = '仅个人机；企业资产需先确认 BitLocker 恢复密钥已托管'
            RequireConfirm = $true
            GetState = {
                $v = Read-RegValue -Hive 'HKLM' -Path 'SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
                if ($v.Exists) { return [string]$v.Value }
                return '1'
            }
            DoAction = { & powercfg.exe /h off }
            UndoAction = {
                param($state)
                if ($state -eq '1' -or $null -eq $state) { & powercfg.exe /h on }
            }
        }
    )

    if ($IncludeAll) { return $all }

    $rankText = [string]$script:RequestedLevel
    if (-not $script:TierRank.ContainsKey($rankText)) { $rankText = 'L3' }
    $targetRank = $script:TierRank[$rankText]

    return $all | Where-Object {
        ($script:TierRank[$_.Tier] -le $targetRank) -and
        (@($_.Roles) | Where-Object { $script:Role -contains $_ })
    }
}

# ---------------------------------------------------------------- 变更清单

function Save-Manifest {
    if ($script:Records.Count -eq 0) { return $null }
    $appliedCount = @($script:Records | Where-Object { $_.Applied }).Count
    if ($appliedCount -eq 0) { return $null }
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        [void](New-Item -ItemType Directory -Path $BackupDir -Force)
    }
    $path = Join-Path $BackupDir ('manifest-{0}.json' -f $script:Stamp)
    $payload = [pscustomobject]@{
        Stamp     = $script:Stamp
        Computer  = $env:COMPUTERNAME
        User      = $env:USERNAME
        Level     = $script:RequestedLevel
        Role      = ($script:Role -join ',')
        Os        = (Get-OsInfo).Full
        Records   = @($script:Records)
    }
    $payload | ConvertTo-Json -Depth 6 | Out-File -FilePath $path -Encoding utf8
    return $path
}

function Get-LatestManifest {
    if (-not (Test-Path -LiteralPath $BackupDir)) { return $null }
    $f = Get-ChildItem -LiteralPath $BackupDir -Filter 'manifest-*.json' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $f) { return $null }
    return $f.FullName
}

# ---------------------------------------------------------------- 执行 / 回滚

function Invoke-RegItem {
    param($Item)

    $target = ('{0}:\{1}\{2}' -f $Item.Hive, $Item.Path, $Item.Name)
    $old = Read-RegValue -Hive $Item.Hive -Path $Item.Path -Name $Item.Name
    $keyExisted = Test-RegKey -Hive $Item.Hive -Path $Item.Path

    if ($null -ne $old.Value -and (ConvertTo-StateValue $old.Value $old.Kind) -eq (ConvertTo-StateValue $Item.Value $Item.ValueKind) -and $old.Exists) {
        Write-Log ('已是目标值，跳过：{0}' -f $Item.Id) 'SKIP'
        return
    }

    $record = [ordered]@{
        Kind       = 'Reg'
        Id         = $Item.Id
        Tier       = $Item.Tier
        Hive       = $Item.Hive
        Path       = $Item.Path
        Name       = $Item.Name
        KeyExisted = $keyExisted
        OldExists  = [bool]$old.Exists
        OldKind    = [string]$old.Kind
        OldValue   = (ConvertTo-StateValue $old.Value $old.Kind)
        Applied    = $false
    }

    $approved = $script:Cmdlet.ShouldProcess($target, ('设置为 {0} ({1})' -f $Item.Value, $Item.ValueKind))
    if ($script:DryRun) {
        Write-Log ('[演练] 将写入 {0}' -f $target) 'SKIP'
        if (-not $approved) { return }
    }
    elseif ($approved) {
        try {
            Write-RegValue -Hive $Item.Hive -Path $Item.Path -Name $Item.Name -ValueKind $Item.ValueKind -Value $Item.Value
            $record.Applied = $true
            Write-Log ('已应用 [{0}] {1}' -f $Item.Tier, $Item.Desc) 'OK'
        }
        catch {
            Write-Log ('写入失败 {0}：{1}' -f $Item.Id, $_.Exception.Message) 'ERROR'
        }
    }
    [void]$script:Records.Add([pscustomobject]$record)
}

function Invoke-CmdItem {
    param($Item)

    if ($Item.ConditionText) { Write-Log ('  条件：{0}' -f $Item.ConditionText) }

    if ($Item.RequireConfirm -and -not $Force -and $script:Cmdlet.ShouldProcess('确认执行', $Item.Desc)) {
        $ans = ''
        try { $ans = Read-Host '  该项存在不可回滚风险，输入 YES 继续' } catch { $ans = '' }
        if ($ans -ne 'YES') {
            Write-Log ('用户取消：{0}' -f $Item.Id) 'SKIP'
            return
        }
    }

    $state = $null
    try { $state = & $Item.GetState } catch { $state = $null }

    $record = [ordered]@{
        Kind     = 'Cmd'
        Id       = $Item.Id
        Tier     = $Item.Tier
        OldState = [string]$state
        Applied  = $false
    }

    $approved = $script:Cmdlet.ShouldProcess($Item.Desc, '执行')
    if ($script:DryRun) {
        Write-Log ('[演练] 将执行：{0}' -f $Item.Desc) 'SKIP'
        if (-not $approved) { return }
    }
    elseif ($approved) {
        try {
            & $Item.DoAction
            $record.Applied = $true
            Write-Log ('已应用 [{0}] {1}' -f $Item.Tier, $Item.Desc) 'OK'
        }
        catch {
            Write-Log ('执行失败 {0}：{1}' -f $Item.Id, $_.Exception.Message) 'ERROR'
        }
    }
    [void]$script:Records.Add([pscustomobject]$record)
}

function Invoke-Rollback {
    $manifestPath = Get-LatestManifest
    if ($null -eq $manifestPath) {
        Write-Log ('未找到变更清单，目录：{0}' -f $BackupDir) 'ERROR'
        return
    }

    $data = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Log ('回滚清单：{0}（{1} 条记录，{2}）' -f $manifestPath, @($data.Records).Count, $data.Stamp)

    $applied = @($data.Records) | Where-Object { $_.Applied }
    if (-not $applied) { Write-Log '该清单没有已生效的变更' 'SKIP'; return }

    # 逆序还原（后改的先退）
    $reversed = @($applied)
    [array]::Reverse($reversed)

    foreach ($rec in $reversed) {
        if ($rec.Kind -eq 'Reg') {
            $root = Get-HiveRoot $rec.Hive
            $key = $null
            try { $key = $root.OpenSubKey([string]$rec.Path, $true) } catch { $key = $null }
            if ($null -eq $key) {
                Write-Log ('键不存在，无需还原：{0}' -f $rec.Id) 'SKIP'
                continue
            }
            try {
                if ($rec.OldExists) {
                    $val = ConvertFrom-StateValue $rec.OldValue $rec.OldKind
                    $kind = [Microsoft.Win32.RegistryValueKind]$rec.OldKind
                    $key.SetValue([string]$rec.Name, $val, $kind)
                    Write-Log ('已还原 {0} = {1}' -f $rec.Id, $val) 'OK'
                }
                else {
                    $key.DeleteValue([string]$rec.Name, $false)
                    Write-Log ('已删除本次写入的值 {0}' -f $rec.Id) 'OK'
                }
            }
            catch {
                Write-Log ('还原失败 {0}：{1}' -f $rec.Id, $_.Exception.Message) 'ERROR'
            }
            finally {
                $key.Close()
            }

            if (-not $rec.OldExists -and -not $rec.KeyExisted) {
                Remove-RegKeyTree -Hive $rec.Hive -Path $rec.Path
                Write-Log ('已删除本次新建的键 {0}' -f $rec.Path) 'OK'
            }
        }
        elseif ($rec.Kind -eq 'Cmd') {
            $item = Get-OptimizationItems -IncludeAll | Where-Object { $_.Id -eq $rec.Id } | Select-Object -First 1
            if ($null -eq $item) {
                Write-Log ('未找到回滚定义，跳过：{0}' -f $rec.Id) 'WARN'
                continue
            }
            try {
                & $item.UndoAction $rec.OldState
                Write-Log ('已回滚 {0}（原状态：{1}）' -f $rec.Id, $rec.OldState) 'OK'
            }
            catch {
                Write-Log ('回滚失败 {0}：{1}' -f $rec.Id, $_.Exception.Message) 'ERROR'
            }
        }
    }

    Write-Log '回滚完成。涉及界面的项需重新登录或重启资源管理器后生效。' 'OK'
}

# ---------------------------------------------------------------- 基线采集

function Invoke-Report {
    $os = Get-OsInfo
    $lines = @()

    $lines += ('# 基线报告 · {0}' -f $env:COMPUTERNAME)
    $lines += ('')
    $lines += ('采集时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines += ('模式：只读（未做任何修改）')
    $lines += ('')
    $lines += ('')

    # 系统
    $lines += ('## 系统')
    $lines += ('')
    $lines += ('| 项 | 值 |')
    $lines += ('|---|---|')
    $lines += ('| 版本 | {0} |' -f $os.Full)
    $lines += ('| 是否为 Win11 | {0} |' -f $os.IsWin11)
    $lines += ('')
    if (-not $os.IsWin11 -and $os.Build -ge 19041) {
        $lines += ('> **版本处置提示**：Win10 22H2 常规支持已于 2025-10-14 结束，消费者 ESU 已于 2026-10-13 到期。该机不应长期在网，请确认是否升 Win11 或已纳入企业 ESU。')
        $lines += ('')
    }

    # 存储
    $lines += ('## 存储')
    $lines += ('')
    $lines += ('| 项 | 值 |')
    $lines += ('|---|---|')
    try {
        $d = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
        $total = $d.Free + $d.Used
        $pct = [math]::Round(($d.Free / $total) * 100, 1)
        $lines += ('| 系统盘 | {0} 可用 {1} GB / 共 {2} GB（{3}%） |' -f $env:SystemDrive, [math]::Round($d.Free / 1GB, 1), [math]::Round($total / 1GB, 1), $pct)
        if ($pct -lt 15) { $lines += ('| 判定 | **可用空间不足 15%，优先做组件清理** |') }
    }
    catch { $lines += ('| 系统盘 | 读取失败 |') }

    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.BusType -ne 'USB' }
        foreach ($disk in $disks) {
            $lines += ('| 物理磁盘 | {0} / {1} / {2} GB |' -f $disk.FriendlyName, $disk.MediaType, [math]::Round($disk.Size / 1GB, 0))
        }
    }
    catch { $lines += ('| 物理磁盘 | 读取失败（需管理员） |') }

    $trim = (& fsutil.exe behavior query DisableDeleteNotify 2>$null) -join ' '
    $lines += ('| TRIM | {0} |' -f ($trim -replace '\s+', ' '))
    $lines += ('')

    # 内存与占用
    $lines += ('## 内存与占用')
    $lines += ('')
    $lines += ('| 项 | 值 |')
    $lines += ('|---|---|')
    try {
        $osw = Get-CimInstance -ClassName Win32_OperatingSystem
        $totalGb = [math]::Round($osw.TotalVisibleMemorySize / 1MB, 1)
        $freeGb = [math]::Round($osw.FreePhysicalMemory / 1MB, 2)
        $lines += ('| 物理内存 | {0} GB，空闲 {1} GB，占用 {2} GB |' -f $totalGb, $freeGb, [math]::Round($totalGb - $freeGb, 2))
        $lines += ('| 低配判定（<=8GB） | {0} |' -f (Test-LowRam))
    }
    catch { $lines += ('| 物理内存 | 读取失败 |') }

    try {
        $s = Get-Counter -Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 3 -ErrorAction Stop
        $avg = ($s.CounterSamples | Measure-Object -Property CookedValue -Average).Average
        $lines += ('| 空闲 CPU（均值） | {0}%（目标 <=5%） |' -f [math]::Round($avg, 1))
    }
    catch { $lines += ('| 空闲 CPU | 读取失败 |') }

    $pf = Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue
    if ($pf) {
        foreach ($p in $pf) { $lines += ('| 页面文件 | {0}，{1} MB |' -f $p.Name, $p.AllocatedBaseSize) }
    }
    else {
        $lines += ('| 页面文件 | 未查询到（若被禁用属违规配置，需排查） |')
    }
    $lines += ('')

    # 开机耗时
    $lines += ('## 开机耗时（事件 ID 100）')
    $lines += ('')
    try {
        $evts = Get-WinEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational' -MaxEvents 60 -ErrorAction Stop |
                Where-Object { $_.Id -eq 100 } | Select-Object -First 5
        if ($evts) {
            $lines += ('| 时间 | 开机耗时 |')
            $lines += ('|---|---|')
            foreach ($e in $evts) {
                $xml = [xml]$e.ToXml()
                $node = $xml.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' }
                $ms = 0
                [void][int]::TryParse([string]$node.'#text', [ref]$ms)
                if ($ms -gt 0) {
                    $lines += ('| {0} | {1} 秒 |' -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'), [math]::Round($ms / 1000, 1))
                }
            }
        }
        else { $lines += ('未采集到事件 100 记录（该日志需系统运行一段时间后才有数据）') }
    }
    catch { $lines += ('未采集到数据：该日志需管理员权限，且系统需累计若干次启动后才有记录。原始信息：{0}' -f $_.Exception.Message) }
    $lines += ('')

    # 启动项
    $lines += ('## 启动项')
    $lines += ('')
    $lines += ('> 脚本只列清单与当前状态，**不替你决定关哪一项**。请到「任务管理器 → 启动应用」按"启动影响"列人工判定。')
    $lines += ('')
    $runKeys = @(
        @{ Hive = 'HKCU'; Path = 'Software\Microsoft\Windows\CurrentVersion\Run' },
        @{ Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run' }
    )
    $found = 0
    foreach ($rk in $runKeys) {
        $k = (Get-HiveRoot $rk.Hive).OpenSubKey($rk.Path, $false)
        if ($null -eq $k) { continue }
        foreach ($n in $k.GetValueNames()) {
            $lines += ('- **{0}** = {1}  （来源：{2}\Run）' -f $n, $k.GetValue($n), $rk.Hive)
            $found++
        }
        $k.Close()
    }
    if ($found -eq 0) { $lines += ('未发现 Run 键启动项。') }
    $lines += ('')

    # 电源与相关服务
    $lines += ('## 电源与相关服务')
    $lines += ('')
    $lines += ('| 项 | 值 |')
    $lines += ('|---|---|')
    $lines += ('| 机型判定 | {0} |' -f $(if (Test-DesktopMachine) { '台式机' } else { '笔记本 / 有电池' }))
    $lines += ('| 当前电源方案 GUID | {0} |' -f (Get-ActiveSchemeGuid))
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='SysMain'" -ErrorAction Stop
        $lines += ('| SysMain 启动类型 | {0}，状态 {1} |' -f $svc.StartMode, $svc.State)
    }
    catch { $lines += ('| SysMain | 读取失败 |') }
    try {
        $dg = Read-RegValue -Hive 'HKLM' -Path 'SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity'
        $lines += ('| VBS（仅供参考，脚本不改） | {0} |' -f $(if ($dg.Exists) { $dg.Value } else { '未设置（默认关闭）' }))
    }
    catch { }
    $lines += ('')

    $lines += ('## 下一步')
    $lines += ('')
    $lines += ('1. 按「任务管理器 → 启动应用」人工清理"启动影响 = 高"的条目。')
    $lines += ('2. 执行 L1：`.\Optimize-WinClient.ps1 -Level L1 -Role <Office|Dev|Design|Personal> -Apply -WhatIf` 预览后再去掉 -WhatIf。')
    $lines += ('3. 30 天后用同一命令重采基线，比对开机耗时是否改善 >=20%。')

    $text = $lines -join "`r`n"

    Write-Host ''
    Write-Host $text

    try {
        if (-not (Test-Path -LiteralPath $BackupDir)) {
            [void](New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction Stop)
        }
        $out = Join-Path $BackupDir ('baseline-{0}-{1}.md' -f $env:COMPUTERNAME, $script:Stamp)
        $text | Out-File -FilePath $out -Encoding utf8
        Write-Log ('基线报告已保存：{0}' -f $out) 'OK'
    }
    catch {
        Write-Log ('基线报告保存失败（不影响上面的输出）：{0}' -f $_.Exception.Message) 'WARN'
    }
}

# ---------------------------------------------------------------- 主流程

$script:RequestedLevel = $Level

# 安全闸门：没有 -Apply 一律视为演练，任何写入路径都不会被执行
$script:DryRun = ((-not $Apply) -or $WhatIfPreference)

if (-not (Test-Path -LiteralPath $BackupDir)) {
    try { [void](New-Item -ItemType Directory -Path $BackupDir -Force) } catch { }
}

if ($Rollback) {
    Invoke-Rollback
    exit 0
}

if ($Level -eq 'Report') {
    Invoke-Report
    exit 0
}

$os = Get-OsInfo
Write-Log ('目标：{0} | 级别 {1} | 机型 {2}' -f $os.Full, $Level, ($Role -join ','))
Write-Log ('备份目录：{0}' -f $BackupDir)

if (-not $Apply) {
    Write-Log '当前为预览模式：只列计划，不写入。确认无误后追加 -Apply。' 'WARN'
}

$isAdmin = Test-Admin
if (-not $isAdmin) {
    Write-Log '当前非管理员：HKLM 项会被跳过（HKCU 项仍可执行）。' 'WARN'
}

$items = @(Get-OptimizationItems)
if ($items.Count -eq 0) {
    Write-Log '没有匹配到适用项，请检查 -Level 与 -Role。' 'WARN'
    exit 0
}

Write-Log ('共 {0} 项待处理' -f $items.Count)
Write-Host ''
Write-Host ('{0,-32} {1,-4} {2}' -f 'ID', '级别', '说明') -ForegroundColor Cyan
Write-Host ('-' * 96) -ForegroundColor DarkGray

foreach ($item in $items) {
    $verdict = '适用'
    if ($item.ContainsKey('Win11Only') -and $item.Win11Only -and -not $os.IsWin11) { $verdict = '跳过（非 Win11）' }
    elseif ($item.Hive -eq 'HKLM' -and -not $isAdmin) { $verdict = '跳过（需管理员）' }
    elseif ($item.ContainsKey('Condition')) {
        $ok = $false
        try { $ok = [bool](& $item.Condition) } catch { $ok = $false }
        if (-not $ok) { $verdict = '跳过（条件不满足）' }
    }
    Write-Host ('{0,-32} {1,-4} {2}  [{3}]' -f $item.Id, $item.Tier, $item.Desc, $verdict)
}
Write-Host ''

foreach ($item in $items) {
    if ($item.ContainsKey('Win11Only') -and $item.Win11Only -and -not $os.IsWin11) {
        Write-Log ('跳过（非 Win11）：{0}' -f $item.Id) 'SKIP'
        continue
    }
    if ($item.Hive -eq 'HKLM' -and -not $isAdmin) {
        Write-Log ('跳过（需管理员）：{0}' -f $item.Id) 'SKIP'
        continue
    }
    if ($item.ContainsKey('Condition')) {
        $ok = $false
        try { $ok = [bool](& $item.Condition) } catch { $ok = $false }
        if (-not $ok) {
            Write-Log ('跳过（条件不满足）：{0}' -f $item.Id) 'SKIP'
            continue
        }
    }

    switch ($item.Kind) {
        'Reg' { Invoke-RegItem -Item $item }
        'Cmd' { Invoke-CmdItem -Item $item }
    }
}

Write-Host ''
$manifest = Save-Manifest
if ($manifest) {
    Write-Log ('变更清单已保存：{0}' -f $manifest) 'OK'
    Write-Log '如需撤销，执行：.\Optimize-WinClient.ps1 -Rollback' 'OK'
}
else {
    Write-Log '本次没有产生任何变更记录。' 'SKIP'
}
