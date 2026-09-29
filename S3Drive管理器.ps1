param(
    [ValidateSet('Start', 'Stop', 'Status', 'Refresh', 'Tray')]
    [string]$Mode = 'Start',
    [string]$BucketId
)

$ErrorActionPreference = 'Stop'
$ToolRoot = Split-Path -Parent $PSCommandPath
$Rclone = Join-Path $ToolRoot 'rclone\rclone.exe'
$ConfigPath = Join-Path $ToolRoot '配置.json'
$BaseDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'S3Drive\buckets'
$ProgramExitFile = Join-Path (Split-Path -Parent $BaseDir) 'exit.request'

# Must run before loading WinForms. It prevents Windows from bitmap-scaling
# tray menus and status dialogs on high-DPI displays.
if (-not ('S3DriveDpi' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class S3DriveDpi {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}
'@
}
try {
    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 (-4), supported by modern Windows 10/11.
    [S3DriveDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
} catch {
    [S3DriveDpi]::SetProcessDPIAware() | Out-Null
}

function Get-Buckets {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "找不到配置：$ConfigPath" }
    $buckets = @(((Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json).buckets) | Where-Object { $_.enabled -ne $false })
    if (-not $buckets.Count) { throw '没有启用的桶配置。' }
    $ids=@{}; $drives=@{}; $ports=@{}
    foreach($b in $buckets) {
        if (-not $b.id -or $b.id -notmatch '^[A-Za-z0-9_-]+$') { throw '桶 id 只能含字母、数字、连字符和下划线。' }
        if (-not $b.remote -or $b.remote -notmatch '^[^:]+:.+') { throw "桶 $($b.id) 的 remote 无效。" }
        if (-not $b.drive -or $b.drive -notmatch '^[A-Za-z]:$') { throw "桶 $($b.id) 的盘符无效。" }
        if (-not $b.rcPort -or [int]$b.rcPort -lt 1024 -or [int]$b.rcPort -gt 65535) { throw "桶 $($b.id) 的 RC 端口无效。" }
        if($ids[$b.id] -or $drives[$b.drive.ToUpper()] -or $ports[[int]$b.rcPort]) { throw '已启用的桶不能共用 id、盘符或 RC 端口。' }
        $ids[$b.id]=$true; $drives[$b.drive.ToUpper()]=$true; $ports[[int]$b.rcPort]=$true
    }
    $buckets
}

function Select-Buckets {
    $buckets=@(Get-Buckets)
    if (-not $BucketId) { return $buckets }
    $match=@($buckets | Where-Object id -eq $BucketId)
    if(-not $match.Count){throw "未找到已启用桶：$BucketId"}; $match
}

function Get-BucketPaths($Bucket) {
    $root=Join-Path $BaseDir $Bucket.id
    [pscustomobject]@{Root=$root; LogDir=(Join-Path $root 'logs'); StateDir=(Join-Path $root 'state'); CacheDir=(Join-Path $root 'cache'); ManagerLog=(Join-Path $root 'logs\manager.log'); RcloneLog=(Join-Path $root 'logs\rclone.log'); OperationsLog=(Join-Path $root 'logs\operations.jsonl'); PauseFile=(Join-Path $root 'state\paused'); QuotaCache=(Join-Path $root 'state\quota.json')}
}

function Initialize-Bucket($Bucket) {
    $p=Get-BucketPaths $Bucket
    foreach($d in @($p.Root,$p.LogDir,$p.StateDir,$p.CacheDir)){if(-not(Test-Path -LiteralPath $d)){New-Item -ItemType Directory -Path $d -Force|Out-Null}}
    foreach($file in @($p.ManagerLog,$p.OperationsLog)) { if((Test-Path $file) -and (Get-Item $file).Length -gt 5MB){Move-Item $file ("$file.{0:yyyyMMdd-HHmmss}.old" -f (Get-Date)) -Force} }
    $p
}

function Write-Log($Bucket,[string]$Message,[string]$EventId='manager.info',[string]$Level='Information') {
    $p=Initialize-Bucket $Bucket; $time=Get-Date
    Add-Content -LiteralPath $p.ManagerLog -Value ("{0:o} [{1}] {2}" -f $time,$Bucket.id,$Message)
    $event=[ordered]@{timestamp=$time.ToString('o');level=$Level;eventId=$EventId;bucketId=$Bucket.id;displayName=$Bucket.displayName;remote=$Bucket.remote;drive=$Bucket.drive;message=$Message}
    Add-Content -LiteralPath $p.OperationsLog -Value ($event|ConvertTo-Json -Compress) -Encoding utf8
}

function Invoke-BucketRc($Bucket,[string]$Endpoint,[string[]]$Arguments=@()) {
    try{
        $raw=& $Rclone rc --url "http://127.0.0.1:$($Bucket.rcPort)" $Endpoint @Arguments 2>$null
        if($LASTEXITCODE -ne 0 -or -not $raw){return $null}
        try{return $raw|ConvertFrom-Json}
        catch{
            # vfs/refresh returns {"result":{"":"OK"}}; Windows PowerShell 5 cannot parse an empty JSON property name.
            return [pscustomobject]@{Raw=($raw -join "`n")}
        }
    }catch{return $null}
}

function Refresh-Bucket($Bucket) {
    $status=Get-BucketStatus $Bucket
    if($status.State -in @('Stopped','Disconnected','LegacyMount')){return $false}
    $result=Invoke-BucketRc $Bucket 'vfs/refresh' @('recursive=true')
    if($null -eq $result){Write-Log $Bucket 'Server directory refresh failed: rclone RC was unavailable.' 'server-refresh.failed' 'Warning';return $false}
    Write-Log $Bucket 'Server directory metadata refreshed recursively.' 'server-refresh.succeeded'
    return $true
}

function Format-ByteSize([Nullable[long]]$Bytes) {
    if ($null -eq $Bytes) { return '未知' }
    $value=[double]$Bytes
    foreach($unit in @('B','KB','MB','GB','TB','PB')) {
        if($value -lt 1024 -or $unit -eq 'PB'){return ('{0:N2} {1}' -f $value,$unit)}
        $value/=1024
    }
}

function Get-BucketQuota($Bucket,[switch]$Force) {
    # S3 has no portable bucket-quota API. Optionally set quotaTotalBytes in
    # the local template to display a fixed Explorer capacity bar.
    if($Bucket.quotaTotalBytes){return [pscustomobject]@{timestamp=(Get-Date).ToString('o');source='config-fallback';bucket='';totalBytes=[long]$Bucket.quotaTotalBytes;usedBytes=$null;freeBytes=$null}}
    return $null
}

function Get-BucketStatus($Bucket) {
    $p=Get-BucketPaths $Bucket;$mounted=Test-Path -LiteralPath "$($Bucket.drive)\";$vfs=Invoke-BucketRc $Bucket 'vfs/stats';$core=Invoke-BucketRc $Bucket 'core/stats';$quota=Get-BucketQuota $Bucket;$queued=0;$uploading=0;$failed=0
    if($vfs -and $vfs.diskCache){$queued=[int]$vfs.diskCache.uploadsQueued;$uploading=[int]$vfs.diskCache.uploadsInProgress;$failed=[int]$vfs.diskCache.erroredFiles}
    $state=if(Test-Path $p.PauseFile){'Stopped'}elseif(-not $mounted){'Disconnected'}elseif(-not $vfs){'LegacyMount'}elseif($failed -gt 0){'Error'}elseif($queued -gt 0 -or $uploading -gt 0){'Syncing'}else{'Connected'}
    [pscustomobject]@{BucketId=$Bucket.id;Name=$Bucket.displayName;Remote=$Bucket.remote;Drive=$Bucket.drive;RcPort=$Bucket.rcPort;State=$state;Queued=$queued;Uploading=$uploading;Failed=$failed;Errors=if($core){[int]$core.errors}else{0};Total=if($quota){Format-ByteSize $quota.totalBytes}else{'未知'};Used=if($quota){Format-ByteSize $quota.usedBytes}else{'未知'};Free=if($quota){Format-ByteSize $quota.freeBytes}else{'未知'};TotalBytes=if($quota){[long]$quota.totalBytes}else{$null};UsedBytes=if($quota -and $null -ne $quota.usedBytes){[long]$quota.usedBytes}else{$null};FreeBytes=if($quota -and $null -ne $quota.freeBytes){[long]$quota.freeBytes}else{$null};QuotaSource=if($quota){$quota.source}else{'none'};LogDirectory=$p.LogDir}
}

function Start-BucketUnsafe($Bucket) {
    $p=Initialize-Bucket $Bucket;Remove-Item $p.PauseFile -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath "$($Bucket.drive)\"){Write-Log $Bucket 'Drive already mounted.' 'mount.already-mounted';return $true}
    if(-not(Test-Path $Rclone)){throw "找不到 rclone：$Rclone"}
    $quota=Get-BucketQuota $Bucket -Force
    # Performance profile: 8 parallel files; large S3 uploads use 8 × 16 MiB parts.
    # Maximum upload buffering per mounted bucket is approximately 8 × 8 × 16 MiB = 1 GiB.
    # Do not use --s3-no-head here: the post-upload verification is retained for data safety.
    $args=@('mount',$Bucket.remote,$Bucket.drive,'--vfs-cache-mode',$Bucket.vfsCacheMode,'--vfs-write-back',$Bucket.vfsWriteBack,'--vfs-cache-max-age',$Bucket.vfsCacheMaxAge,'--vfs-cache-poll-interval',$Bucket.vfsCachePollInterval,'--dir-cache-time','0s','--poll-interval','0','--cache-dir',$p.CacheDir,'--volname',$Bucket.displayName,'--rc','--rc-addr',"127.0.0.1:$($Bucket.rcPort)",'--rc-no-auth','--no-console','--transfers','8','--s3-upload-concurrency','8','--s3-chunk-size','16M','--vfs-read-chunk-streams','4','--vfs-read-chunk-size','16M','--vfs-read-chunk-size-limit','64M','--use-server-modtime','--log-file',$p.RcloneLog,'--log-level','INFO','--log-file-max-size','20M','--log-file-max-backups','5','--log-file-max-age','14d','--windows-event-log-level','ERROR','--retries','10','--low-level-retries','20','--retries-sleep','10s','--contimeout','15s','--timeout','1m')
    if($quota -and [long]$quota.totalBytes -gt 0){$args+=@('--vfs-disk-space-total-size',("{0}B" -f [long]$quota.totalBytes),'--vfs-used-is-size')}
    Write-Log $Bucket "Starting mount: $($Bucket.remote) -> $($Bucket.drive)." 'mount.requested'
    # Start-Process joins an argument array into one command line. Quote each value
    # explicitly so volume names containing spaces remain one rclone argument.
    $argumentLine=(($args | ForEach-Object { '"{0}"' -f ($_ -replace '"','\"') }) -join ' ')
    $proc=Start-Process -FilePath $Rclone -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
    for($i=0;$i -lt 20;$i++){Start-Sleep 1;if(Test-Path -LiteralPath "$($Bucket.drive)\"){Write-Log $Bucket "Mount succeeded, PID $($proc.Id)." 'mount.succeeded';return $true};$proc.Refresh();if($proc.HasExited){Write-Log $Bucket "Mount failed; rclone exit code $($proc.ExitCode)." 'mount.failed' 'Error';return $false}}
    Write-Log $Bucket 'Mount timed out.' 'mount.timed-out' 'Error';$false
}

function Start-Bucket($Bucket) {
    # A named mutex also protects against a manual start racing the tray's recovery loop.
    $mutex=[Threading.Mutex]::new($false,"S3Drive-Mount-$($Bucket.id)")
    $locked=$false
    try {
        $locked=$mutex.WaitOne(30000)
        if(-not $locked){Write-Log $Bucket 'Mount skipped: another start is still in progress.' 'mount.busy' 'Warning';return $false}
        Start-BucketUnsafe $Bucket
    } finally {
        if($locked){$mutex.ReleaseMutex()}
        $mutex.Dispose()
    }
}

function Stop-Bucket($Bucket) {
    $p=Initialize-Bucket $Bucket
    $status=Get-BucketStatus $Bucket
    if($status.Queued -gt 0 -or $status.Uploading -gt 0){
        Write-Log $Bucket "Safe stop blocked: queued=$($status.Queued), uploading=$($status.Uploading)." 'unmount.blocked' 'Warning'
        throw "$($Bucket.displayName) 仍有文件未同步完成（等待上传 $($status.Queued)，上传中 $($status.Uploading)）。请等待状态恢复 Connected 后再退出。"
    }
    Set-Content $p.PauseFile (Get-Date -Format o)
    if(-not(Test-Path -LiteralPath "$($Bucket.drive)\")){Write-Log $Bucket 'Drive already unmounted.' 'unmount.already-stopped';return $true}
    Write-Log $Bucket 'Requesting graceful stop through rclone RC.' 'unmount.requested'
    if($null -eq (Invoke-BucketRc $Bucket 'core/quit')){Write-Log $Bucket 'Safe stop failed: RC unavailable.' 'unmount.failed' 'Error';throw "$($Bucket.id) 无法安全退出：RC 不可用。"}
    for($i=0;$i -lt 30;$i++){Start-Sleep 1;if(-not(Test-Path -LiteralPath "$($Bucket.drive)\")){Write-Log $Bucket 'Drive safely unmounted.' 'unmount.succeeded';return $true}}
    throw "$($Bucket.drive) 仍在使用；请关闭其中的文件后重试。"
}

function Exit-S3DriveProgram($NotifyIcon) {
    $buckets = @(Get-Buckets)
    $busy = @()
    foreach ($bucket in $buckets) {
        $status = Get-BucketStatus $bucket
        if ($status.Queued -gt 0 -or $status.Uploading -gt 0) {
            $busy += "$($bucket.displayName)：等待上传 $($status.Queued)，上传中 $($status.Uploading)"
        }
    }
    if ($busy.Count) {
        throw "仍有文件未同步完成，不能退出程序。`n$($busy -join "`n")"
    }
    foreach ($bucket in $buckets) { Stop-Bucket $bucket | Out-Null }
    New-Item -ItemType File -Path $ProgramExitFile -Force | Out-Null
    $NotifyIcon.Visible = $false
    [Windows.Forms.Application]::Exit()
}

function Start-Tray {
    Add-Type -AssemblyName System.Windows.Forms;Add-Type -AssemblyName System.Drawing
    $new=$false;$mutex=[Threading.Mutex]::new($true,'S3Drive-Tray',[ref]$new);if(-not$new){return}
    try{
        foreach($b in @(Get-Buckets)){Start-Bucket $b|Out-Null};$notify=New-Object Windows.Forms.NotifyIcon;$notify.Icon=[Drawing.SystemIcons]::Information;$notify.Visible=$true
        $menu=New-Object Windows.Forms.ContextMenuStrip;$notify.ContextMenuStrip=$menu
        foreach($b in @(Get-Buckets)){$id=$b.id;$item=$menu.Items.Add("$($b.displayName) [$($b.drive)]");$open=$item.DropDownItems.Add('打开');$open.add_Click(({Start-Process explorer.exe "$((Get-Buckets|Where-Object id -eq $id).drive)\"}).GetNewClosure());$status=$item.DropDownItems.Add('状态');$status.add_Click(({[Windows.Forms.MessageBox]::Show(((Get-BucketStatus (Get-Buckets|Where-Object id -eq $id))|Format-List|Out-String),'S3 桶状态')|Out-Null}).GetNewClosure());$stop=$item.DropDownItems.Add('安全退出此桶');$stop.add_Click(({try{Stop-Bucket (Get-Buckets|Where-Object id -eq $id)|Out-Null;$notify.ShowBalloonTip(5000,'S3 Drive',"$id 已安全退出。",[Windows.Forms.ToolTipIcon]::Info)}catch{$notify.ShowBalloonTip(10000,'S3 Drive 退出失败',$_.Exception.Message,[Windows.Forms.ToolTipIcon]::Error)}}).GetNewClosure())}
        $menu.Items.Add('-') | Out-Null
        $refreshNow=$menu.Items.Add('立即从服务器刷新目录')
        $refreshNow.add_Click({
            $ok=0
            foreach($bucket in @(Get-Buckets)){if(Refresh-Bucket $bucket){$ok++}}
            $notify.ShowBalloonTip(5000,'S3 Drive',"已请求刷新 $ok 个已连接桶的服务器目录。按 F5 可立即重绘资源管理器列表。",[Windows.Forms.ToolTipIcon]::Info)
        })
        $exitProgram=$menu.Items.Add('退出程序（安全停止全部桶）')
        $exitProgram.add_Click({
            try { Exit-S3DriveProgram $notify }
            catch { $notify.ShowBalloonTip(10000,'S3 Drive 无法退出',$_.Exception.Message,[Windows.Forms.ToolTipIcon]::Error) }
        })
        $lastMonitorError=''
        $nextServerRefresh=(Get-Date).AddMinutes(5)
        $timer=New-Object Windows.Forms.Timer;$timer.Interval=5000
        $timer.add_Tick({
            try {
                $states=@()
                foreach($b in @(Get-Buckets)){
                    $s=Get-BucketStatus $b;$states+=$s
                    if($s.State -eq 'Disconnected' -and -not(Test-Path (Get-BucketPaths $b).PauseFile)){
                        Write-Log $b 'Disconnected; automatic recovery requested.' 'mount.recovery'
                        Start-Bucket $b|Out-Null
                    }
                }
                if((Get-Date) -ge $nextServerRefresh){
                    foreach($b in @(Get-Buckets)){Refresh-Bucket $b|Out-Null}
                    $nextServerRefresh=(Get-Date).AddMinutes(5)
                }
                $notify.Text="S3 Drive：$($states.Count) 个桶"
                $lastMonitorError=''
            } catch {
                # A missing or temporarily invalid configuration must not escape a WinForms timer callback.
                $message=$_.Exception.Message
                $notify.Text='S3 Drive：配置或状态错误';$notify.Icon=[Drawing.SystemIcons]::Error
                $errorLog=Join-Path $BaseDir 'manager-errors.log'
                Add-Content -LiteralPath $errorLog -Value ("{0:o} {1}" -f (Get-Date),$message)
                if($lastMonitorError -ne $message){$notify.ShowBalloonTip(10000,'S3 Drive 错误',$message,[Windows.Forms.ToolTipIcon]::Error);$lastMonitorError=$message}
            }
        })
        $timer.Start();[Windows.Forms.Application]::Run()
    }finally{if($mutex){$mutex.ReleaseMutex();$mutex.Dispose()}}
}

try{switch($Mode){'Start'{foreach($b in @(Select-Buckets)){if(-not(Start-Bucket $b)){exit 1}}}'Stop'{foreach($b in @(Select-Buckets)){if(-not(Stop-Bucket $b)){exit 1}}}'Status'{@(Select-Buckets|ForEach-Object{Get-BucketStatus $_})|ConvertTo-Json -Depth 4}'Refresh'{foreach($b in @(Select-Buckets)){Refresh-Bucket $b|Out-Null}}'Tray'{Start-Tray}}}catch{Write-Error $_.Exception.Message;exit 1}
