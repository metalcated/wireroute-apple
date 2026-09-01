#!/bin/sh

set -eu

if [ "${ACTION:-}" != "install" ]; then
    echo "note: MapLibre dSYM installation is only required while archiving"
    exit 0
fi

resolved_file="${PROJECT_DIR}/WireGuard.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [ ! -f "${resolved_file}" ]; then
    echo "error: MapLibre dSYM installation could not find ${resolved_file}"
    exit 1
fi

maplibre_identity="$(/usr/bin/plutil -extract pins.0.identity raw -o - "${resolved_file}")"
maplibre_version="$(/usr/bin/plutil -extract pins.0.state.version raw -o - "${resolved_file}")"
if [ "${maplibre_identity}" != "maplibre-gl-native-distribution" ]; then
    echo "error: MapLibre is no longer the first resolved package; update the dSYM installer"
    exit 1
fi

case "${maplibre_version}" in
    6.29.0)
        dsym_sha256="d63ddc911253029eda8a31e3f5721cddc0fdb0796a03a1a1c794dda8ff93c508"
        expected_uuid="19E85E5A-837A-3278-87A6-FA63D4B799E5"
        ;;
    *)
        echo "error: No verified MapLibre dSYM is configured for version ${maplibre_version}"
        exit 1
        ;;
esac

download_url="https://github.com/maplibre/maplibre-native/releases/download/ios-v${maplibre_version}/MapLibre_ios_device.framework.dSYM.zip"
cache_directory="${DERIVED_FILE_DIR}/MapLibreDSYM/${maplibre_version}"
archive_file="${cache_directory}/MapLibre_ios_device.framework.dSYM.zip"
download_file="${archive_file}.download"
expanded_directory="${cache_directory}/expanded"
source_dsym="${expanded_directory}/MapLibre_ios_device.framework.dSYM"
destination_dsym="${DWARF_DSYM_FOLDER_PATH}/MapLibre_ios_device.framework.dSYM"

/bin/mkdir -p "${cache_directory}" "${expanded_directory}" "${DWARF_DSYM_FOLDER_PATH}"

archive_is_valid=false
if [ -f "${archive_file}" ]; then
    archive_hash="$(/usr/bin/shasum -a 256 "${archive_file}" | /usr/bin/awk '{print $1}')"
    if [ "${archive_hash}" = "${dsym_sha256}" ]; then
        archive_is_valid=true
    fi
fi

if [ "${archive_is_valid}" != true ]; then
    echo "note: Downloading verified MapLibre ${maplibre_version} device dSYM"
    /usr/bin/curl --fail --location --silent --show-error "${download_url}" --output "${download_file}"
    download_hash="$(/usr/bin/shasum -a 256 "${download_file}" | /usr/bin/awk '{print $1}')"
    if [ "${download_hash}" != "${dsym_sha256}" ]; then
        echo "error: MapLibre dSYM checksum did not match the official ${maplibre_version} release"
        exit 1
    fi
    /bin/mv -f "${download_file}" "${archive_file}"
fi

if [ ! -d "${source_dsym}" ]; then
    /usr/bin/ditto -x -k "${archive_file}" "${expanded_directory}"
fi

source_dwarf="${source_dsym}/Contents/Resources/DWARF/MapLibre_ios_device"
if [ ! -f "${source_dwarf}" ]; then
    echo "error: The verified MapLibre dSYM archive did not contain its device DWARF file"
    exit 1
fi

source_uuid="$(/usr/bin/xcrun dwarfdump --uuid "${source_dwarf}" | /usr/bin/awk '{print $2}')"
if [ "${source_uuid}" != "${expected_uuid}" ]; then
    echo "error: MapLibre dSYM UUID ${source_uuid} did not match expected UUID ${expected_uuid}"
    exit 1
fi

/usr/bin/ditto "${source_dsym}" "${destination_dsym}"
echo "note: Installed MapLibre ${maplibre_version} dSYM with UUID ${source_uuid}"
