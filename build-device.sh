#!/bin/bash
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd ~/Turbo-IO/apps/RayNeoCompanion
echo "START $(date)" > ~/Turbo-IO/device-build.log
xcodegen generate --spec project-device.yml >> ~/Turbo-IO/device-build.log 2>&1
xcodebuild build -project RayNeoCompanion.xcodeproj -scheme RayNeoCompanionDevice -destination "platform=iOS,id=00008140-001C41A02E06801C" -derivedDataPath ~/Turbo-IO/.derivedDataDevice DEVELOPMENT_TEAM=7JBC998RH7 -allowProvisioningUpdates >> ~/Turbo-IO/device-build.log 2>&1
echo "EXIT=$?" >> ~/Turbo-IO/device-build.log
