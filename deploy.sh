#!/usr/bin/env bash
# Deploy mod-ui source to the running device via rsync and restart the service.
# Override PISTOMP_HOST / PISTOMP_USER if your device differs from the default.
#
# Usage:
#   ./deploy.sh                 # sync Python + HTML, restart service
#   ./deploy.sh --build-utils   # also rsync utils/ source, build on device, install .so
set -euo pipefail

HOST="${PISTOMP_HOST:-pistomp.local}"
USER="${PISTOMP_USER:-pistomp}"
TARGET="${USER}@${HOST}"

VENV="/opt/pistomp/venvs/mod-ui"
HTML_DIR="/opt/pistomp/mod-ui/html"

PYTHON_VERSION="$(ssh "${TARGET}" "ls ${VENV}/lib/" | grep -oE 'python[0-9]+\.[0-9]+' | head -1 | grep -oE '[0-9]+\.[0-9]+')"
SITE_PACKAGES="${VENV}/lib/python${PYTHON_VERSION}/site-packages"

echo "==> Deploying to ${TARGET} (Python ${PYTHON_VERSION})"

rsync -az --delete --exclude='__pycache__' --exclude='*.pyc' \
    mod/ "${TARGET}:${SITE_PACKAGES}/mod/"

# Exclude libmod_utils.so: it is ARM64 and must be built on the device (see --build-utils).
rsync -az --delete --exclude='__pycache__' --exclude='*.pyc' --exclude='libmod_utils.so' \
    modtools/ "${TARGET}:${SITE_PACKAGES}/modtools/"

rsync -az --delete \
    html/ "${TARGET}:${HTML_DIR}/"

if [[ "${1:-}" == "--build-utils" ]]; then
    echo "==> Building utils on device"
    rsync -az --delete --exclude='*.o' --exclude='*.so' \
        utils/ "${TARGET}:/tmp/mod-ui-utils/"
    ssh "${TARGET}" "make -C /tmp/mod-ui-utils && cp /tmp/mod-ui-utils/libmod_utils.so ${SITE_PACKAGES}/modtools/"
fi

echo "==> Restarting mod-ui"
ssh "${TARGET}" "sudo systemctl restart mod-ui"

echo "==> Done"
