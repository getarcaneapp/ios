#!/bin/sh
set -euo pipefail

BUILD_NUMBER=$(date '+%y%m%d.%H%M')

# Locate the .xcodeproj inside the cloned repo. Xcode Cloud doesn't expose
# $PROJECT_FILE_PATH / $PROJECT_DIR / $PROJECT_NAME the way an in-Xcode Run
# Script phase does, so we derive them from $CI_PRIMARY_REPOSITORY_PATH.
PROJECT_FILE_PATH=$(find "$CI_PRIMARY_REPOSITORY_PATH" -maxdepth 3 -name "*.xcodeproj" -print -quit)
PROJECT_DIR=$(dirname "$PROJECT_FILE_PATH")
PROJECT_NAME=$(basename "$PROJECT_FILE_PATH" .xcodeproj)

echo "CURRENT_PROJECT_VERSION = $BUILD_NUMBER" > "${PROJECT_DIR}/${PROJECT_NAME}/BuildNumber.xcconfig"

echo "Updated build number to: $BUILD_NUMBER"
