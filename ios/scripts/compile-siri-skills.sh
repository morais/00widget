#!/bin/bash
set -euo pipefail

# Xcode 27.2 doesn't understand skills bundles. Compile only when the selected
# toolchain carries the compiler, without changing the system-selected Xcode.
output="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Metadata.appintents"
if processor="$(xcrun --find appintentsskillsprocessor 2>/dev/null)"; then
  mkdir -p "$output"
  "$processor" --skillsbundle "${SRCROOT}/Resources/Siri/Skills.skillsbundle" --output "$output"
else
  rm -f "$output/Skills.skillsc"
fi
