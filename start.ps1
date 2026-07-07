# Weather & Stock combined dashboard local server
# Usage: .\start.ps1

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Port = 8080
$ApiKey = "77fc6bf77fb3921f2558527cb6a39f719028aaeca64b5c42e79f76ffbf6a8146"
$FcstUrl = "http://apis.data.go.kr/1360000/VilageFcstInfoService_2.0/getVilageFcst"
$StockUrl = "https://apis.data.go.kr/1160100/service/GetStockSecuritiesInfoService/getStockPriceInfo"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$script:WeatherCache = $null
$script:WeatherCacheTime = $null
$WeatherCacheMinutes = 10

$script:StockCache = $null
$script:StockCacheTime = $null
$StockCacheMinutes = 30

$Regions = Get-Content (Join-Path $Root "regions.json") -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-ApiItems {
    param([object]$Body)
    if ($null -eq $Body -or $null -eq $Body.items) { return @() }
    $items = $Body.items.item
    if ($null -eq $items) { return @() }
    if ($items -isnot [System.Array]) { return @($items) }
    return $items
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
        ".svg"  { "image/svg+xml" }
        ".png"  { "image/png" }
        default { "application/octet-stream" }
    }
    if ($ext -in @(".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico")) {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        $Response.StatusCode = 200
        $Response.ContentType = $type
        $Response.ContentLength64 = $bytes.Length
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Response.OutputStream.Close()
        return
    }
    $content = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    Send-TextResponse -Response $Response -Content $content -ContentType $type
}

# --- Stock API ---
function Get-Top50Stocks {
    $probe = Invoke-RestMethod -Uri "${StockUrl}?serviceKey=${ApiKey}&numOfRows=1&pageNo=1&resultType=json" -TimeoutSec 60
    if ($probe.response.header.resultCode -ne "00") {
        throw $probe.response.header.resultMsg
    }
    $basDt = (Get-ApiItems $probe.response.body)[0].basDt
    $all = @()
    $page = 1
    $total = 0
    do {
        $url = "${StockUrl}?serviceKey=${ApiKey}&numOfRows=1000&pageNo=${page}&resultType=json&basDt=${basDt}"
        $res = Invoke-RestMethod -Uri $url -TimeoutSec 120
        if ($res.response.header.resultCode -ne "00") { throw $res.response.header.resultMsg }
        $total = [int]$res.response.body.totalCount
        $all += Get-ApiItems $res.response.body
        $page++
    } while ($all.Count -lt $total)
    $top50 = $all | Sort-Object { [decimal]$_.clpr } -Descending | Select-Object -First 50
    return @{
        basDt = $basDt
        totalCount = $all.Count
        updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        stocks = @($top50 | ForEach-Object {
            @{
                basDt = $_.basDt; srtnCd = $_.srtnCd; itmsNm = $_.itmsNm
                mrktCtg = $_.mrktCtg; clpr = $_.clpr; vs = $_.vs; fltRt = $_.fltRt
                mkp = $_.mkp; hipr = $_.hipr; lopr = $_.lopr
                trqu = $_.trqu; trPrc = $_.trPrc; mrktTotAmt = $_.mrktTotAmt
            }
        })
    }
}

# --- Weather API (condensed from weather/start.ps1) ---
function Get-VilageBaseCandidates {
    $now = Get-Date
    $list = New-Object System.Collections.Generic.List[hashtable]
    foreach ($t in @(2300, 2000, 1700, 1400, 1100, 800, 500, 200)) {
        $hour = [math]::Floor($t / 100)
        $minute = $t % 100
        $candidate = Get-Date -Year $now.Year -Month $now.Month -Day $now.Day -Hour $hour -Minute $minute -Second 0
        if ($now -ge $candidate.AddMinutes(10)) {
            $list.Add(@{ base_date = $candidate.ToString("yyyyMMdd"); base_time = "{0:D4}" -f $t }) | Out-Null
        }
    }
    if ($list.Count -eq 0) {
        $prev = $now.AddDays(-1)
        $list.Add(@{ base_date = $prev.ToString("yyyyMMdd"); base_time = "2300" }) | Out-Null
    }
    return @($list)
}

function Invoke-KmaApi {
    param([string]$BaseUrl, [object]$Params, [int]$PageNo = 1, [int]$NumOfRows = 1000)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $query = @("serviceKey=$ApiKey", "numOfRows=$NumOfRows", "pageNo=$PageNo", "dataType=JSON")
    foreach ($key in ($Params.Keys | Sort-Object)) { $query += "$key=$($Params[$key])" }
    Invoke-RestMethod -Uri "${BaseUrl}?$($query -join '&')" -TimeoutSec 30
}

function Get-KmaAllItems {
    param([string]$BaseUrl, [object]$Params)
    $allItems = New-Object System.Collections.Generic.List[object]
    $page = 1; $total = 0
    do {
        $result = Invoke-KmaApi -BaseUrl $BaseUrl -Params $Params -PageNo $page
        if ($result.response.header.resultCode -ne "00") { throw $result.response.header.resultMsg }
        $body = $result.response.body
        if ($null -ne $body.totalCount) { $total = [int]$body.totalCount }
        foreach ($item in (Get-ApiItems $body)) { $allItems.Add($item) | Out-Null }
        $page++
    } while ($total -gt 0 -and $allItems.Count -lt $total -and $page -le 5)
    return @($allItems.ToArray())
}

function Get-WeatherIcon { param([string]$Sky, [string]$Pty)
    if ($Pty -and $Pty -ne "0") {
        switch ($Pty) { "3" { return "snow" } "2" { return "sleet" } default { return "rain" } }
    }
    switch ($Sky) { "1" { return "sun" } "3" { return "cloud" } "4" { return "overcast" } default { return "cloud" } }
}

function Resolve-VilageBase {
    foreach ($base in (Get-VilageBaseCandidates)) {
        try {
            $result = Invoke-KmaApi -BaseUrl $FcstUrl -Params @{
                nx = $Regions[0].nx; ny = $Regions[0].ny
                base_date = $base.base_date; base_time = $base.base_time
            }
            if ($result.response.header.resultCode -eq "00") { return $base }
        } catch { }
    }
    throw "예보 기준 시간을 찾지 못했습니다."
}

function Parse-RegionFcst {
    param([array]$Items, [object]$FcstTarget)
    $slots = @{}
    foreach ($item in $Items) {
        $slotKey = "$($item.fcstDate)-$($item.fcstTime)"
        if (-not $slots.ContainsKey($slotKey)) { $slots[$slotKey] = @{} }
        if ($item.category) { $slots[$slotKey][$item.category] = $item.fcstValue }
    }
    $now = Get-Date
    $preferredKeys = @(
        "$($FcstTarget.fcst_date)-$($FcstTarget.fcst_time)",
        "$($now.ToString('yyyyMMdd'))-$($now.ToString('HH'))00"
    )
    foreach ($key in $preferredKeys) {
        if ($slots.ContainsKey($key) -and $slots[$key].ContainsKey("TMP")) { return $slots[$key] }
    }
    $nowKey = "$($now.ToString('yyyyMMdd'))-$($now.ToString('HH'))00"
    foreach ($key in ($slots.Keys | Where-Object { $_ -ge $nowKey } | Sort-Object)) {
        if ($slots[$key].ContainsKey("TMP")) { return $slots[$key] }
    }
    foreach ($key in ($slots.Keys | Sort-Object -Descending)) {
        if ($slots[$key].ContainsKey("TMP")) { return $slots[$key] }
    }
    return @{}
}

function Get-RegionWeather {
    param($Region, [object]$ResolvedBase, [object]$FcstTarget)
    $items = Get-KmaAllItems -BaseUrl $FcstUrl -Params @{
        nx = $Region.nx; ny = $Region.ny
        base_date = $ResolvedBase.base_date; base_time = $ResolvedBase.base_time
    }
    $fcstMap = Parse-RegionFcst -Items $items -FcstTarget $FcstTarget
    if (-not $fcstMap.ContainsKey("TMP")) { throw "예보 데이터가 비어 있습니다." }
    $sky = $fcstMap["SKY"]; $pty = $fcstMap["PTY"]
    return @{
        id = $Region.id; name = $Region.name; nx = $Region.nx; ny = $Region.ny
        left = $Region.left; top = $Region.top
        temp = $fcstMap["TMP"]; forecastTemp = $fcstMap["TMP"]
        sky = $sky; pty = $pty; pop = $fcstMap["POP"]
        humidity = $fcstMap["REH"]; wind = $fcstMap["WSD"]
        icon = (Get-WeatherIcon $sky $pty)
        fcstDate = $FcstTarget.fcst_date; fcstTime = $FcstTarget.fcst_time
        baseDate = $ResolvedBase.base_date; baseTime = $ResolvedBase.base_time
    }
}

function Get-AllRegionWeather {
    $resolvedBase = Resolve-VilageBase
    $fcstTarget = @{ fcst_date = (Get-Date).ToString("yyyyMMdd"); fcst_time = (Get-Date).AddHours(1).ToString("HH") + "00" }
    $results = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($region in $Regions) {
        try {
            $result = Get-RegionWeather -Region $region -ResolvedBase $resolvedBase -FcstTarget $fcstTarget
            $results.Add($result) | Out-Null
            Write-Host ("  OK  {0} {1}°C" -f $region.name, $result.temp) -ForegroundColor DarkGray
        } catch {
            $errors.Add("$($region.id): $($_.Exception.Message)") | Out-Null
            Write-Host ("  FAIL {0}" -f $region.name) -ForegroundColor Yellow
        }
        Start-Sleep -Milliseconds 250
    }
    if ($results.Count -eq 0 -and $errors.Count -gt 0) { throw ($errors -join " | ") }
    return @{
        updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        baseDate = $resolvedBase.base_date; baseTime = $resolvedBase.base_time
        regions = @($results); errors = @($errors)
    }
}

# --- Server ---
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Weather & Stock Dashboard" -ForegroundColor Cyan
Write-Host " http://localhost:$Port" -ForegroundColor Green
Write-Host " Press Ctrl+C to stop" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Start-Process "http://localhost:$Port"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $path = $request.Url.LocalPath

        try {
            if ($path -eq "/api/weather") {
                $now = Get-Date
                if ($null -eq $script:WeatherCache -or $null -eq $script:WeatherCacheTime -or ($now - $script:WeatherCacheTime).TotalMinutes -gt $WeatherCacheMinutes) {
                    Write-Host "날씨 데이터 갱신 중..." -ForegroundColor Yellow
                    $script:WeatherCache = Get-AllRegionWeather
                    $script:WeatherCacheTime = $now
                }
                $json = $script:WeatherCache | ConvertTo-Json -Depth 6 -Compress
                Send-TextResponse -Response $response -Content $json -ContentType "application/json"
            }
            elseif ($path -eq "/api/top50") {
                $now = Get-Date
                if ($null -eq $script:StockCache -or $null -eq $script:StockCacheTime -or ($now - $script:StockCacheTime).TotalMinutes -gt $StockCacheMinutes) {
                    Write-Host "주식 데이터 갱신 중..." -ForegroundColor Yellow
                    $script:StockCache = Get-Top50Stocks
                    $script:StockCacheTime = $now
                }
                $json = $script:StockCache | ConvertTo-Json -Depth 5 -Compress
                Send-TextResponse -Response $response -Content $json -ContentType "application/json"
            }
            elseif ($path -eq "/regions.json") {
                Send-FileResponse -Response $response -FilePath (Join-Path $Root "regions.json")
            }
            elseif ($path -eq "/" -or $path -eq "/index.html") {
                Send-FileResponse -Response $response -FilePath (Join-Path $Root "index.html")
            }
            elseif ($path.StartsWith("/data/") -or $path.StartsWith("/assets/")) {
                $filePath = Join-Path $Root ($path.TrimStart("/") -replace "/", [IO.Path]::DirectorySeparatorChar)
                Send-FileResponse -Response $response -FilePath $filePath
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
}
finally {
    $listener.Stop()
    $listener.Close()
}
