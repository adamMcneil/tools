#!/usr/bin/env bash
#
# deploy-plugin.sh - Builds and deploys a Dynamics 365 plugin.
#
# Builds a .NET solution, merges DLLs using ILRepack, and deploys the plugin
# using D365AssemblyUpdater.
#
# Usage:
#   deploy-plugin.sh -e|--environment <test|prod> [options]
#
# Options:
#   -e, --environment <env>   Target environment (required)
#   -p, --publish             Pass -p to the updater
#   -d, --updater-path <path> Path to D365AssemblyUpdater (default: D365AssemblyUpdater)
#   -h, --help                Show this help
#
# Examples:
#   deploy-plugin.sh --environment test
#   deploy-plugin.sh -e prod --publish
#   deploy-plugin.sh -e test -d ./tools/D365AssemblyUpdater
#

set -e

# Defaults
D365_UPDATER_PATH="D365AssemblyUpdater"
PUBLISH=false
ENVIRONMENT=""

usage() {
    local exit_code="${1:-0}"
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
    exit "$exit_code"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        -p|--publish)
            PUBLISH=true
            shift
            ;;
        -d|--updater-path)
            D365_UPDATER_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage 1
            ;;
    esac
done

if [[ -z "$ENVIRONMENT" ]]; then
    echo "Error: --environment is required" >&2
    usage 1
fi

# Build the solution
dotnet build -c Release || { echo "Error: Build failed" >&2; exit 1; }

# Find solution file and derive paths
SOLUTION_FILE=$(find . -maxdepth 1 -name "*.sln" -print -quit)
if [[ -z "$SOLUTION_FILE" ]]; then
    echo "Error: No .sln file found in current directory" >&2
    exit 1
fi

NAME="${SOLUTION_FILE%.sln}"
NAME="${NAME#./}"
BASEPATH="${PWD}/${NAME}"
PLUGIN_DLL="${BASEPATH}/bin/Release/net462/${NAME}.dll"
PLUGIN_BASE_DLL="${BASEPATH}/bin/Release/net462/PluginBase.dll"
KEY="${BASEPATH}/CTI.snk"
# Choose deployment config
JSON=""
EXACT_JSON="${BASEPATH}/deployment.${ENVIRONMENT}.json"
if [[ -f "$EXACT_JSON" ]]; then
    JSON="$EXACT_JSON"
else
    for fallback in dev test prod; do
        candidate="${BASEPATH}/deployment.${fallback}.json"
        if [[ -f "$candidate" ]]; then
            JSON="$candidate"
            break
        fi
    done
fi
if [[ -z "$JSON" ]]; then
    echo "Error: No deployment JSON found for environment '$ENVIRONMENT' and no fallback (dev/test/prod) exists." >&2
    exit 1
fi
echo "Using deployment JSON: $JSON"

MERGED_DLL="${PWD}/merged-dll/${NAME}.dll"
LIB="${BASEPATH}/bin/Release/net462"

# Ensure output directory exists
mkdir -p "$(dirname "$MERGED_DLL")"

# Merge DLLs using ILRepack
ilrepack "/out:${MERGED_DLL}" "$PLUGIN_DLL" "$PLUGIN_BASE_DLL" "/keyfile:${KEY}" "/lib:${LIB}" || { echo "Error: ILRepack merge failed" >&2; exit 1; }

# Deploy using D365AssemblyUpdater
UPDATER_ARGS=(-Action set -n "CTI.Service.Plugins" -o "$ENVIRONMENT" -d "$MERGED_DLL" -j "$JSON")
if [[ "$PUBLISH" == true ]]; then
    UPDATER_ARGS+=(-p)
fi

exec "$D365_UPDATER_PATH" "${UPDATER_ARGS[@]}"
