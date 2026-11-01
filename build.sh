#!/bin/zsh
# Builds build/app.noindex/Tidemark.app ("Tidemark"). Pass --install to copy it into /Applications.
# Pass --release for a universal, Developer ID-signed, notarized build/Tidemark.zip to share.
set -e
cd "$(dirname "$0")"
if [[ "$1" == "--release" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Tidemark
else
  swift build -c release
  BIN=.build/release/Tidemark
fi
if [[ ! -f build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
# .noindex keeps the dev build out of Spotlight/Launchpad, so only the installed copy shows up
APP=build/app.noindex/Tidemark.app
rm -rf $APP build/Tidemark.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/
cp Info.plist $APP/Contents/
cp build/AppIcon.icns $APP/Contents/Resources/
if [[ "$1" == "--release" ]]; then
  codesign --force --options runtime --timestamp -s "Developer ID Application: ERTAN ASAN (N9P7QZ9792)" $APP
  # Credentials stored once with: xcrun notarytool store-credentials tidemark-notary
  rm -f build/Tidemark.zip
  ditto -c -k --keepParent $APP build/Tidemark.zip
  xcrun notarytool submit build/Tidemark.zip --keychain-profile tidemark-notary --wait
  xcrun stapler staple $APP
  rm build/Tidemark.zip
  ditto -c -k --keepParent $APP build/Tidemark.zip
  echo "Built build/Tidemark.zip"
  exit 0
fi
codesign --force -s - $APP
echo "Built $APP"
if [[ "$1" == "--install" ]]; then
  rm -rf /Applications/Tidemark.app
  cp -R $APP /Applications/
  touch /Applications/Tidemark.app
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  $LSREGISTER -f /Applications/Tidemark.app
  # Finder "Open in Tidemark" Quick Action (right-click a folder)
  mkdir -p ~/Library/Services
  rm -rf ~/Library/Services/"Open in Tidemark.workflow"
  cp -R "scripts/Open in Tidemark.workflow" ~/Library/Services/
  # Show it in Finder's right-click menu, not just the app menu's Services submenu
  defaults write pbs NSServicesStatus -dict-add '"(null) - Open in Tidemark - runWorkflowAsService"' \
    '{ "presentation_modes" = { ContextMenu = 1; FinderPreview = 1; ServicesMenu = 1; TouchBar = 0; }; }'
  /System/Library/CoreServices/pbs -update
  echo "Installed /Applications/Tidemark.app"
fi
