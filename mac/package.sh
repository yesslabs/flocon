#!/bin/sh
# Prépare le zip à vendre : ../dist/Flocon-Mac-<version>.zip (l'app + la notice). Usage : ./package.sh
set -e
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Flocon.app/Contents/Info.plist)
STAGE="../dist/Flocon $VERSION"
rm -rf "$STAGE" ../dist/Flocon-Mac-*.zip
mkdir -p "$STAGE"
cp -R Flocon.app "$STAGE/"
cp LISEZ-MOI.txt "$STAGE/"
# ditto, et non « Compresser » du Finder ni zip : il conserve la signature et les attributs de l'app
ditto -c -k --keepParent "$STAGE" "../dist/Flocon-Mac-$VERSION.zip"
rm -rf "$STAGE"
echo "Prêt : dist/Flocon-Mac-$VERSION.zip"
