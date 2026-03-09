#!/usr/bin/env python3
import argparse
import json
import urllib.parse
import urllib.request


DEFAULT_PRICE_SCALE = 1_000_000_000


def fetch_json_url(url, timeout=20):
    request = urllib.request.Request(url, headers={"User-Agent": "self-driving-yield/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def extract_json_path(payload, path):
    current = payload
    for raw_part in path.split("."):
        part = raw_part.strip()
        if not part:
            continue
        if isinstance(current, list):
            current = current[int(part)]
            continue
        if not isinstance(current, dict):
            raise KeyError(f"Cannot descend into non-object at {part}")
        current = current[part]
    return current


def normalize_price(price_value, scale):
    return int(round(float(price_value) * scale))


def fetch_http_json_price(url, path, scale, timeout):
    payload = fetch_json_url(url, timeout=timeout)
    if not path:
        raise ValueError("http-json source requires --http-json-path")
    raw_price = extract_json_path(payload, path)
    return {
        "source": "http-json",
        "raw_price": float(raw_price),
        "spot_price": normalize_price(raw_price, scale),
        "scale": scale,
        "url": url,
        "path": path,
    }


def fetch_coingecko_price(coin_id, vs_currency, scale, timeout):
    query = urllib.parse.urlencode({"ids": coin_id, "vs_currencies": vs_currency})
    url = f"https://api.coingecko.com/api/v3/simple/price?{query}"
    payload = fetch_json_url(url, timeout=timeout)
    raw_price = payload[coin_id][vs_currency]
    return {
        "source": "coingecko",
        "raw_price": float(raw_price),
        "spot_price": normalize_price(raw_price, scale),
        "scale": scale,
        "url": url,
        "coin_id": coin_id,
        "vs_currency": vs_currency,
    }


def fetch_binance_price(symbol, scale, timeout):
    query = urllib.parse.urlencode({"symbol": symbol.upper()})
    url = f"https://api.binance.com/api/v3/ticker/price?{query}"
    payload = fetch_json_url(url, timeout=timeout)
    raw_price = payload["price"]
    return {
        "source": "binance",
        "raw_price": float(raw_price),
        "spot_price": normalize_price(raw_price, scale),
        "scale": scale,
        "url": url,
        "symbol": symbol.upper(),
    }


def fetch_price(args):
    if args.source == "coingecko":
        return fetch_coingecko_price(args.coingecko_id, args.vs_currency, args.price_scale, args.timeout_seconds)
    if args.source == "binance":
        return fetch_binance_price(args.binance_symbol, args.price_scale, args.timeout_seconds)
    if args.source == "http-json":
        return fetch_http_json_price(args.http_json_url, args.http_json_path, args.price_scale, args.timeout_seconds)
    raise ValueError(f"Unsupported source: {args.source}")


def main():
    parser = argparse.ArgumentParser(description="Fetch a spot price from a public HTTP JSON source and normalize it to the keeper spot_price integer format")
    parser.add_argument("--source", choices=("coingecko", "binance", "http-json"), required=True)
    parser.add_argument("--coingecko-id", default="sui")
    parser.add_argument("--vs-currency", default="usd")
    parser.add_argument("--binance-symbol", default="SUIUSDT")
    parser.add_argument("--http-json-url", default="")
    parser.add_argument("--http-json-path", default="")
    parser.add_argument("--price-scale", type=int, default=DEFAULT_PRICE_SCALE)
    parser.add_argument("--timeout-seconds", type=int, default=20)
    parser.add_argument("--json", action="store_true", help="Print the full payload instead of only the normalized spot_price")
    args = parser.parse_args()

    payload = fetch_price(args)
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        print(payload["spot_price"])


if __name__ == "__main__":
    main()
