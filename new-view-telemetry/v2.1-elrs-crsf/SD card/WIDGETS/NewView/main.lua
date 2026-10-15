-- New View Telemetry: offline satellite map plus flight telemetry for EdgeTX colour radios
-- Created by NVFPV
-- Version 2.1 ELRS & CRSF edition (tester build, October 2026)
-- Works with flight controllers that send GPS over ExpressLRS / Crossfire (CRSF) telemetry, such as Betaflight.
-- Telemetry: ExpressLRS / Crossfire (CRSF sensors). Needs EdgeTX 2.11 or later.
-- Tiles: GMapCatcher layout, 100x100 px, in /IMAGES/NewView/sat_tiles
-- The layout is computed from the zone size, so the same file runs on any colour screen.

local TILE_ROOT = "/IMAGES/NewView/sat_tiles"
local TRAIL_MAX = 60
local TRAIL_STEP_M = 15
local CACHE_MAX = 36          -- kept between frames; the tiles on screen are never dropped, even if there are more
local ZOOM_REPEAT = 100       -- 10 ms ticks between zoom steps while the switch is held
local ZOOM_FIRST = 150        -- delay before a held switch starts repeating

local options = {
  { "Zoom", SOURCE, 0 },       -- 3-position switch or channel: up = zoom in, down = zoom out
  { "MinZoom", VALUE, 0, -2, 17 },
  { "MaxZoom", VALUE, 2, -2, 17 },
  { "UseYaw", BOOL, 1 },       -- cursor follows the nose (Yaw) instead of the GPS track
  { "HomeRst", SOURCE, 0 },    -- switch or channel above 50% resets home
  -- map cursor: 1 arrow, 2 drone, 3 plane (EdgeTX numbers CHOICE values from 1; a plain number on radios without CHOICE)
  CHOICE ~= nil and { "Cursor", CHOICE, 1, { "Arrow", "Drone", "Plane" } } or { "Cursor", VALUE, 1, 1, 3 },
  -- warning limits: the value turns red past the limit and amber just before it; 0 turns a limit off
  { "AltMax", VALUE, 120, 0, 5000 },   -- maximum height above home, m
  { "DistMax", VALUE, 0, 0, 50000 },   -- maximum distance from home, m
  { "CellMin", VALUE, 350, 0, 450 },   -- minimum cell voltage in hundredths of a volt: 350 = 3.50 V
  { "Cells", VALUE, 0, 0, 14 },        -- battery cell count, 0 = work it out from the first voltage seen
  { "BatMin", VALUE, 20, 0, 100 },     -- minimum battery %
  { "LQMin", VALUE, 50, 0, 100 },      -- minimum link quality %
  { "SatMin", VALUE, 6, 0, 30 },       -- minimum GPS satellites
  { "Alerts", BOOL, 1 },               -- beep and vibrate every 5 s while armed and past a limit
}

-- readable names in Widget settings (EdgeTX 2.11+ calls this; older versions show the short names)
local LABELS = {
  UseYaw = "Cursor follows nose", HomeRst = "Home reset", MinZoom = "Min zoom", MaxZoom = "Max zoom",
  AltMax = "Max altitude (m)", DistMax = "Max distance (m)", CellMin = "Min cell (V x100)",
  Cells = "Cells (0 = auto)", BatMin = "Min battery %", LQMin = "Min link quality %",
  SatMin = "Min satellites", Alerts = "Beep on warnings",
}
local function translate(name) return LABELS[name] or name end


-- EdgeTX's Lua 5.3 API wants integer coordinates, so every draw call goes through these
local floor = math.floor
local function I(v) return floor(v + 0.5) end
local function fillRect(x, y, w, h, f) lcd.drawFilledRectangle(I(x), I(y), I(w), I(h), f) end
local function rect(x, y, w, h, f) lcd.drawRectangle(I(x), I(y), I(w), I(h), f) end
local function text(x, y, s, f) lcd.drawText(I(x), I(y), s, f) end
local function line(x1, y1, x2, y2, f) lcd.drawLine(I(x1), I(y1), I(x2), I(y2), SOLID, f) end
local function tri(x1, y1, x2, y2, x3, y3, f) lcd.drawFilledTriangle(I(x1), I(y1), I(x2), I(y2), I(x3), I(y3), f) end

local C = {}
local function initColors()
  C.bg = lcd.RGB(16, 16, 20)
  C.panel = lcd.RGB(28, 30, 36)
  C.text = lcd.RGB(235, 235, 235)
  C.dim = lcd.RGB(150, 150, 160)
  C.warn = lcd.RGB(255, 200, 0)
  C.crit = lcd.RGB(255, 70, 40)
  C.ok = lcd.RGB(80, 220, 100)
  C.sky = lcd.RGB(60, 130, 210)
  C.ground = lcd.RGB(120, 80, 40)
  C.plane = lcd.RGB(255, 255, 255)
  C.home = lcd.RGB(255, 170, 0)
  C.trail = lcd.RGB(255, 230, 60)
  C.nomap = lcd.RGB(45, 48, 55)
end

-- shared state (one aircraft, so all widget instances share it)
local tele = { lat = nil, lon = nil, hdg = 0 }
local home = { lat = nil, lon = nil }
local trail = {}               -- { lat, lon, x, y }: x, y projected at level 17 (one world tile)
local project
local cache, cacheCount = {}, 0
local wasArmed = false
local lastFix = nil

-- telemetry ----------------------------------------------------------------

local function val(name)
  local v = getValue(name)
  if type(v) ~= "number" then return 0 end
  return v
end

local function fmText()
  local v = getValue("FM")
  if type(v) == "string" then return v end
  return nil
end

-- Flight-mode text -> armed, mode name to show, status line (nil = ARMED / DISARMED).
-- While disarmed the flight controller sends either "OK", "WAIT" or "!ERR", or the mode name with a suffix:
-- "*" ready to arm, "!" arming blocked, "?" GPS rescue not ready.
-- "!FS!" is sent in failsafe, armed or not, so it keeps the last armed state and home stays put.
local function fmState(fm)
  if fm == nil or fm == "" then return false, nil, nil end
  if fm == "!FS!" then return wasArmed, "FAILSAFE", nil end
  if fm == "OK" or fm == "WAIT" or fm == "!ERR" then return false, fm, nil end
  local last = string.sub(fm, -1)
  if last == "*" then return false, string.sub(fm, 1, -2), nil end
  if last == "!" then return false, string.sub(fm, 1, -2), "ARM BLOCKED" end
  if last == "?" then return false, string.sub(fm, 1, -2), "NO GPS RESCUE" end
  return true, fm, nil
end

local function isArmed(fm)
  local armed = fmState(fm)
  return armed
end

-- height above home: baro "Alt" when the craft sends it, else GPS "GAlt" minus its value at home
local function altitude()
  if getFieldInfo("Alt") ~= nil then return val("Alt") end
  if getFieldInfo("GAlt") ~= nil then return val("GAlt") - (home.galt or val("GAlt")) end
  return 0
end

local function distBearing(lat1, lon1, lat2, lon2)
  local r = math.rad
  local dLat = r(lat2 - lat1)
  local dLon = r(lon2 - lon1)
  local x = dLon * math.cos(r((lat1 + lat2) / 2))
  local d = math.sqrt(x * x + dLat * dLat) * 6371000
  local b = math.deg(math.atan(x, dLat)) % 360
  return d, b
end

local function updateTelemetry(widget)
  local gps = getValue("GPS")
  if type(gps) == "table" and gps.lat ~= nil and gps.lon ~= nil and (gps.lat ~= 0 or gps.lon ~= 0) then
    if tele.lat ~= nil then
      local d, b = distBearing(tele.lat, tele.lon, gps.lat, gps.lon)
      if d > 2 then tele.track = b end
    end
    tele.lat, tele.lon = gps.lat, gps.lon
    lastFix = getTime()
  end

  -- heading: nose (Yaw, radians) if wanted and present, else CRSF Hdg, else GPS track
  local yawInfo = widget.options.UseYaw == 1 and getFieldInfo("Yaw") or nil
  if yawInfo ~= nil then
    tele.hdg = math.deg(val("Yaw")) % 360
  elseif getFieldInfo("Hdg") ~= nil then
    tele.hdg = val("Hdg") % 360
  elseif tele.track ~= nil then
    tele.hdg = tele.track
  end

  -- home: set on arming, or on the first fix while disarmed; reset by switch
  local armed = isArmed(fmText())
  if tele.lat ~= nil then
    local rst = widget.options.HomeRst
    local rstOn = rst ~= nil and rst ~= 0 and getValue(rst) > 512
    local justArmed = armed and not wasArmed
    if justArmed or home.lat == nil or rstOn then
      home.lat, home.lon = tele.lat, tele.lon
      home.galt = getFieldInfo("GAlt") ~= nil and val("GAlt") or nil
      if justArmed then trail = {} end
    end
    local n = #trail
    if n == 0 or distBearing(trail[n][1], trail[n][2], tele.lat, tele.lon) > TRAIL_STEP_M then
      local x, y = project(tele.lat, tele.lon, 17)
      trail[n + 1] = { tele.lat, tele.lon, x, y }
      if #trail > TRAIL_MAX then table.remove(trail, 1) end
    end
  end
  wasArmed = armed
end

-- map ----------------------------------------------------------------------

-- GMapCatcher level L = web zoom 17 - L; returns global tile coordinates (fractional)
project = function(lat, lon, level)
  local wt = 2 ^ (17 - level)
  local x = wt * (lon + 180) / 360
  local s = math.sin(math.rad(lat))
  local y = wt / 2 - 0.5 * math.log((1 + s) / (1 - s)) * wt / (2 * math.pi)
  return x, y
end

local function tilePath(tx, ty, level)
  return string.format("%s/%d/%d/%d/%d/s_%d.png", TILE_ROOT, level, tx // 1024, tx % 1024, ty // 1024, ty % 1024)
end

local frame = 0
local loads = 0               -- tiles opened in this frame
local LOADS_MAX = 6           -- spread big redraws (zoom change, bigger screens) over several frames

-- Keeps the tiles drawn in recent frames. Trimming waits for the end of the frame (trimCache), so a
-- tile still to be drawn this frame is never dropped; an 800x480 map shows up to 42 tiles.
local function getTile(path)
  local e = cache[path]
  if e ~= nil then e.f = frame; return e.b end
  if loads >= LOADS_MAX then return nil end
  loads = loads + 1
  local b = Bitmap.open(path)
  local w = b and Bitmap.getSize(b) or 0
  if w == 0 then b = false end
  cache[path] = { b = b, f = frame }
  cacheCount = cacheCount + 1
  return b
end

-- After the map is drawn: if over CACHE_MAX, drop the tiles that weren't on screen this frame.
local function trimCache()
  if cacheCount <= CACHE_MAX then return end
  for k, v in pairs(cache) do
    if v.f ~= frame then cache[k] = nil; cacheCount = cacheCount - 1 end
  end
  collectgarbage()
end

local function rotPt(cx, cy, ang, dx, dy)
  local c, s = math.cos(ang), math.sin(ang)
  return math.floor(cx + dx * c - dy * s + 0.5), math.floor(cy + dx * s + dy * c + 0.5)
end

local function drawArrow(cx, cy, hdg, size, color)
  local a = math.rad(hdg)
  local x1, y1 = rotPt(cx, cy, a, 0, -size)
  local x2, y2 = rotPt(cx, cy, a, size * 0.7, size * 0.8)
  local x3, y3 = rotPt(cx, cy, a, 0, size * 0.35)
  local x4, y4 = rotPt(cx, cy, a, -size * 0.7, size * 0.8)
  tri(x1, y1, x2, y2, x3, y3, color)
  tri(x1, y1, x3, y3, x4, y4, color)
  line(x1, y1, x2, y2, BLACK)
  line(x2, y2, x3, y3, BLACK)
  line(x3, y3, x4, y4, BLACK)
  line(x4, y4, x1, y1, BLACK)
end

-- fills a shape made of convex parts, then outlines its silhouette in black
local function drawShape(cx, cy, a, s, parts, outline, color)
  for _, p in ipairs(parts) do
    local x0, y0 = rotPt(cx, cy, a, p[1] * s, p[2] * s)
    for i = 3, #p - 2, 2 do
      local x1, y1 = rotPt(cx, cy, a, p[i] * s, p[i + 1] * s)
      local x2, y2 = rotPt(cx, cy, a, p[i + 2] * s, p[i + 3] * s)
      tri(x0, y0, x1, y1, x2, y2, color)
    end
  end
  local n = #outline
  for i = 1, n, 2 do
    local j = i + 2 > n and 1 or i + 2
    local x1, y1 = rotPt(cx, cy, a, outline[i] * s, outline[i + 1] * s)
    local x2, y2 = rotPt(cx, cy, a, outline[j] * s, outline[j + 1] * s)
    line(x1, y1, x2, y2, BLACK)
  end
end

-- top-down plane, nose up before rotation
local PLANE_PARTS = {
  { 0, -1, 0.13, -0.75, 0.13, 0.9, -0.13, 0.9, -0.13, -0.75 },  -- fuselage
  { 0.13, -0.25, 1, 0.15, 1, 0.32, 0.13, 0.12 },                -- right wing
  { -0.13, -0.25, -0.13, 0.12, -1, 0.32, -1, 0.15 },            -- left wing
  { 0.12, 0.6, 0.45, 0.83, 0.45, 0.97, 0.12, 0.9 },             -- right tailplane
  { -0.12, 0.6, -0.12, 0.9, -0.45, 0.97, -0.45, 0.83 },         -- left tailplane
}
local PLANE_OUTLINE = { 0, -1, 0.13, -0.75, 0.13, -0.25, 1, 0.15, 1, 0.32, 0.13, 0.12, 0.12, 0.6, 0.45, 0.83,
  0.45, 0.97, 0, 0.9, -0.45, 0.97, -0.45, 0.83, -0.12, 0.6, -0.13, 0.12, -1, 0.32, -1, 0.15, -0.13, -0.25,
  -0.13, -0.75 }

local function drawPlane(cx, cy, hdg, size, color)
  drawShape(cx, cy, math.rad(hdg), size * 1.4, PLANE_PARTS, PLANE_OUTLINE, color)
end

-- top-down quad in X layout, with a pointer between the front rotors
local function drawDrone(cx, cy, hdg, size, color)
  local a, s = math.rad(hdg), size * 1.2
  local d, r = s * 0.62, math.max(3, I(s * 0.3))
  for _, q in ipairs({ { 1, -1 }, { 1, 1 }, { -1, 1 }, { -1, -1 } }) do
    local x, y = rotPt(cx, cy, a, q[1] * d, q[2] * d)
    line(cx, cy, x, y, BLACK)
    line(cx + 1, cy, x + 1, y, BLACK)
    line(cx, cy + 1, x, y + 1, BLACK)
    lcd.drawFilledCircle(x, y, r, color)
    lcd.drawCircle(x, y, r, BLACK)
  end
  drawShape(cx, cy, a, s, { { 0, -0.62, 0.22, -0.18, 0.22, 0.25, -0.22, 0.25, -0.22, -0.18 } },
    { 0, -0.62, 0.22, -0.18, 0.22, 0.25, -0.22, 0.25, -0.22, -0.18 }, color)
end

local function drawCursor(widget, cx, cy, hdg, size, color)
  local c = widget.options.Cursor
  if c == 2 then drawDrone(cx, cy, hdg, size, color)
  elseif c == 3 then drawPlane(cx, cy, hdg, size, color)
  else drawArrow(cx, cy, hdg, size, color) end
end

local function drawMap(widget, mx, my, mw, mh, L)
  local level = widget.zoom
  local ts = L.tileScale         -- tile size on screen, px
  fillRect(mx, my, mw, mh, C.nomap)
  if tele.lat == nil then
    text(mx + mw / 2, my + mh / 2 - 8, "Waiting for GPS", CENTER + L.font + C.text)
    text(mx + mw / 2, my + mh / 2 + 12, "New View Telemetry by NVFPV", CENTER + SMLSIZE + C.dim)
    return
  end
  local ax, ay = project(tele.lat, tele.lon, level)
  local cx, cy = mx + mw / 2, my + mh / 2
  -- screen position of the top-left corner of tile (0,0) relative to the aircraft
  local tx0 = math.floor(ax - (mw / 2) / ts)
  local ty0 = math.floor(ay - (mh / 2) / ts)
  local tx1 = math.floor(ax + (mw / 2) / ts)
  local ty1 = math.floor(ay + (mh / 2) / ts)
  local missing = 0
  for ty = ty0, ty1 do
    for tx = tx0, tx1 do
      local sx = math.floor(cx + (tx - ax) * ts)
      local sy = math.floor(cy + (ty - ay) * ts)
      local bmp = getTile(tilePath(tx, ty, level))
      if bmp then
        lcd.drawBitmap(bmp, I(sx), I(sy))
      elseif bmp == false then
        missing = missing + 1
      end
    end
  end

  local function toScreen(lat, lon)
    local x, y = project(lat, lon, level)
    return math.floor(cx + (x - ax) * ts), math.floor(cy + (y - ay) * ts)
  end
  local function inMap(x, y) return x >= mx and x < mx + mw and y >= my and y < my + mh end

  local wt = 2 ^ (17 - level)
  for i = 1, #trail do
    local p = trail[i]
    local x, y = floor(cx + (p[3] * wt - ax) * ts), floor(cy + (p[4] * wt - ay) * ts)
    if inMap(x, y) then lcd.drawFilledRectangle(x - 1, y - 1, 3, 3, C.trail) end
  end

  if home.lat ~= nil then
    local hx, hy = toScreen(home.lat, home.lon)
    if inMap(hx, hy) then
      local r = L.arrow * 0.6
      tri(hx, hy - r, hx + r, hy, hx - r, hy, C.home)
      fillRect(hx - r * 0.6, hy, r * 1.2, r * 0.8, C.home)
    end
  end

  drawCursor(widget, cx, cy, tele.hdg, L.arrow, C.plane)

  -- scale bar: GMapCatcher tiles are 40075 km / 2^(17-level) wide at the equator
  local mPerPx = 40075017 * math.cos(math.rad(tele.lat)) / (2 ^ (17 - level)) / ts
  local barM = 50 * 2 ^ (level + 2)
  local barPx = barM / mPerPx
  local by = my + mh - L.small - 6
  fillRect(mx + 4, by - 2, barPx, 3, C.text)
  local label = barM >= 1000 and string.format("%gkm", barM / 1000) or string.format("%dm", I(barM))
  text(mx + 4, by - L.small - 4, label .. " z" .. level, SMLSIZE + C.text)
  if missing > 0 and missing == (tx1 - tx0 + 1) * (ty1 - ty0 + 1) then
    -- under the cursor, so it never sits under the GPS LOST warning at the top
    text(mx + mw / 2, my + mh / 2 + L.arrow * 2, "no tiles here", CENTER + SMLSIZE + C.warn)
  end
end

-- attitude -----------------------------------------------------------------

local function drawHorizon(x, y, w, h)
  local roll = val("Roll")
  local pitch = val("Ptch")
  fillRect(x, y, w, h, C.sky)
  local cx, cy = x + w / 2, y + h / 2
  local off = math.deg(pitch) * h / 60   -- 60 degrees of pitch fills the box
  local t = math.tan(-roll)
  -- ground drawn in vertical strips; about 60 strips whatever the width keeps it cheap
  local x0, y0, bottom, ww = I(x), I(y), I(y + h), I(w)
  local step = math.max(1, ww // 60)
  for i = 0, ww - 1, step do
    local sw = math.min(step, ww - i)
    local hy = floor(cy + off + (i + sw / 2 - w / 2) * t)
    if hy < y0 then hy = y0 end
    if hy < bottom then lcd.drawFilledRectangle(x0 + i, hy, sw, bottom - hy, C.ground) end
  end
  line(cx - w / 4, cy, cx - 6, cy, C.warn)
  line(cx + 6, cy, cx + w / 4, cy, C.warn)
  fillRect(cx - 1, cy - 1, 3, 3, C.warn)
  rect(x, y, w, h, C.dim)
end

-- panel --------------------------------------------------------------------

-- 0 = no warning, 1 = close to the limit, 2 = past it. A limit of 0 (or nil) is off.
local function levelMin(v, limit, margin)
  if not limit or limit <= 0 or v <= 0 then return 0 end
  if v < limit then return 2 elseif v < limit + margin then return 1 end
  return 0
end

local function levelMax(v, limit, margin)
  if not limit or limit <= 0 then return 0 end
  if v > limit then return 2 elseif v > limit - margin then return 1 end
  return 0
end

local function levelColor(lv)
  if lv == 2 then return C.crit elseif lv == 1 then return C.warn end
  return C.text
end

-- cell count: from the setting, else worked out once from the first pack voltage (4.35 V max per cell)
local cellCount = 0
local function cells(o, v)
  if o.Cells and o.Cells > 0 then return o.Cells end
  if v < 2 then cellCount = 0; return 0 end
  if cellCount == 0 then cellCount = math.ceil(v / 4.35) end
  return cellCount
end

-- checks every limit; the results colour the panel and drive the alert beeps
local warn = {}
local nextAlert = 0
local function checkLimits(widget)
  local o = widget.options
  local v = val("RxBt")
  local n = cells(o, v)
  warn.cells = n
  warn.cellV = n > 0 and v / n or 0
  warn.batt = levelMin(warn.cellV, (o.CellMin or 0) / 100, 0.1)
  warn.pct = levelMin(val("Bat%"), o.BatMin, 10)
  warn.sats = levelMin(val("Sats"), o.SatMin, 2)
  warn.lq = levelMin(val("RQly"), o.LQMin, 15)
  warn.alt = levelMax(altitude(), o.AltMax, math.max(5, (o.AltMax or 0) * 0.1))
  local dist = 0
  if home.lat ~= nil and tele.lat ~= nil then dist = distBearing(home.lat, home.lon, tele.lat, tele.lon) end
  warn.dist = levelMax(dist, o.DistMax, math.max(20, (o.DistMax or 0) * 0.1))
  warn.home = dist
  local any = warn.batt == 2 or warn.pct == 2 or warn.sats == 2 or warn.lq == 2 or warn.alt == 2 or warn.dist == 2
  local now = getTime()
  if any and o.Alerts == 1 and isArmed(fmText()) and now >= nextAlert then
    playTone(2200, 150, 0, PLAY_NOW)
    playHaptic(150, 0)
    nextAlert = now + 500
  end
end

local function item(px, y, w, label, value, color, L)
  text(px + 4, y + L.labelDy, label, SMLSIZE + C.dim)
  text(px + w - 4, y, value, RIGHT + L.font + (color or C.text))
end

-- waiting for GPS: the New View load screen fills the widget until the first fix ------------

local WAIT_DIR = "/WIDGETS/NewView/splash/"
local WAIT_SIZES = { {800, 480}, {480, 320}, {480, 272}, {320, 240}, {320, 480} }
local wait = {}               -- picture and where it goes; dropped after the first fix to free memory

-- an exact size if there is one, else the closest shape, scaled to fit
local function loadWaitPicture(zw, zh)
  local best, bestErr
  for _, s in ipairs(WAIT_SIZES) do
    if s[1] == zw and s[2] == zh then best = s break end
    local err = math.abs(math.log((s[1] / s[2]) / (zw / zh)))
    if s[1] < zw or s[2] < zh then err = err + 0.05 end   -- prefer shrinking over enlarging
    if bestErr == nil or err < bestErr then best, bestErr = s, err end
  end
  local k = math.min(zw / best[1], zh / best[2])
  wait.bmp = Bitmap.open(WAIT_DIR .. "splash_" .. best[1] .. "x" .. best[2] .. ".png")
  wait.w, wait.h = floor(best[1] * k), floor(best[2] * k)
  wait.x, wait.y = floor((zw - wait.w) / 2), floor((zh - wait.h) / 2)
  wait.scale = floor(k * 100 + 0.5)
  wait.zw, wait.zh = zw, zh
end

-- returns false if the picture is missing, so the plain map-area message is used instead
local function drawWaiting(zw, zh)
  if wait.zw ~= zw or wait.zh ~= zh then loadWaitPicture(zw, zh) end
  if not wait.bmp then return false end
  fillRect(0, 0, zw, zh, BLACK)
  if wait.scale == 100 then lcd.drawBitmap(wait.bmp, wait.x, wait.y)
  else lcd.drawBitmap(wait.bmp, wait.x, wait.y, wait.scale) end
  -- status line and a scanning bar where the load screen's progress bar sits, in night-vision green
  local green, pale = lcd.RGB(91, 255, 106), lcd.RGB(200, 255, 191)
  local bx, bw = wait.x + floor(0.2 * wait.w), floor(0.6 * wait.w)
  local bh = math.max(4, floor(wait.h / 60))
  local by = wait.y + floor(0.905 * wait.h)
  local msg
  if fmText() == nil then msg = "NO TELEMETRY"
  else msg = string.format("WAITING FOR GPS  -  SATS %d", I(val("Sats"))) end
  text(wait.x + wait.w / 2, by + bh + 2, msg, CENTER + (wait.h >= 400 and 0 or SMLSIZE) + green)
  lcd.drawRectangle(bx - 1, by - 1, bw + 2, bh + 2, green)
  local seg = floor(bw / 4)
  local pos = floor((getTime() % 200) / 200 * (bw + seg)) - seg
  local x0, x1 = math.max(0, pos), math.min(bw, pos + seg)
  if x1 > x0 then fillRect(bx + x0, by, x1 - x0, bh, pale) end
  return true
end

local function dropWaiting()
  if wait.bmp or wait.zw then
    wait = {}
    collectgarbage()
  end
end

local function drawPanel(px, py, pw, ph, L)
  local w = warn
  fillRect(px, py, pw, ph, C.panel)
  local y = py + 2
  local fm = fmText()
  local armed, name, note = fmState(fm)
  local fmColor = (fm == nil or fm == "!FS!") and C.crit or (armed and C.ok or C.warn)
  text(px + pw / 2, y, name or "NO TELEM", CENTER + L.big + fmColor)
  y = y + L.bigH
  text(px + pw / 2, y, note or (armed and "ARMED" or "DISARMED"), CENTER + SMLSIZE + ((armed or note) and C.crit or C.dim))
  y = y + L.small + 4

  local hh = L.horizon
  if hh > 0 then
    drawHorizon(px + 4, y, pw - 8, hh)
    y = y + hh + 3
  end

  local rows = {}
  local v = val("RxBt")
  rows[#rows + 1] = { (w.cells or 0) > 0 and ("Batt " .. w.cells .. "S") or "Batt", string.format("%.1fV", v), levelColor(w.batt) }
  local pct = val("Bat%"); rows[#rows + 1] = { "Bat%", string.format("%d%%", I(pct)), levelColor(w.pct) }
  rows[#rows + 1] = { "Curr", string.format("%.1fA", val("Curr")), C.text }
  rows[#rows + 1] = { "Used", string.format("%dmAh", I(val("Capa"))), C.text }
  local sats = val("Sats"); rows[#rows + 1] = { "Sats", string.format("%d", I(sats)), levelColor(w.sats) }
  rows[#rows + 1] = { "Alt", string.format("%dm", I(altitude())), levelColor(w.alt) }
  rows[#rows + 1] = { "Spd", string.format("%dkm/h", I(val("GSpd"))), C.text }
  local dist = w.home or 0
  rows[#rows + 1] = { "Home", dist >= 1000 and string.format("%.2fkm", dist / 1000) or string.format("%dm", I(dist)), levelColor(w.dist) }
  local lq = val("RQly"); rows[#rows + 1] = { "LQ", string.format("%d%%", I(lq)), levelColor(w.lq) }
  rows[#rows + 1] = { "RSSI", string.format("%ddB", I(val("1RSS"))), C.text }

  local avail = py + ph - y
  local n = math.max(1, math.min(#rows, math.floor(avail / L.rowH)))
  for i = 1, n do
    item(px, y, pw, rows[i][1], rows[i][2], rows[i][3], L)
    y = y + L.rowH
  end

end

-- layout -------------------------------------------------------------------

local function layout(w, h)
  local L = {}
  local k = math.min(w / 480, h / 272)
  -- tiles are drawn at their real size: scaled bitmaps leave seams at the map edge and cost CPU,
  -- so a bigger screen simply shows more ground
  L.tileScale = 100
  -- font size from the short side: a 320x480 portrait screen uses the same fonts as 480x320,
  -- so all ten panel rows fit under the map
  local t = math.min(w, h)
  L.small = t >= 400 and 16 or 12
  if t >= 400 then
    L.font, L.big, L.bigH, L.rowH, L.labelDy = MIDSIZE, DBLSIZE, 48, 30, 8
  elseif t >= 260 then
    L.font, L.big, L.bigH, L.rowH, L.labelDy = 0, MIDSIZE, 26, 17, 2
  else
    L.font, L.big, L.bigH, L.rowH, L.labelDy = SMLSIZE, 0, 20, 15, 0
  end
  L.arrow = math.max(8, math.floor(12 * k))
  if h > w then
    -- portrait: map on top, panel below
    L.mx, L.my, L.mw, L.mh = 0, 0, w, math.floor(h * 0.55)
    L.px, L.py, L.pw, L.ph = 0, L.mh, w, h - L.mh
    L.horizon = 0
  else
    L.pw = math.max(110, math.floor(w * 0.3))
    L.mx, L.my, L.mw, L.mh = 0, 0, w - L.pw, h
    L.px, L.py, L.ph = w - L.pw, 0, h
    L.horizon = h >= 230 and math.floor(h * 0.18) or 0
  end
  return L
end

-- zoom ---------------------------------------------------------------------

local function clampZoom(widget, z)
  local lo, hi = widget.options.MinZoom, widget.options.MaxZoom
  if lo > hi then lo, hi = hi, lo end
  return math.max(lo, math.min(hi, z))
end

local function handleZoom(widget, event)
  local src = widget.options.Zoom
  if src ~= nil and src ~= 0 then
    local v = getValue(src)
    local now = getTime()
    if v < -512 or v > 512 then
      -- one step per flick; holding repeats after 1.5 s, then every second
      if widget.zoomT == nil or now >= widget.zoomT then
        widget.zoom = clampZoom(widget, widget.zoom + (v < 0 and -1 or 1))
        widget.zoomT = now + (widget.zoomT == nil and ZOOM_FIRST or ZOOM_REPEAT)
      end
    else
      widget.zoomT = nil
    end
  end
  if event ~= nil and event ~= 0 then
    if event == EVT_VIRTUAL_NEXT or event == EVT_ROT_RIGHT or event == EVT_PLUS_BREAK then
      widget.zoom = clampZoom(widget, widget.zoom + 1)
    elseif event == EVT_VIRTUAL_PREV or event == EVT_ROT_LEFT or event == EVT_MINUS_BREAK then
      widget.zoom = clampZoom(widget, widget.zoom - 1)
    end
  end
end

-- widget API ---------------------------------------------------------------

local function create(zone, opts)
  initColors()
  local w = { zone = zone, options = opts }
  w.zoom = clampZoom(w, opts.MinZoom)
  w.L = layout(zone.w, zone.h)
  return w
end

local function update(widget, opts)
  widget.options = opts
  widget.zoom = clampZoom(widget, widget.zoom)
  widget.L = layout(widget.zone.w, widget.zone.h)
end

local function background(widget)
  updateTelemetry(widget)
  checkLimits(widget)
end

local function refresh(widget, event, touchState)
  local z = widget.zone
  if widget.L == nil or widget.lw ~= z.w or widget.lh ~= z.h then
    widget.L = layout(z.w, z.h)
    widget.lw, widget.lh = z.w, z.h
  end
  local L = widget.L
  updateTelemetry(widget)
  checkLimits(widget)
  if tele.lat == nil then
    if drawWaiting(z.w, z.h) then
      frame = frame + 1
      return
    end
  else
    dropWaiting()
  end
  handleZoom(widget, event)
  drawMap(widget, L.mx, L.my, L.mw, L.mh, L)
  trimCache()
  drawPanel(L.px, L.py, L.pw, L.ph, L)
  if lastFix ~= nil and getTime() - lastFix > 300 then
    text(L.mx + L.mw / 2, L.my + 4, "GPS LOST", CENTER + MIDSIZE + BLINK + C.crit)
  end
  frame = frame + 1
  loads = 0
end

return { name = "New View Telemetry", options = options, translate = translate, create = create, update = update, background = background, refresh = refresh }
