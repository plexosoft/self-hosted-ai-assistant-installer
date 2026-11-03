#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BOOTSTRAP="${ROOT}/bootstrap.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

bash "${BOOTSTRAP}" --help >"${TMP}/help.txt"
grep -Fq 'Usage: bootstrap.sh [--instance production|sandbox]' "${TMP}/help.txt"

if bash "${BOOTSTRAP}" --instance staging >"${TMP}/invalid-instance.txt" 2>&1; then
    echo 'ERROR: unsupported instance was accepted.' >&2
    exit 1
fi
grep -Fq 'Invalid instance: staging' "${TMP}/invalid-instance.txt"

if bash "${BOOTSTRAP}" --instance= >"${TMP}/empty-instance.txt" 2>&1; then
    echo 'ERROR: empty instance was accepted.' >&2
    exit 1
fi
grep -Fq 'Invalid instance:' "${TMP}/empty-instance.txt"

if bash "${BOOTSTRAP}" --version v1.2.3-rc.1 >"${TMP}/invalid-version.txt" 2>&1; then
    echo 'ERROR: prerelease version format was accepted.' >&2
    exit 1
fi
grep -Fq 'Invalid stable release tag format' "${TMP}/invalid-version.txt"

mkdir -p "${TMP}/home/self-hosted-ai-assistant-sandbox"
printf 'preserve me\n' > "${TMP}/home/self-hosted-ai-assistant-sandbox/keep.txt"
if HOME="${TMP}/home" BOOTSTRAP_DEST="${TMP}/home/self-hosted-ai-assistant-sandbox" \
    bash "${BOOTSTRAP}" --instance sandbox >"${TMP}/existing-destination.txt" 2>&1; then
    echo 'ERROR: existing Sandbox destination was accepted.' >&2
    exit 1
fi
grep -Fq 'Destination already exists' "${TMP}/existing-destination.txt"
grep -Fq 'preserve me' "${TMP}/home/self-hosted-ai-assistant-sandbox/keep.txt"

printf '[test-bootstrap-arguments] All tests passed.\n'
