@echo off
rem New View Telemetry map tile maker for Windows. Created by NVFPV.
rem Downloads free Sentinel-2 satellite tiles for your flying area into an SD folder next to this file.
echo New View Telemetry map tile maker (by NVFPV)
echo.
python --version >nul 2>&1 || (echo Python is not installed. Get it from https://www.python.org/downloads/ and tick "Add python.exe to PATH". & pause & exit /b 1)
echo Installing the Python packages it needs (only slow the first time)...
python -m pip install --quiet --user rasterio pyproj numpy pillow
echo.
echo Tip: in Google Maps, right-click your field and click the numbers at the top to copy them.
set /p LAT=Centre latitude  (e.g. -33.4193): 
set /p LON=Centre longitude (e.g. 149.5775): 
set /p KM=Size of the square in km (e.g. 10): 
set /p LEVELS=Zoom levels, separated by spaces [0 1 2]: 
if "%LEVELS%"=="" set LEVELS=0 1 2
python "%~dp0make_map_tiles.py" --lat %LAT% --lon %LON% --size-km %KM% --levels %LEVELS% --out "%~dp0SD"
echo.
echo Copy the IMAGES folder from "%~dp0SD" onto the root of your radio's SD card.
pause
