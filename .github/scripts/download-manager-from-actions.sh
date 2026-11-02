#!/usr/bin/env bash
set -euo pipefail

REPO="${1:?repo owner/name required}"
KSU_SHA="${2:?commit SHA required}"
VARIANT_DIR="${3:?output dir required}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-ksu-ref.sh
source "${SCRIPT_DIR}/resolve-ksu-ref.sh"

# 管理器 artifact 名字各上游不一致，而且改过：
#   tiann/KernelSU   -> manager (小写)
#   SukiSU-Ultra     -> Manager（2026-09 起改成大写，另有 Manager-gradle / Manager-spoofed）
#   Baka-SU/BakaSU   -> Manager-release（另有 Spoofed-Manager-release）
# nightly.link 的 zip 名是 artifact 名 + ".zip"，大小写敏感（manager.zip 会 404），
# 所以这里维护一个候选列表，API 与 nightly.link 都按顺序、忽略大小写地试。
manager_artifact_candidates() {
  case "$REPO" in
    Baka-SU/BakaSU)
      printf '%s\n' "Manager-release" "Manager" "manager" "Manager-gradle" "Manager-debug"
      ;;
    tiann/KernelSU | SukiSU-Ultra/SukiSU-Ultra)
      printf '%s\n' "Manager" "manager" "Manager-release" "manager-release" "Manager-gradle" "manager-gradle"
      ;;
    *)
      echo "::error::Unknown repo for manager download: ${REPO}" >&2
      return 1
      ;;
  esac
}

# 先按候选名精确匹配（忽略大小写），再退而求其次挑任意带 manager 的产物。
select_artifact_id() {
  local artifacts_json="$1" name artifact_id
  while IFS= read -r name; do
    artifact_id="$(printf '%s' "$artifacts_json" | jq -r --arg name "$name" '
      ([.artifacts[] | select((.name | ascii_downcase) == ($name | ascii_downcase))] | .[0].id) // empty')"
    if [ -n "$artifact_id" ] && [ "$artifact_id" != "null" ]; then
      printf '%s\n' "$artifact_id"
      return 0
    fi
  done < <(manager_artifact_candidates)

  printf '%s' "$artifacts_json" | jq -r '
    ([.artifacts[]
      | select((.name | ascii_downcase) | contains("manager"))
      | select((.name | ascii_downcase) | (contains("spoofed") or contains("mappings")) | not)
     ] | .[0].id) // empty'
}

extract_apk_from_zip() {
  local tmp_zip="$1"
  unzip -o "$tmp_zip" -d "$VARIANT_DIR"
  rm -f "$tmp_zip"
  if ! find "$VARIANT_DIR" -type f -name '*.apk' -print -quit | grep -q .; then
    echo "::error::Downloaded artifact did not contain an APK in ${VARIANT_DIR}" >&2
    find "$VARIANT_DIR" -type f | head -20 >&2 || true
    return 1
  fi
}

try_download_artifact_api() {
  local run_id="$1"
  local tmp_zip artifact_id artifacts_json

  if [ -z "${GITHUB_TOKEN:-}" ]; then
    return 1
  fi

  KSU_API_REPO="$REPO"
  artifacts_json="$(ksu_github_api_curl \
    "https://api.github.com/repos/${REPO}/actions/runs/${run_id}/artifacts")"
  artifact_id="$(select_artifact_id "$artifacts_json")"
  if [ -z "$artifact_id" ] || [ "$artifact_id" = "null" ]; then
    echo "::warning::No manager artifact on run ${run_id} for ${REPO} (candidates: $(manager_artifact_candidates | tr '\n' ' '))" >&2
    return 1
  fi

  mkdir -p "$VARIANT_DIR"
  tmp_zip="$(mktemp "${TMPDIR:-/tmp}/manager-XXXXXX.zip")"
  if ! ksu_github_api_curl -L \
    "https://api.github.com/repos/${REPO}/actions/artifacts/${artifact_id}/zip" \
    -o "$tmp_zip"; then
    rm -f "$tmp_zip"
    return 1
  fi
  extract_apk_from_zip "$tmp_zip"
  echo "Downloaded manager from ${REPO}@${KSU_SHA} (run ${run_id}, source ${MANAGER_RUN_SOURCE}) via Actions API"
}

try_download_nightly_run() {
  local run_id="$1"
  local name url tmp_zip
  mkdir -p "$VARIANT_DIR"

  while IFS= read -r name; do
    url="https://nightly.link/${REPO}/actions/runs/${run_id}/${name}.zip"
    tmp_zip="$(mktemp "${TMPDIR:-/tmp}/manager-XXXXXX.zip")"
    echo "Downloading manager via nightly.link (run ${run_id}, sha ${KSU_SHA}, source ${MANAGER_RUN_SOURCE}): ${url}"
    if ! curl -fsSL -o "$tmp_zip" "$url"; then
      rm -f "$tmp_zip"
      echo "::warning::nightly.link candidate not found: ${name}.zip" >&2
      continue
    fi
    if extract_apk_from_zip "$tmp_zip"; then
      echo "Downloaded manager from ${REPO}@${KSU_SHA} (run ${run_id}, source ${MANAGER_RUN_SOURCE}) via nightly.link"
      return 0
    fi
    echo "::warning::nightly.link candidate had no APK: ${name}.zip" >&2
  done < <(manager_artifact_candidates)

  return 1
}

if ! ksu_find_manager_run_id "$REPO" "$KSU_SHA"; then
  exit 1
fi
run_id="${KSU_MANAGER_RUN_ID}"
if [ "${MANAGER_RUN_FALLBACK_MAIN:-0}" = "1" ]; then
  echo "::notice::Manager APK from latest successful build-manager on main (KSU ref was ${KSU_SHA})" >&2
fi
echo "Manager workflow run for ${REPO}@${KSU_SHA} (source=${MANAGER_RUN_SOURCE}): https://github.com/${REPO}/actions/runs/${run_id}"

if [ -n "${GITHUB_REPOSITORY:-}" ] && [ "$REPO" = "$GITHUB_REPOSITORY" ]; then
  if try_download_artifact_api "$run_id"; then
    exit 0
  fi
  echo "::warning::Actions artifact API failed; trying nightly.link for the same run..." >&2
else
  if try_download_artifact_api "$run_id"; then
    exit 0
  fi
  echo "Fork/cross-repo: Actions artifact zip not available; trying nightly.link for the same run..." >&2
fi

if try_download_nightly_run "$run_id"; then
  exit 0
fi

echo "::error::Failed to download manager for ${REPO}@${KSU_SHA} (run ${run_id}, source ${MANAGER_RUN_SOURCE}) via API and nightly.link" >&2
exit 1
