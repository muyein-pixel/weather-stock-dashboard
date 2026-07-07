# Korea weather dashboard local server
# Usage: .\start.ps1

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Port = 8082
$ApiKey = "77fc6bf77fb3921f2558527cb6a39f719028aaeca64b5c42e79f76ffbf6a8146"
$FcstUrl = "http://apis.data.go.kr/1360000/VilageFcstInfoService_2.0/getVilageFcst"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:CachedData = $null
$script:CacheTime = $null
$CacheMinutes = 10

$Regions = Get-Content (Join-Path $Root "regions.json") -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-ApiItems {
    param([object]$Body)
    if ($null -eq $Body.items.item) { return @() }
    $items = $Body.items.item
    if ($items -isnot [System.Array]) { return @($items) }
    return $items
}

function Get-VilageBaseCandidates {
    $now = Get-Date
    $list = New-Object System.Collections.Generic.List[hashtable]
    $times = @(2300, 2000, 1700, 1400, 1100, 800, 500, 200)

    foreach ($t in $times) {
        $hour = [math]::Floor($t / 100)
        $minute = $t % 100
        $candidate = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $hour -Minute $minute -Second 0
        if ($now -ge $candidate.AddMinutes(10)) {
            $list.Add(@{
                base_date = $candidate.ToString("yyyyMMdd")
                base_time = "{0:D4}" -f $t
            }) | Out-Null
        }
    }

    if ($list.Count -eq 0) {
        $prev = $now.AddDays(-1)
        $list.Add(@{
            base_date = $prev.ToString("yyyyMMdd")
            base_time = "2300"
        }) | Out-Null
    }

    return @($list)
}

function Get-VilageBaseDateTime {
    return (Get-VilageBaseCandidates)[0]
}

function Get-FcstTargetTime {
    $now = Get-Date
    $next = $now.AddHours(1)
    return @{
        fcst_date = $now.ToString("yyyyMMdd")
        fcst_time = $next.ToString("HH") + "00"
    }
}

function Invoke-KmaApi {
    param(
        [string]$BaseUrl,
        [object]$Params,
        [int]$PageNo = 1,
        [int]$NumOfRows = 1000
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $query = @(
        "serviceKey=$ApiKey",
        "numOfRows=$NumOfRows",
        "pageNo=$PageNo",
        "dataType=JSON"
    )
    foreach ($key in ($Params.Keys | Sort-Object)) {
        $query += "$key=$($Params[$key])"
    }
    $url = "${BaseUrl}?$($query -join '&')"

    try {
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 30
        return $response
    }
    catch [System.Net.WebException] {
        $http = $_.Exception.Response
        if ($null -ne $http) {
            $reader = New-Object System.IO.StreamReader($http.GetResponseStream())
            $body = $reader.ReadToEnd()
            $reader.Close()
            try {
                $json = $body | ConvertFrom-Json
                if ($json.response.header.resultMsg) {
                    throw $json.response.header.resultMsg
                }
            }
            catch [System.Management.Automation.RuntimeException] {
                if ($_.Exception.Message -notlike "HTTP *") {
                    throw
                }
            }
            throw "HTTP $([int]$http.StatusCode): $body"
        }
        throw $_.Exception.Message
    }
}

function Get-KmaAllItems {
    param(
        [string]$BaseUrl,
        [object]$Params
    )

    $allItems = New-Object System.Collections.Generic.List[object]
    $page = 1
    $total = 0

    do {
        $result = Invoke-KmaApi -BaseUrl $BaseUrl -Params $Params -PageNo $page
        if ($result.response.header.resultCode -ne "00") {
            throw $result.response.header.resultMsg
        }
        $body = $result.response.body
        if ($null -ne $body.totalCount) {
            $total = [int]$body.totalCount
        }
        $items = Get-ApiItems $body
        foreach ($item in $items) {
            $allItems.Add($item) | Out-Null
        }
        $page++
    } while ($total -gt 0 -and $allItems.Count -lt $total -and $page -le 5)

    return @($allItems.ToArray())
}

function Invoke-KmaApiWithFallback {
    param(
        [string]$BaseUrl,
        [object]$CommonParams
    )

    $candidates = Get-VilageBaseCandidates
    $lastError = "Unknown error"

    foreach ($base in $candidates) {
        $params = @{} + $CommonParams
        $params.base_date = $base.base_date
        $params.base_time = $base.base_time
        try {
            $result = Invoke-KmaApi -BaseUrl $BaseUrl -Params $params
            if ($result.response.header.resultCode -eq "00") {
                return @{
                    response = $result.response
                    base_date = $base.base_date
                    base_time = $base.base_time
                }
            }
            $lastError = $result.response.header.resultMsg
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    throw $lastError
}

function ConvertTo-WeatherMap {
    param(
        [array]$Items,
        [string]$DateKey,
        [string]$TimeKey
    )
    $map = @{}
    foreach ($item in $Items) {
        if ($item.$DateKey -eq $null) { continue }
        $slot = "$($item.$DateKey)-$($item.$TimeKey)"
        if (-not $map.ContainsKey($slot)) {
            $map[$slot] = @{}
        }
        $category = $item.category
        if ($category) {
            $map[$slot][$category] = $item.fcstValue
        }
    }
    return $map
}

function Get-WeatherIcon {
    param([string]$Sky, [string]$Pty)
    if ($Pty -and $Pty -ne "0") {
        switch ($Pty) {
            "3" { return "snow" }
            "2" { return "sleet" }
            default { return "rain" }
        }
    }
    switch ($Sky) {
        "1" { return "sun" }
        "3" { return "cloud" }
        "4" { return "overcast" }
        default { return "cloud" }
    }
}

function Resolve-VilageBase {
    param([object]$ProbeRegion = $Regions[0])

    $candidates = Get-VilageBaseCandidates
    foreach ($base in $candidates) {
        try {
            $result = Invoke-KmaApi -BaseUrl $FcstUrl -Params @{
                nx        = $ProbeRegion.nx
                ny        = $ProbeRegion.ny
                base_date = $base.base_date
                base_time = $base.base_time
            }
            if ($result.response.header.resultCode -eq "00") {
                return $base
            }
        }
        catch { }
    }

    throw "예보 기준 시간을 찾지 못했습니다."
}

function Parse-RegionFcst {
    param(
        [array]$Items,
        [object]$FcstTarget
    )

    if ($null -eq $Items -or $Items.Count -eq 0) {
        return @{}
    }

    $slots = @{}
    foreach ($item in $Items) {
        $slotKey = "$($item.fcstDate)-$($item.fcstTime)"
        if (-not $slots.ContainsKey($slotKey)) {
            $slots[$slotKey] = @{}
        }
        if ($item.category) {
            $slots[$slotKey][$item.category] = $item.fcstValue
        }
    }

    $now = Get-Date
    $preferredKeys = @(
        "$($FcstTarget.fcst_date)-$($FcstTarget.fcst_time)",
        "$($now.ToString('yyyyMMdd'))-$($now.ToString('HH'))00"
    )

    foreach ($key in $preferredKeys) {
        if ($slots.ContainsKey($key) -and $slots[$key].ContainsKey("TMP")) {
            return $slots[$key]
        }
    }

    $nowKey = "$($now.ToString('yyyyMMdd'))-$($now.ToString('HH'))00"
    foreach ($key in ($slots.Keys | Where-Object { $_ -ge $nowKey } | Sort-Object)) {
        if ($slots[$key].ContainsKey("TMP")) {
            return $slots[$key]
        }
    }

    foreach ($key in ($slots.Keys | Sort-Object -Descending)) {
        if ($slots[$key].ContainsKey("TMP")) {
            return $slots[$key]
        }
    }

    return @{}
}

function Build-RegionWeatherResult {
    param(
        $Region,
        [object]$FcstMap,
        [object]$FcstTarget,
        [string]$BaseDate,
        [string]$BaseTime
    )

    if (-not $FcstMap.ContainsKey("TMP")) {
        throw "예보 데이터가 비어 있습니다."
    }

    $sky = $FcstMap["SKY"]
    $pty = $FcstMap["PTY"]

    return @{
        id = $Region.id
        name = $Region.name
        nx = $Region.nx
        ny = $Region.ny
        left = $Region.left
        top = $Region.top
        temp = $FcstMap["TMP"]
        forecastTemp = $FcstMap["TMP"]
        sky = $sky
        pty = $pty
        pop = $FcstMap["POP"]
        humidity = $FcstMap["REH"]
        wind = $FcstMap["WSD"]
        icon = Get-WeatherIcon $sky $pty
        fcstDate = $FcstTarget.fcst_date
        fcstTime = $FcstTarget.fcst_time
        baseDate = $BaseDate
        baseTime = $BaseTime
    }
}

function Fetch-RegionWeatherData {
    param(
        $Region,
        [object]$ResolvedBase,
        [object]$FcstTarget,
        [switch]$UseFallbackBases
    )

    $candidates = if ($UseFallbackBases) {
        Get-VilageBaseCandidates
    }
    else {
        @($ResolvedBase)
    }

    $lastError = "예보 데이터를 찾지 못했습니다."
    foreach ($base in $candidates) {
        try {
            $items = Get-KmaAllItems -BaseUrl $FcstUrl -Params @{
                nx        = $Region.nx
                ny        = $Region.ny
                base_date = $base.base_date
                base_time = $base.base_time
            }
            $fcstMap = Parse-RegionFcst -Items $items -FcstTarget $FcstTarget
            return Build-RegionWeatherResult -Region $Region -FcstMap $fcstMap -FcstTarget $FcstTarget `
                -BaseDate $base.base_date -BaseTime $base.base_time
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    throw $lastError
}

function Get-RegionWeather {
    param(
        $Region,
        [object]$ResolvedBase,
        [object]$FcstTarget
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return Fetch-RegionWeatherData -Region $Region -ResolvedBase $ResolvedBase -FcstTarget $FcstTarget
        }
        catch {
            $sharedError = $_.Exception.Message
            Start-Sleep -Milliseconds (300 * $attempt)
        }
    }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            return Fetch-RegionWeatherData -Region $Region -ResolvedBase $ResolvedBase -FcstTarget $FcstTarget -UseFallbackBases
        }
        catch {
            $fallbackError = $_.Exception.Message
            Start-Sleep -Milliseconds 500
        }
    }

    throw $fallbackError
}

function Get-AllRegionWeather {
    $resolvedBase = Resolve-VilageBase
    $fcstTarget = Get-FcstTargetTime
    $results = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($region in $Regions) {
        try {
            $result = Get-RegionWeather -Region $region -ResolvedBase $resolvedBase -FcstTarget $fcstTarget
            $results.Add($result) | Out-Null
            Write-Host ("  OK  {0} {1}" -f $region.name, $result.temp) -ForegroundColor DarkGray
        }
        catch {
            $errors.Add("$($region.id): $($_.Exception.Message)") | Out-Null
            Write-Host ("  FAIL {0} - {1}" -f $region.name, $_.Exception.Message) -ForegroundColor Yellow
        }
        Start-Sleep -Milliseconds 250
    }

    if ($results.Count -eq 0 -and $errors.Count -gt 0) {
        throw ($errors -join " | ")
    }

    if ($errors.Count -gt 0) {
        Write-Host ""
        Write-Host ("일부 지역 조회 실패: {0}/{1}" -f $errors.Count, $Regions.Count) -ForegroundColor Yellow
    }

    return @{
        updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        baseDate = $resolvedBase.base_date
        baseTime = $resolvedBase.base_time
        regions = @($results)
        errors = @($errors)
    }
}

function Send-TextResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Content,
        [string]$ContentType,
        [int]$StatusCode = 200
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType + "; charset=utf-8"
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Send-FileResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$FilePath
    )
    if (-not (Test-Path $FilePath)) {
        Send-TextResponse -Response $Response -Content "Not Found" -ContentType "text/plain" -StatusCode 404
        return
    }
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $type = switch ($ext) {
        ".html" { "text/html" }
        ".css"  { "text/css" }
        ".js"   { "application/javascript" }
        ".json" { "application/json" }
        ".png"  { "image/png" }
        ".jpg"  { "image/jpeg" }
        ".jpeg" { "image/jpeg" }
        ".gif"  { "image/gif" }
        ".webp" { "image/webp" }
        default { "application/octet-stream" }
    }

    if ($ext -in @(".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico")) {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        $Response.StatusCode = 200
        $Response.ContentType = $type
        $Response.SendChunked = $false
        try {
            $Response.ContentLength64 = [int64]$bytes.Length
        }
        catch {
            $Response.SendChunked = $true
        }
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Response.OutputStream.Close()
        return
    }

    $content = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    Send-TextResponse -Response $Response -Content $content -ContentType $type
}

function Test-ServerAlive {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:${Port}/" -UseBasicParsing -TimeoutSec 3
        return $r.StatusCode -eq 200
    }
    catch { return $false }
}

if (Test-ServerAlive) {
    Write-Host ""
    Write-Host "서버가 이미 실행 중입니다. 코드 변경 반영을 위해 재시작이 필요합니다." -ForegroundColor Yellow
    Write-Host "  1. 실행 중인 서버 창에서 Ctrl+C 로 종료" -ForegroundColor Yellow
    Write-Host "  2. 날씨시작.bat 다시 실행" -ForegroundColor Yellow
    Write-Host "http://localhost:${Port}" -ForegroundColor Green
    Write-Host ""
    Start-Process "http://localhost:${Port}"
    exit 0
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:${Port}/")

try {
    $listener.Start()
}
catch {
    Write-Host ""
    Write-Host "서버 시작 실패: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "해결 방법:" -ForegroundColor Yellow
    Write-Host "  1. PowerShell을 관리자 권한으로 열고 아래 명령 실행 후 다시 시도"
    Write-Host "     netsh http add urlacl url=http://localhost:${Port}/ user=$env:USERNAME"
    Write-Host "  2. 또는 이미 실행 중인 서버가 있다면 브라우저에서 직접 접속"
    Write-Host "     http://localhost:${Port}" -ForegroundColor Green
    Write-Host ""
    if (Test-ServerAlive) {
        Start-Process "http://localhost:${Port}"
    }
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Korea Weather Dashboard" -ForegroundColor Cyan
Write-Host " http://localhost:${Port}" -ForegroundColor Green
Write-Host " HTML 파일을 직접 열지 마세요!" -ForegroundColor Yellow
Write-Host " Press Ctrl+C to stop" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "날씨 데이터 불러오는 중..." -ForegroundColor Yellow
Start-Process "http://localhost:${Port}"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $script:CachedData = Get-AllRegionWeather
    $script:CacheTime = Get-Date
}
catch {
    Write-Host ("날씨 데이터 로드 실패: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    $script:CachedData = @{
        updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        regions = @()
        errors = @($_.Exception.Message)
    }
    $script:CacheTime = Get-Date
}
$sw.Stop()
$elapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
if ($script:CachedData.regions.Count -gt 0) {
    Write-Host "날씨 데이터 준비 완료! ($elapsedSec 초, $($script:CachedData.regions.Count)개 지역)" -ForegroundColor Green
}
Write-Host ""

function Handle-Request {
    param($Context)
    $request = $Context.Request
    $response = $Context.Response
    $path = $request.Url.LocalPath

    try {
        if ($path -eq "/api/weather") {
            $now = Get-Date
            if ($null -eq $script:CachedData -or $null -eq $script:CacheTime -or ($now - $script:CacheTime).TotalMinutes -gt $CacheMinutes) {
                $script:CachedData = Get-AllRegionWeather
                $script:CacheTime = $now
            }
            $json = $script:CachedData | ConvertTo-Json -Depth 6 -Compress
            Send-TextResponse -Response $response -Content $json -ContentType "application/json"
        }
        elseif ($path -eq "/korea-map.png") {
            Send-FileResponse -Response $response -FilePath (Join-Path $Root "korea-map.png")
        }
        elseif ($path -eq "/regions.json") {
            Send-FileResponse -Response $response -FilePath (Join-Path $Root "regions.json")
        }
        elseif ($path -eq "/" -or $path -eq "/index.html") {
            Send-FileResponse -Response $response -FilePath (Join-Path $Root "index.html")
        }
        else {
            Send-TextResponse -Response $response -Content "Not Found" -ContentType "text/plain" -StatusCode 404
        }
    }
    catch {
        $err = @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
        Send-TextResponse -Response $response -Content $err -ContentType "application/json" -StatusCode 500
    }
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        Handle-Request -Context $context
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
