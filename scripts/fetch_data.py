#!/usr/bin/env python3
"""Fetch weather and stock data for GitHub Pages static deployment."""

import json
import os
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

API_KEY = os.environ.get("DATA_GO_KR_API_KEY", "")
ROOT = Path(__file__).resolve().parent.parent
REGIONS_FILE = ROOT / "regions.json"
WEATHER_OUT = ROOT / "data" / "weather.json"
STOCKS_OUT = ROOT / "data" / "stocks.json"

FCST_URL = "http://apis.data.go.kr/1360000/VilageFcstInfoService_2.0/getVilageFcst"
STOCK_URL = "https://apis.data.go.kr/1160100/service/GetStockSecuritiesInfoService/getStockPriceInfo"

SKY_ICONS = {"1": "sun", "3": "cloud", "4": "overcast"}


def api_get(url, params):
    query = urllib.parse.urlencode({**params, "serviceKey": API_KEY})
    full = f"{url}?{query}"
    req = urllib.request.Request(full, headers={"User-Agent": "dashboard-fetch/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def get_items(body):
    items = body.get("items", {}).get("item")
    if items is None:
        return []
    return items if isinstance(items, list) else [items]


def vilage_base_candidates():
    now = datetime.now()
    times = [2300, 2000, 1700, 1400, 1100, 800, 500, 200]
    candidates = []
    for t in times:
        hour, minute = divmod(t, 100)
        candidate = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if now >= candidate + timedelta(minutes=10):
            candidates.append({
                "base_date": candidate.strftime("%Y%m%d"),
                "base_time": f"{t:04d}",
            })
    if not candidates:
        prev = now - timedelta(days=1)
        candidates.append({"base_date": prev.strftime("%Y%m%d"), "base_time": "2300"})
    return candidates


def resolve_vilage_base(region):
    for base in vilage_base_candidates():
        try:
            res = api_get(FCST_URL, {
                "numOfRows": 10, "pageNo": 1, "dataType": "JSON",
                "nx": region["nx"], "ny": region["ny"],
                "base_date": base["base_date"], "base_time": base["base_time"],
            })
            if res["response"]["header"]["resultCode"] == "00":
                return base
        except Exception:
            pass
    raise RuntimeError("예보 기준 시간을 찾지 못했습니다.")


def fcst_target():
    now = datetime.now()
    nxt = now + timedelta(hours=1)
    return {"fcst_date": now.strftime("%Y%m%d"), "fcst_time": nxt.strftime("%H") + "00"}


def weather_icon(sky, pty):
    if pty and pty != "0":
        return {"3": "snow", "2": "sleet"}.get(pty, "rain")
    return SKY_ICONS.get(sky, "cloud")


def parse_fcst(items, target):
    slots = {}
    for item in items:
        key = f"{item['fcstDate']}-{item['fcstTime']}"
        slots.setdefault(key, {})[item["category"]] = item["fcstValue"]

    now = datetime.now()
    preferred = [
        f"{target['fcst_date']}-{target['fcst_time']}",
        f"{now.strftime('%Y%m%d')}-{now.strftime('%H')}00",
    ]
    for key in preferred:
        if key in slots and "TMP" in slots[key]:
            return slots[key]
    now_key = f"{now.strftime('%Y%m%d')}-{now.strftime('%H')}00"
    for key in sorted(k for k in slots if k >= now_key):
        if "TMP" in slots[key]:
            return slots[key]
    for key in sorted(slots.keys(), reverse=True):
        if "TMP" in slots[key]:
            return slots[key]
    return {}


def fetch_region(region, base, target):
    res = api_get(FCST_URL, {
        "numOfRows": 1000, "pageNo": 1, "dataType": "JSON",
        "nx": region["nx"], "ny": region["ny"],
        "base_date": base["base_date"], "base_time": base["base_time"],
    })
    if res["response"]["header"]["resultCode"] != "00":
        raise RuntimeError(res["response"]["header"]["resultMsg"])
    items = get_items(res["response"]["body"])
    fcst = parse_fcst(items, target)
    if "TMP" not in fcst:
        raise RuntimeError("예보 데이터가 비어 있습니다.")
    sky, pty = fcst.get("SKY"), fcst.get("PTY")
    return {
        "id": region["id"], "name": region["name"],
        "nx": region["nx"], "ny": region["ny"],
        "left": region["left"], "top": region["top"],
        "temp": fcst["TMP"], "forecastTemp": fcst["TMP"],
        "sky": sky, "pty": pty, "pop": fcst.get("POP"),
        "humidity": fcst.get("REH"), "wind": fcst.get("WSD"),
        "icon": weather_icon(sky, pty),
        "fcstDate": target["fcst_date"], "fcstTime": target["fcst_time"],
        "baseDate": base["base_date"], "baseTime": base["base_time"],
    }


def fetch_weather():
    regions = json.loads(REGIONS_FILE.read_text(encoding="utf-8"))
    base = resolve_vilage_base(regions[0])
    target = fcst_target()
    results, errors = [], []
    for region in regions:
        try:
            results.append(fetch_region(region, base, target))
            print(f"  OK  {region['name']}")
        except Exception as e:
            errors.append(f"{region['id']}: {e}")
            print(f"  FAIL {region['name']}: {e}")
        time.sleep(0.25)
    if not results and errors:
        raise RuntimeError(" | ".join(errors))
    return {
        "updatedAt": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "baseDate": base["base_date"], "baseTime": base["base_time"],
        "regions": results, "errors": errors,
    }


def fetch_stocks():
    probe = api_get(STOCK_URL, {"numOfRows": 1, "pageNo": 1, "resultType": "json"})
    if probe["response"]["header"]["resultCode"] != "00":
        raise RuntimeError(probe["response"]["header"]["resultMsg"])
    bas_dt = get_items(probe["response"]["body"])[0]["basDt"]
    all_items, page, total = [], 1, 0
    while True:
        res = api_get(STOCK_URL, {
            "numOfRows": 1000, "pageNo": page, "resultType": "json", "basDt": bas_dt,
        })
        if res["response"]["header"]["resultCode"] != "00":
            raise RuntimeError(res["response"]["header"]["resultMsg"])
        total = int(res["response"]["body"]["totalCount"])
        all_items.extend(get_items(res["response"]["body"]))
        if len(all_items) >= total:
            break
        page += 1
    top50 = sorted(all_items, key=lambda x: float(x["clpr"]), reverse=True)[:50]
    fields = ["basDt", "srtnCd", "itmsNm", "mrktCtg", "clpr", "vs", "fltRt",
              "mkp", "hipr", "lopr", "trqu", "trPrc", "mrktTotAmt"]
    return {
        "basDt": bas_dt, "totalCount": len(all_items),
        "updatedAt": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "stocks": [{f: s[f] for f in fields} for s in top50],
    }


def main():
    if not API_KEY:
        print("ERROR: DATA_GO_KR_API_KEY 환경변수가 필요합니다.", file=sys.stderr)
        sys.exit(1)
    WEATHER_OUT.parent.mkdir(parents=True, exist_ok=True)
    print("Fetching weather...")
    weather = fetch_weather()
    WEATHER_OUT.write_text(json.dumps(weather, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Weather: {len(weather['regions'])} regions -> {WEATHER_OUT}")
    print("Fetching stocks...")
    stocks = fetch_stocks()
    STOCKS_OUT.write_text(json.dumps(stocks, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Stocks: {len(stocks['stocks'])} items -> {STOCKS_OUT}")


if __name__ == "__main__":
    main()
