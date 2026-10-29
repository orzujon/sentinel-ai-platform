Set-StrictMode -Version Latest

function ConvertTo-SentinelIpv4Number {
    param([Parameter(Mandatory)][string]$Address)
    $parsed = [System.Net.IPAddress]::Parse($Address)
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Only IPv4 addresses are supported: $Address"
    }
    $bytes = $parsed.GetAddressBytes()
    return ([uint64]$bytes[0] * 16777216) + ([uint64]$bytes[1] * 65536) + ([uint64]$bytes[2] * 256) + [uint64]$bytes[3]
}

function Get-SentinelSubnetRange {
    param([Parameter(Mandatory)][string]$CIDR)
    $parts = $CIDR.Split('/')
    if ($parts.Count -ne 2) { throw "Expected IPv4 CIDR: $CIDR" }
    $prefix = 0
    if (-not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 1 -or $prefix -gt 32) {
        throw "Unsupported IPv4 prefix in $CIDR"
    }
    $ip = ConvertTo-SentinelIpv4Number -Address $parts[0]
    $span = [uint64][math]::Pow(2, (32 - $prefix))
    $start = [uint64]([math]::Floor($ip / $span) * $span)
    return [pscustomobject]@{ Start = $start; End = ($start + $span - 1) }
}

function Test-SentinelSubnetsOverlap {
    param([string]$A, [string]$B)
    $aRange = Get-SentinelSubnetRange -CIDR $A
    $bRange = Get-SentinelSubnetRange -CIDR $B
    return ($aRange.Start -le $bRange.End -and $bRange.Start -le $aRange.End)
}

function Invoke-SentinelPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$RunDirectory
    )

    # The only filesystem writes in this function are reports UNDER RunDirectory.
    # No Windows feature, Hyper-V object, network or VM is changed.
    New-Item -ItemType Directory -Path $RunDirectory -Force | Out-Null
    $eventPath = Join-Path $RunDirectory 'events.jsonl'
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $start = [DateTime]::UtcNow

    function Write-SentinelEvent {
        param([string]$Event, [string]$Level, [string]$Message)
        $entry = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); event = $Event; level = $Level; message = $Message }
        ($entry | ConvertTo-Json -Compress -Depth 6) | Add-Content -LiteralPath $eventPath -Encoding UTF8
    }

    function Add-SentinelCheck {
        param([string]$Name, [string]$Status, [string]$Detail)
        $record = [pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail }
        $checks.Add($record)
        Write-SentinelEvent -Event 'check' -Level $Status -Message "$Name`: $Detail"
    }

    Write-SentinelEvent -Event 'stage-start' -Level 'INFO' -Message 'Read-only preflight started'

    # Config fail-closed checks, before touching Hyper-V cmdlets.
    $configValid = $true
    try {
        if ($Config.mode -ne 'isolated-sandbox') { throw 'mode must be isolated-sandbox' }
        if ($Config.vms.Count -ne 2) { throw 'exactly two target VMs must be declared' }
        $targetNames = @($Config.vms | ForEach-Object { [string]$_.name })
        $targetIPs = @($Config.vms | ForEach-Object { [string]$_.staticIP })
        if ((@($targetNames | Select-Object -Unique).Count -ne 2) -or (@($targetIPs | Select-Object -Unique).Count -ne 2)) {
            throw 'target VM names and IP addresses must be unique'
        }
        foreach ($target in $targetNames) {
            if ($target -in @($Config.protection.vmNames)) { throw "Protected VM name requested: $target" }
            if ($target -notmatch '^sentinel-l1-[a-z0-9-]+$') { throw "Unexpected sandbox VM name: $target" }
        }
        if ([string]$Config.paths.vmRoot -notmatch '^C:\\Sentinel\\Level1-Sandbox\\VMs(?:\\|$)') {
            throw 'VM path must stay inside the dedicated C:\Sentinel\Level1-Sandbox\VMs directory'
        }
        if ($Config.network.switch -in @($Config.protection.switchNames)) {
            throw 'Target switch is a protected switch'
        }
        if ([string]$Config.network.type -ne 'Internal') { throw 'Only an internal switch is permitted' }
        $labRange = Get-SentinelSubnetRange -CIDR ([string]$Config.network.subnet)
        foreach ($protectedSubnet in @($Config.protection.subnets)) {
            if (Test-SentinelSubnetsOverlap $Config.network.subnet $protectedSubnet) {
                throw "Sandbox network overlaps protected subnet: $protectedSubnet"
            }
        }
        $allIPs = @($targetIPs) + @([string]$Config.network.hostIP)
        if ((@($allIPs | Select-Object -Unique).Count) -ne 3) { throw 'Host and VM IP addresses must all be distinct' }
        foreach ($ip in $allIPs) {
            $asNumber = ConvertTo-SentinelIpv4Number $ip
            if ($asNumber -le $labRange.Start -or $asNumber -ge $labRange.End) {
                throw "Configured address outside usable subnet: $ip"
            }
        }
        foreach ($vm in @($Config.vms)) {
            if ([double]$vm.memoryStartupGB -lt 2 -or [double]$vm.diskGB -lt 20 -or [int]$vm.virtualProcessors -lt 1) {
                throw "Unsafe/unsupported VM sizing: $($vm.name)"
            }
        }
        Add-SentinelCheck 'Config protection' 'PASS' 'Isolated names, distinct IPs, dedicated switch and no protected subnet overlap'
    }
    catch {
        $configValid = $false
        Add-SentinelCheck 'Config protection' 'BLOCK' $_.Exception.Message
    }

    if ($configValid) {
    $isWindowsHost = ($env:OS -eq 'Windows_NT')
    if (-not $isWindowsHost) {
        Add-SentinelCheck 'Operating system' 'BLOCK' 'Run preflight on Windows 11 PowerShell, not inside WSL'
    }
    else {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            $osCaption = [string]$os.Caption
            if ($osCaption -notmatch 'Windows (10|11)' -or $osCaption -notmatch '(Pro|Professional|Enterprise|Education)') {
                Add-SentinelCheck 'Windows edition' 'BLOCK' "Unsupported or unverified edition: $osCaption"
            }
            else { Add-SentinelCheck 'Windows edition' 'PASS' $osCaption }

            $totalGB = [math]::Round(([double]$os.TotalVisibleMemorySize / 1MB), 2)
            $freeGB = [math]::Round(([double]$os.FreePhysicalMemory / 1MB), 2)
            $guestGB = [double](($Config.vms | Measure-Object -Property memoryStartupGB -Sum).Sum)
            $neededFreeGB = $guestGB + [double]$Config.capacity.hostRAMReserveGB
            if ($totalGB -lt [double]$Config.capacity.minHostTotalRAMGB) {
                Add-SentinelCheck 'Physical RAM total' 'BLOCK' "Total $totalGB GiB, policy minimum $($Config.capacity.minHostTotalRAMGB) GiB"
            }
            else { Add-SentinelCheck 'Physical RAM total' 'PASS' "Total $totalGB GiB" }

            if ($freeGB -lt $neededFreeGB) {
                Add-SentinelCheck 'Free RAM budget' 'BLOCK' "Free $freeGB GiB; need >= $neededFreeGB GiB for guests plus reserve. Existing VMs are NOT stopped."
            }
            else {
                Add-SentinelCheck 'Free RAM budget' 'PASS' "Free $freeGB GiB; startup guests $guestGB GiB plus host reserve $($Config.capacity.hostRAMReserveGB) GiB"
            }

            $logicalCores = [int]$cs.NumberOfLogicalProcessors
            $guestCPU = [int](($Config.vms | Measure-Object -Property virtualProcessors -Sum).Sum)
            $requiredCPU = $guestCPU + [int]$Config.capacity.hostLogicalCPUReserve
            if ($logicalCores -lt $requiredCPU) {
                Add-SentinelCheck 'CPU budget' 'BLOCK' "Logical processors $logicalCores; policy requires >= $requiredCPU"
            }
            else { Add-SentinelCheck 'CPU budget' 'PASS' "$logicalCores logical processors; $guestCPU configured vCPUs + $($Config.capacity.hostLogicalCPUReserve) reserved" }
        }
        catch { Add-SentinelCheck 'Host hardware' 'BLOCK' "Unable to collect host facts: $($_.Exception.Message)" }

        try {
            $diskRoot = [System.IO.Path]::GetPathRoot([string]$Config.paths.vmRoot)
            if ([string]::IsNullOrWhiteSpace($diskRoot)) { throw 'VM path needs an absolute Windows drive path' }
            $drive = [System.IO.DriveInfo]::new($diskRoot)
            if (-not $drive.IsReady) { throw "Drive $diskRoot is not ready" }
            $diskFree = [math]::Round($drive.AvailableFreeSpace / 1GB, 2)
            $guestDisk = [double](($Config.vms | Measure-Object -Property diskGB -Sum).Sum)
            $diskBudget = $guestDisk + [double]$Config.capacity.diskReserveGB
            if ($diskFree -lt $diskBudget) {
                Add-SentinelCheck 'Disk capacity' 'BLOCK' "Drive $diskRoot free $diskFree GiB; conservative target >= $diskBudget GiB"
            }
            else { Add-SentinelCheck 'Disk capacity' 'PASS' "Drive $diskRoot free $diskFree GiB; conservative budget $diskBudget GiB (dynamic VHDX can initially use less)" }
        }
        catch { Add-SentinelCheck 'Disk capacity' 'BLOCK' $_.Exception.Message }

        try {
            $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
            if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                Add-SentinelCheck 'Administrator rights' 'PASS' 'Elevated PowerShell session'
            }
            else { Add-SentinelCheck 'Administrator rights' 'BLOCK' 'Reopen Windows PowerShell as Administrator for later provisioning stages' }
        }
        catch { Add-SentinelCheck 'Administrator rights' 'BLOCK' $_.Exception.Message }

        try {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
            if ([string]$feature.State -eq 'Enabled') {
                Add-SentinelCheck 'Hyper-V feature' 'PASS' 'Windows Hyper-V is enabled'
            }
            else { Add-SentinelCheck 'Hyper-V feature' 'BLOCK' "Hyper-V is $($feature.State); first host-setup stage will require controlled enable/reboot" }
        }
        catch { Add-SentinelCheck 'Hyper-V feature' 'BLOCK' "Unable to inspect feature: $($_.Exception.Message)" }

        try {
            Import-Module Hyper-V -ErrorAction Stop
            $hyperVHost = Get-VMHost -ErrorAction Stop
            Add-SentinelCheck 'Hyper-V management' 'PASS' "Hyper-V cmdlets operational on $($hyperVHost.ComputerName)"
        }
        catch { Add-SentinelCheck 'Hyper-V management' 'BLOCK' $_.Exception.Message }

        try {
            $allVMs = @(Get-VM -ErrorAction Stop)
            $collisionNames = @($allVMs | Where-Object { $_.Name -in @($Config.vms | ForEach-Object { $_.name }) } | ForEach-Object { $_.Name })
            if ($collisionNames.Count -gt 0) {
                Add-SentinelCheck 'Target VM name collisions' 'BLOCK' ('Already exist: ' + ($collisionNames -join ', ') + '; never overwrite or auto-adopt')
            }
            else { Add-SentinelCheck 'Target VM name collisions' 'PASS' 'No planned sandbox VM names exist' }

            $protected = @($allVMs | Where-Object { $_.Name -in @($Config.protection.vmNames) })
            $summary = if ($protected.Count -eq 0) { 'No protected VMs found' } else { ($protected | ForEach-Object { "$($_.Name)=$($_.State)" }) -join '; ' }
            Add-SentinelCheck 'Existing VM protection' 'PASS' "Read-only observation: $summary. Protected names never targeted."
        }
        catch { Add-SentinelCheck 'VM inventory' 'BLOCK' "Unable to inspect existing VMs: $($_.Exception.Message)" }

        try {
            $switches = @(Get-VMSwitch -ErrorAction Stop)
            $collision = @($switches | Where-Object { $_.Name -eq [string]$Config.network.switch })
            if ($collision.Count -gt 0) {
                Add-SentinelCheck 'Sandbox switch collision' 'BLOCK' "Switch $($Config.network.switch) already exists; explicit adoption procedure required"
            }
            else { Add-SentinelCheck 'Sandbox switch collision' 'PASS' 'No planned switch name collision' }
        }
        catch { Add-SentinelCheck 'Switch inventory' 'BLOCK' $_.Exception.Message }

        try {
            $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)
            $overlaps = @()
            foreach ($route in $routes) {
                $prefix = [string]$route.DestinationPrefix
                if ($prefix -eq '0.0.0.0/0') { continue }
                if (Test-SentinelSubnetsOverlap $Config.network.subnet $prefix) {
                    $overlaps += "$prefix ($($route.InterfaceAlias))"
                }
            }
            if ($overlaps.Count -gt 0) {
                Add-SentinelCheck 'Subnet route conflicts' 'BLOCK' ('Existing overlapping routes: ' + (($overlaps | Select-Object -Unique) -join ', '))
            }
            else { Add-SentinelCheck 'Subnet route conflicts' 'PASS' "No nondefault IPv4 route overlaps $($Config.network.subnet)" }
        }
        catch { Add-SentinelCheck 'Subnet route conflicts' 'BLOCK' $_.Exception.Message }

        try {
            $wslExe = Get-Command 'wsl.exe' -ErrorAction Stop
            Add-SentinelCheck 'WSL executable' 'PASS' "Found $($wslExe.Source); Ubuntu/Ansible availability is a later-stage check"
        }
        catch { Add-SentinelCheck 'WSL executable' 'WARN' 'WSL command missing; later host setup must install/configure it' }
    }

    if (-not $Config.image.expectedSha256 -or [string]$Config.image.expectedSha256 -notmatch '^[a-fA-F0-9]{64}$') {
        Add-SentinelCheck 'Approved image digest' 'WARN' 'Ubuntu digest not pinned yet. Image acquisition stage MUST block until verified SHA256 is supplied.'
    }
    else { Add-SentinelCheck 'Approved image digest' 'PASS' 'A 64-character expected digest is configured; image validation comes later' }

    } # End of checks that require valid config

    $blocked = @($checks | Where-Object Status -eq 'BLOCK').Count
    $warned = @($checks | Where-Object Status -eq 'WARN').Count
    $result = if ($blocked -gt 0) { 'BLOCKED' } elseif ($warned -gt 0) { 'READY_WITH_WARNINGS' } else { 'READY' }
    $ended = [DateTime]::UtcNow
    $report = [ordered]@{
        schemaVersion = '1.0'
        stage = 'preflight'
        runId = (Split-Path -Leaf $RunDirectory)
        startedUtc = $start.ToString('o')
        finishedUtc = $ended.ToString('o')
        durationSeconds = [math]::Round(($ended - $start).TotalSeconds, 3)
        result = $result
        mode = 'READ_ONLY'
        mutationsToHyperV = 0
        labName = $Config.lab
        checks = @($checks.ToArray())
        counts = [ordered]@{ pass = @($checks | Where-Object Status -eq 'PASS').Count; warn = $warned; block = $blocked }
    }
    $reportPath = Join-Path $RunDirectory 'preflight.json'
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-SentinelEvent -Event 'stage-end' -Level $result -Message "Completed: $result; passes=$($report.counts.pass), warnings=$warned, blockers=$blocked"

    return [pscustomobject]@{ Result = $result; Checks = @($checks.ToArray()); ReportPath = $reportPath; EventPath = $eventPath; RunId = $report.runId; Counts = $report.counts }
}

Export-ModuleMember -Function Invoke-SentinelPreflight, Test-SentinelSubnetsOverlap
