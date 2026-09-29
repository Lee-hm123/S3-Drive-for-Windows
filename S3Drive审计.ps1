param()

$ErrorActionPreference='Continue'
$ToolRoot=Split-Path -Parent $PSCommandPath
$ConfigPath=Join-Path $ToolRoot '配置.json'
$BaseDir=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'S3Drive\buckets'
$ProgramExitFile=Join-Path (Split-Path -Parent $BaseDir) 'exit.request'
$new=$false;$mutex=[Threading.Mutex]::new($true,'S3Drive-Audit',[ref]$new);if(-not$new){exit 0}

function Get-Buckets { @(((Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json).buckets)|Where-Object{$_.enabled -ne $false}) }
function Write-Audit($Bucket,[string]$EventId,[hashtable]$Data) {
    $dir=Join-Path (Join-Path $BaseDir $Bucket.id) 'logs';if(-not(Test-Path $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
    $file=Join-Path $dir 'local-operations.jsonl';if((Test-Path $file) -and (Get-Item $file).Length -gt 5MB){Move-Item $file ("$file.{0:yyyyMMdd-HHmmss}.old" -f (Get-Date)) -Force}
    [ordered]@{timestamp=(Get-Date).ToString('o');eventId=$EventId;bucketId=$Bucket.id;remote=$Bucket.remote;drive=$Bucket.drive;data=$Data}|ConvertTo-Json -Compress|Add-Content -LiteralPath $file -Encoding utf8
}

try {
    $watchers=@{}
    while($true) {
        if(Test-Path -LiteralPath $ProgramExitFile){exit 0}
        foreach($b in @(Get-Buckets)) {
            if($watchers.ContainsKey($b.id) -or -not(Test-Path -LiteralPath "$($b.drive)\")){continue}
            $w=New-Object IO.FileSystemWatcher;$w.Path="$($b.drive)\";$w.Filter='*';$w.IncludeSubdirectories=$true;$w.NotifyFilter=[IO.NotifyFilters]'FileName, DirectoryName';$w.InternalBufferSize=65536
            foreach($name in @('Created','Deleted','Renamed')){Register-ObjectEvent -InputObject $w -EventName $name -SourceIdentifier "S3Drive-Audit-$($b.id)-$name"|Out-Null};$w.EnableRaisingEvents=$true;$watchers[$b.id]=$w;Write-Audit $b 'audit.attached' @{}
        }
        $event=Wait-Event -Timeout 3;if(-not $event){continue};$match=[regex]::Match($event.SourceIdentifier,'^S3Drive-Audit-(.+)-(Created|Deleted|Renamed)$');$id=$match.Groups[1].Value;$kind=$match.Groups[2].Value;$bucket=@(Get-Buckets|Where-Object id -eq $id)[0]
        if($bucket){$args=$event.SourceEventArgs;$data=if($kind -eq 'Renamed'){@{oldPath=$args.OldFullPath;path=$args.FullPath}}else{@{path=$args.FullPath}};Write-Audit $bucket ("local.{0}.observed" -f $kind.ToLower()) $data}
        Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
    }
} catch { foreach($b in @(Get-Buckets)){Write-Audit $b 'audit.error' @{message=$_.Exception.Message}};exit 1
} finally { foreach($w in $watchers.Values){$w.Dispose()};if($mutex){$mutex.ReleaseMutex();$mutex.Dispose()} }
