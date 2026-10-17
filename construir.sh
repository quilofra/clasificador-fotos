#!/bin/bash
# Compila la app y arma el bundle .app listo para usar.
set -euo pipefail
cd "$(dirname "$0")"

APP="Clasificador de Fotos.app"
DEST="${1:-$HOME/Applications}"

echo "==> Compilando (release)…"
swift build -c release

echo "==> Icono…"
if python3 -c "import PIL" 2>/dev/null; then
    python3 hacer_icono.py
elif [ -f build/Clasificador.icns ]; then
    echo "    (sin Pillow: reutilizo el icono ya generado)"
else
    echo "    falta Pillow y no hay icono. Instala con: pip3 install pillow"
    exit 1
fi

echo "==> Armando el bundle…"
rm -rf "build/$APP"
mkdir -p "build/$APP/Contents/MacOS" "build/$APP/Contents/Resources"
cp .build/release/Clasificador "build/$APP/Contents/MacOS/Clasificador"
cp build/Clasificador.icns "build/$APP/Contents/Resources/Clasificador.icns"

cat > "build/$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>Clasificador de Fotos</string>
    <key>CFBundleDisplayName</key>          <string>Clasificador de Fotos</string>
    <key>CFBundleIdentifier</key>           <string>com.quilofra.clasificadorfotos</string>
    <key>CFBundleExecutable</key>           <string>Clasificador</string>
    <key>CFBundleIconFile</key>             <string>Clasificador</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>1.0</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.photography</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Para leer las fotos que arrastres al pool desde el Escritorio.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Para leer las fotos que arrastres al pool desde Documentos.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Para leer las fotos que arrastres al pool desde Descargas.</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Para leer las fotos que quieras clasificar.</string>
</dict>
</plist>
PLIST

echo "==> Firmando…"
codesign --force --deep --sign - "build/$APP"

echo "==> Instalando en $DEST…"
mkdir -p "$DEST"
rm -rf "$DEST/$APP"
cp -R "build/$APP" "$DEST/$APP"

echo
echo "Listo: $DEST/$APP"
