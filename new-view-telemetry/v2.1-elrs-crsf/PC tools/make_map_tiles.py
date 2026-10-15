#!/usr/bin/env python3
"""
make_map_tiles.py - satellite map tiles for the NewView widget (EdgeTX)
Created by NVFPV.

Downloads free Copernicus Sentinel-2 true-colour imagery for the area you fly in
and cuts it into 100x100 px tiles in the GMapCatcher layout that the NewView
widget reads from the radio's SD card.

Example (10 km x 10 km, zoom levels 0, 1 and 2):
    python make_map_tiles.py --lat -33.4193 --lon 149.5775 --size-km 10 --levels 0 1 2

Then copy the IMAGES folder it makes onto the root of the radio's SD card.

Needs Python 3.9+ and:  pip install rasterio pyproj numpy pillow
Imagery: "Contains modified Copernicus Sentinel data", free and open use with credit.
Source: Sentinel-2 L2A Cloud-Optimised GeoTIFFs in the AWS open-data bucket sentinel-cogs.
"""
import argparse, datetime as dt, json, math, os, re, sys, urllib.request

import numpy as np
import rasterio
from PIL import Image, ImageFilter
from pyproj import Transformer
from rasterio.transform import from_origin
from rasterio.warp import Resampling, reproject, transform_bounds
from rasterio.windows import from_bounds

BUCKET = "https://sentinel-cogs.s3.us-west-2.amazonaws.com"
PREFIX = "sentinel-s2-l2a-cogs"
ORIGIN = math.pi * 6378137.0          # half the web-mercator world width, m
SCL_BAD = (0, 1, 3, 8, 9, 10)         # no data, saturated, cloud shadow, cloud (med, high), cirrus

_tr = {}


def mgrs100k(lat, lon):
    """MGRS 100 km square (e.g. 55HGC). Sentinel-2 names its tiles this way."""
    zone = int((lon + 180) // 6) + 1
    if 56 <= lat < 64 and 3 <= lon < 12:
        zone = 32
    if 72 <= lat < 84:
        for lo, hi, z in ((0, 9, 31), (9, 21, 33), (21, 33, 35), (33, 42, 37)):
            if lo <= lon < hi:
                zone = z
    band = "CDEFGHJKLMNPQRSTUVWXX"[int((lat + 80) // 8)]
    epsg = (32600 if lat >= 0 else 32700) + zone
    if epsg not in _tr:
        _tr[epsg] = Transformer.from_crs(4326, epsg, always_xy=True)
    e, n = _tr[epsg].transform(lon, lat)
    col = ["STUVWXYZ", "ABCDEFGH", "JKLMNPQR"][zone % 3][int(e // 100000) - 1]
    row = "ABCDEFGHJKLMNPQRSTUV"[(int(n // 100000) + (5 if zone % 2 == 0 else 0)) % 20]
    return "%d%s%s%s" % (zone, band, col, row)


def http_get(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def list_prefixes(prefix):
    xml = http_get("%s/?list-type=2&delimiter=/&prefix=%s" % (BUCKET, prefix)).decode()
    return re.findall(r"<Prefix>([^<]*)</Prefix>", xml)[1:]


def find_scenes(tiles, months, max_cloud, date=None):
    """Scenes for the MGRS tiles over the last `months`, best (least cloud) first."""
    today = dt.date.today()
    found = []
    for t in sorted(tiles):
        zone, band, sq = t[:-3], t[-3], t[-2:]
        for k in range(months):
            y, m = today.year, today.month - k
            while m < 1:
                y, m = y - 1, m + 12
            for p in list_prefixes("%s/%s/%s/%s/%d/%d/" % (PREFIX, zone, band, sq, y, m)):
                name = p.rstrip("/").split("/")[-1]
                if date and date.replace("-", "") not in name:
                    continue
                try:
                    props = json.loads(http_get("%s/%s%s.json" % (BUCKET, p, name)))["properties"]
                except Exception:
                    continue
                cc = props.get("eo:cloud_cover", 100)
                if cc <= max_cloud:
                    found.append({"name": name, "url": BUCKET + "/" + p, "cloud": cc,
                                  "nodata": props.get("s2:nodata_pixel_percentage", 0),
                                  "date": props.get("datetime", "")[:10]})
    found.sort(key=lambda s: (s["cloud"] + s["nodata"] / 10, s["date"][::-1]))
    return found


def area_bad_fraction(scene, bbox):
    """Share of the area that is cloud, shadow or outside the scene, from the SCL band."""
    with rasterio.open(scene["url"] + "SCL.tif") as src:
        l, b, r, t = transform_bounds(4326, src.crs, bbox[1], bbox[0], bbox[3], bbox[2])
        w = from_bounds(l, b, r, t, src.transform).round_offsets().round_lengths()
        scl = src.read(1, window=w, boundless=True, fill_value=0)
    if scl.size == 0:
        return 1.0
    return float(np.isin(scl, SCL_BAD).mean())


def read_tci(scene, bbox):
    with rasterio.open(scene["url"] + "TCI.tif") as src:
        l, b, r, t = transform_bounds(4326, src.crs, bbox[1], bbox[0], bbox[3], bbox[2])
        w = from_bounds(l, b, r, t, src.transform).round_offsets().round_lengths()
        data = src.read(window=w, boundless=True, fill_value=0)
        return data, src.window_transform(w), src.crs


def tile_xy(lat, lon, z):
    n = 2 ** z
    x = (lon + 180) / 360 * n
    y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return int(x), int(y)


def main():
    ap = argparse.ArgumentParser(description="Satellite map tiles for NewView (by NVFPV)")
    ap.add_argument("--lat", type=float, required=True, help="centre latitude, e.g. -33.4193")
    ap.add_argument("--lon", type=float, required=True, help="centre longitude, e.g. 149.5775")
    ap.add_argument("--size-km", type=float, default=10, help="side of the square area, km (default 10)")
    ap.add_argument("--levels", type=int, nargs="+", default=[0, 1, 2],
                    help="GMapCatcher zoom levels: 0 = most detail (default 0 1 2)")
    ap.add_argument("--out", default="SD", help="output folder (default SD)")
    ap.add_argument("--months", type=int, default=6, help="how far back to look for clear images (default 6)")
    ap.add_argument("--max-cloud", type=float, default=30, help="skip scenes with more cloud than this, %% (default 30)")
    ap.add_argument("--date", help="use only images from this day, YYYY-MM-DD")
    a = ap.parse_args()

    half = a.size_km / 2
    dlat = half / 110.574
    dlon = half / (111.320 * math.cos(math.radians(a.lat)))
    S, N, W, E = a.lat - dlat, a.lat + dlat, a.lon - dlon, a.lon + dlon
    # whole tiles at the widest level, so the area is fully covered at every level
    zmin = 17 - max(a.levels)
    x0, y0 = tile_xy(N, W, zmin)
    x1, y1 = tile_xy(S, E, zmin)
    span = 2 * ORIGIN / 2 ** zmin
    to_ll = Transformer.from_crs(3857, 4326, always_xy=True)
    W2, N2 = to_ll.transform(-ORIGIN + x0 * span, ORIGIN - y0 * span)
    E2, S2 = to_ll.transform(-ORIGIN + (x1 + 1) * span, ORIGIN - (y1 + 1) * span)
    bbox = (S2, W2, N2, E2)
    print("Area %.4f,%.4f to %.4f,%.4f" % (S2, W2, N2, E2))

    tiles = set()
    for i in range(5):
        for j in range(5):
            tiles.add(mgrs100k(S2 + (N2 - S2) * i / 4, W2 + (E2 - W2) * j / 4))
    print("Sentinel-2 tiles:", " ".join(sorted(tiles)))
    scenes = find_scenes(tiles, a.months, a.max_cloud, a.date)
    if not scenes:
        sys.exit("No clear images found. Try --months 12 or --max-cloud 60.")
    print("Checking cloud over your area in the %d best images..." % min(12, len(scenes)))
    ranked = []
    for s in scenes[:12]:
        try:
            s["bad"] = area_bad_fraction(s, bbox)
        except Exception as e:
            print("  skip %s (%s)" % (s["name"], e))
            continue
        print("  %s  %s  cloud/missing over your area: %.1f%%" % (s["date"], s["name"], 100 * s["bad"]))
        ranked.append(s)
    # clearest first; among equally clear images, the newest
    ranked.sort(key=lambda s: (round(s["bad"], 3), -int(s["date"].replace("-", "") or 0)))

    # read the best images until the whole area is covered
    sources, covered = [], None
    for s in ranked:
        if s["bad"] > 0.5:
            break
        data, tr, crs = read_tci(s, bbox)
        sources.append((s, data, tr, crs))
        print("Using %s (%s)" % (s["name"], s["date"]))
        if s["bad"] < 0.01:
            break
    if not sources:
        sys.exit("Every image is mostly cloud over your area. Try --months 12.")

    root = os.path.join(a.out, "IMAGES", "NewView", "sat_tiles")
    total = 0
    for level in sorted(a.levels):
        if level < 0:
            print("Level %d is sharper than the 10 m imagery; skipped." % level)
            continue
        z = 17 - level
        tx0, ty0 = tile_xy(N2 - 1e-9, W2 + 1e-9, z)
        tx1, ty1 = tile_xy(S2 + 1e-9, E2 - 1e-9, z)
        tspan = 2 * ORIGIN / 2 ** z
        nx, ny = tx1 - tx0 + 1, ty1 - ty0 + 1
        canvas = np.zeros((3, ny * 100, nx * 100), np.uint8)
        dtr = from_origin(-ORIGIN + tx0 * tspan, ORIGIN - ty0 * tspan, tspan / 100, tspan / 100)
        rs = Resampling.cubic if level == 0 else Resampling.lanczos
        for s, data, tr, crs in sources:
            layer = np.zeros_like(canvas)
            for b in range(3):
                reproject(data[b], layer[b], src_transform=tr, src_crs=crs, src_nodata=0,
                          dst_transform=dtr, dst_crs="EPSG:3857", dst_nodata=0, resampling=rs)
            empty = canvas.max(axis=0) == 0
            canvas[:, empty] = layer[:, empty]
        img = Image.fromarray(np.moveaxis(canvas, 0, 2))
        if level == 0:
            img = img.filter(ImageFilter.UnsharpMask(radius=1.2, percent=60, threshold=2))
        for j in range(ny):
            for i in range(nx):
                X, Y = tx0 + i, ty0 + j
                d = os.path.join(root, str(level), str(X // 1024), str(X % 1024), str(Y // 1024))
                os.makedirs(d, exist_ok=True)
                img.crop((i * 100, j * 100, i * 100 + 100, j * 100 + 100)).save(
                    os.path.join(d, "s_%d.png" % (Y % 1024)), optimize=True)
        img.convert("RGB").save(os.path.join(a.out, "preview_level%d.jpg" % level), quality=85)
        m_px = tspan / 100 * math.cos(math.radians(a.lat))
        print("Level %d: %d tiles, %.1f m per pixel, scale bar %d m" % (level, nx * ny, m_px, 50 * 2 ** (level + 2)))
        total += nx * ny
    print("Done: %d tiles in %s" % (total, root))
    print("Copy the IMAGES folder inside '%s' onto the root of the radio's SD card." % a.out)


if __name__ == "__main__":
    main()
