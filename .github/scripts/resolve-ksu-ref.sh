#!/usr/bin/env bash
# KernelSU ref resolution for GKI builds. Manager CI helpers below are also sourced by
# download-manager-from-actions.sh — keep them free of required env vars until main runs.

KSU_BUILD_MANAGER_WORKFLOW="build-manager.yml"
KSU_RELEASE_WORKFLOW="release.yml"

ksu_github_api_curl() {
  local repo="${KSU_API_REPO:-}"
  local auth=()
  if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ "$repo" = "$GITHUB_REPOSITORY" ]; then
    auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" "$@"
}

ksu_workflow_run_id_for_head_sha() {
  local repo="$1"
  local workflow_file="$2"
  local sha="$3"
  local run_json run_id

  KSU_API_REPO="$repo"
  run_json="$(ksu_github_api_curl \
    "https://api.github.com/repos/${repo}/actions/workflows/${workflow_file}/runs?head_sha=${sha}&status=success&per_page=1")"
  run_id="$(printf '%s' "$run_json" | jq -r '.workflow_runs[0].id // empty')"
  if [ -n "$run_id" ] && [ "$run_id" != "null" ]; then
    printf '%s\n' "$run_id"
    return 0
  fi
  return 1
}

ksu_workflow_run_id_for_branch() {
  local repo="$1"
  local workflow_file="$2"
  local branch="$3"
  local run_json run_id

  KSU_API_REPO="$repo"
  run_json="$(ksu_github_api_curl \
    "https://api.github.com/repos/${repo}/actions/workflows/${workflow_file}/runs?branch=${branch}&status=success&per_page=1")"
  run_id="$(printf '%s' "$run_json" | jq -r '.workflow_runs[0].id // empty')"
  if [ -n "$run_id" ] && [ "$run_id" != "null" ]; then
    printf '%s\n' "$run_id"
    return 0
  fi
  return 1
}

ksu_branch_head_sha() {
  local repo="$1"
  local branch="$2"
  local sha

  KSU_API_REPO="$repo"
  sha="$(ksu_github_api_curl "https://api.github.com/repos/${repo}/git/ref/heads/${branch}" \
    | jq -r '.object.sha // empty')"
  if [ -z "$sha" ] || [ "$sha" = "null" ]; then
    return 1
  fi
  printf '%s\n' "$sha"
}

ksu_main_head_sha() {
  ksu_branch_head_sha "$1" "main"
}

# Returns 0 if <branch> exists on <repo> (no stdout). Used to decide whether the
# Dev tier can track its own 'dev' branch or must collapse onto 'main'.
ksu_branch_exists() {
  local repo="$1"
  local branch="$2"
  local sha

  KSU_API_REPO="$repo"
  sha="$(ksu_github_api_curl "https://api.github.com/repos/${repo}/git/ref/heads/${branch}" 2>/dev/null \
    | jq -r '.object.sha // empty' 2>/dev/null)" || true
  [ -n "$sha" ] && [ "$sha" != "null" ]
}

ksu_latest_build_manager_sha_on_branch() {
  local repo="$1"
  local branch="$2"
  local nabe="${3:-1}"
  local index=$((nabe - 1))
  local sha

  KSU_API_REPO="$repo"
  sha="$(ksu_github_api_curl \
    "https://api.github.com/repos/${repo}/actions/workflows/${KSU_BUILD_MANAGER_WORKFLOW}/runs?status=success&branch=${branch}&per_page=${nabe}" \
    | jq -r --argjson idx "$index" '.workflow_runs[$idx].head_sha // empty')"
  if [ -z "$sha" ] || [ "$sha" = "null" ]; then
    return 1
  fi
  printf '%s\n' "$sha"
}

# Sets KSU_RESOLVED_LATEST_SHA and KSU_LATEST_SOURCE for the given branch
# (no stdout; safe under set -u). Prefers the branch HEAD when it has a successful
# Release/build-manager run, else the newest such commit on the branch.
ksu_resolve_branch_sha() {
  local repo="$1"
  local branch="${2:-main}"
  local head sha

  KSU_RESOLVED_LATEST_SHA=""
  KSU_LATEST_SOURCE=""

  head="$(ksu_branch_head_sha "$repo" "$branch")" || {
    echo "::error::Failed to read ${branch} HEAD for ${repo}" >&2
    return 1
  }

  if ksu_workflow_run_id_for_head_sha "$repo" "$KSU_RELEASE_WORKFLOW" "$head" >/dev/null; then
    KSU_LATEST_SOURCE="${branch}-head-release"
    KSU_RESOLVED_LATEST_SHA="$head"
    return 0
  fi

  if ksu_workflow_run_id_for_head_sha "$repo" "$KSU_BUILD_MANAGER_WORKFLOW" "$head" >/dev/null; then
    KSU_LATEST_SOURCE="${branch}-head-build-manager"
    KSU_RESOLVED_LATEST_SHA="$head"
    return 0
  fi

  sha="$(ksu_latest_build_manager_sha_on_branch "$repo" "$branch" 1)" || {
    echo "::error::No successful Release or build-manager run on ${repo}@${branch}" >&2
    return 1
  }
  KSU_LATEST_SOURCE="${branch}-fallback"
  KSU_RESOLVED_LATEST_SHA="$sha"
  return 0
}

ksu_resolve_latest_sha() {
  ksu_resolve_branch_sha "$1" "main"
}

# Sets KSU_MANAGER_RUN_ID, MANAGER_RUN_SOURCE, and MANAGER_RUN_FALLBACK_MAIN (no stdout; safe under set -u).
ksu_find_manager_run_id() {
  local repo="$1"
  local sha="$2"
  local run_id

  if ! [[ "$sha" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    echo "::error::Manager download requires a 40-char commit SHA, got: ${sha}" >&2
    return 1
  fi

  KSU_MANAGER_RUN_ID=""
  MANAGER_RUN_SOURCE=""
  MANAGER_RUN_FALLBACK_MAIN=0

  if run_id="$(ksu_workflow_run_id_for_head_sha "$repo" "$KSU_BUILD_MANAGER_WORKFLOW" "$sha")"; then
    MANAGER_RUN_SOURCE="build-manager"
    KSU_MANAGER_RUN_ID="$run_id"
    return 0
  fi

  if run_id="$(ksu_workflow_run_id_for_head_sha "$repo" "$KSU_RELEASE_WORKFLOW" "$sha")"; then
    MANAGER_RUN_SOURCE="release"
    KSU_MANAGER_RUN_ID="$run_id"
    return 0
  fi

  echo "::notice::No successful build-manager or Release run for ${repo} at head_sha=${sha}; falling back to latest successful build-manager on main" >&2
  if run_id="$(ksu_workflow_run_id_for_branch "$repo" "$KSU_BUILD_MANAGER_WORKFLOW" "main")"; then
    MANAGER_RUN_SOURCE="fallback-main"
    MANAGER_RUN_FALLBACK_MAIN=1
    KSU_MANAGER_RUN_ID="$run_id"
    return 0
  fi

  echo "::error::No successful build-manager run for ${repo} on main either" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0 2>/dev/null || true
fi

set -euo pipefail

KSU_VARIANT="${KSU_VARIANT:?KSU_VARIANT is required}"
KSU_BRANCH="${KSU_BRANCH:?KSU_BRANCH is required}"
CUSTOM_REF="${CUSTOM_REF:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Stable / Dev = 静态钉版层（手动维护 SHA）。动态解析会加大维护难度且不可复现，故这两层
# 只用固定 commit；仅 Latest 层动态追踪 main。选取的 commit 需满足：既有成功的
# build-manager/Release run（manager APK 从该 run 取），又其内核源码仍匹配 CI 的补丁布局
# (见 build.yml)。刷新时用一次全矩阵 dispatch 验证。
#
# 2026-10-05: ReSukiSU/ReSukiSU 上游改名 Baka-SU/BakaSU（同一仓库，未 fork），变体名随之
# 改为 BakaSU；上游没有 dev 分支，故 BAKASU 的 Stable 与 Dev 同钉 main HEAD。旧 SHA 94dd3c93
# 在改名后的仓库里仍可达，必要时可作为回退基线。
#
# 2026-11-02: BAKASU 由 9dbce02e (2026-10-05) 抬到 516d3e87 (2026-10-31 main HEAD)。
# susfs4ksu 自 2026-10-19/10-24 起删掉了自己在 KernelSU 侧的实现，改为复用上游 KernelSU 的
# module preinit 与 selinux_hide（"Reuse upstream selinux_hide existing code" /
# "Sync with the official KernelSU main repo"），内核侧 50_add_susfs_in_gki-*.patch 因此直接
# extern 引用 ksu_setup_preinit_file / ksu_preinit_handle_post_execveat / my_write_context /
# my_write_access / my_setprocattr。9dbce02e 早于 BakaSU 加 preinit (2026-10-16)、也早于把
# my_* 改成 __maybe_static 导出 (2026-10-24)，链接期必然 undefined symbol；516d3e87 两个缺口
# 都已具备，且 main 上有成功的 build-manager run (41207077584)，manager APK 仍按
# Manager-release 取得到。
#
# 2026-09-30: 按用户要求 Stable 与 Dev 均钉到各上游 main 的最新 commit（"都最新"），用一次
# 全矩阵编译确认当前上游能否直接编过。注意：本仓 6 月的兼容 shim (.github/scripts/
# ensure-ksu-compat.py + build.yml) 与 SUSFS 补丁仍针对 v3.2.x API，与最新 KSU 大概率不匹配
# (12 处 -Werror + patch reject)，需后续更新补丁"再修"。若全编译失败、需回退到可编译基线，
# 把下面三行 STABLE 改回 v3.2.5=b0bc817b… 系列，并将 config/config 的 custom 改回 true。
# 2026-11-03: SUKISU 由 cf87e3f4 (2026-09-21) 抬到 b34a3c98 (2026-11-03 main HEAD)。
# 上游 10 月这波改动很大：kernel/preinit/ 落地（SUSFS GKI 补丁要的 preinit 后端改由上游提供）、
# kernel/kpm/ 换成 kernel/extension/、supercall/dispatch.c 重写、supercall/selinux_hide 导出调整。
# 因此 b34a3c98 上的内核源码与 cf87e3f4 的补丁锚点不再逐字相同，本仓同步做了两处适配：
#   1) .github/scripts/fix_sukisu_susfs.py 的 ksu_stop_input_hook_runtime 锚点改为同时接受
#      旧版（schedule_work 返回值打日志）与新版（2026-10 起删掉该日志）两种写法；
#   2) 抬版后跑一次全矩阵 dispatch 验证 SUSFS 侧仍能编过。
# 选取依据：b34a3c98 在 main 上有成功的 build-manager run（41590963923），manager APK 取得到。
OFFICIAL_STABLE_REF="08a3b087e49227c8a6731c5f1114998b5e25255b"  # tiann/KernelSU main HEAD (2026-09-30)
SUKISU_STABLE_REF="b34a3c98b027c21e1e12aee21122b9115657296e"    # SukiSU-Ultra main HEAD (2026-11-03), 需新版 fix_sukisu_susfs.py 锚点
BAKASU_STABLE_REF="516d3e87fbc986ccefdde2c2765f1700612441a9"  # Baka-SU/BakaSU main HEAD (2026-10-31), 需 preinit + selinux_hide 导出

# Dev = 开发层，同为静态钉版；当前与 Stable 同步钉到最新 commit（"都最新"）。
# Baka-SU/BakaSU 没有 dev 分支（只有 main 与若干 feature 分支），故 BAKASU_DEV_REF 与
# BAKASU_STABLE_REF 指向同一个 main HEAD；其他变体若有 dev 分支仍可各自独立钉版。
OFFICIAL_DEV_REF="08a3b087e49227c8a6731c5f1114998b5e25255b"
SUKISU_DEV_REF="b34a3c98b027c21e1e12aee21122b9115657296e"
BAKASU_DEV_REF="516d3e87fbc986ccefdde2c2765f1700612441a9"

# Latest = 最新层，动态追踪各上游 main 的最新（有成功 build-manager/Release run 的）commit。
# 解析逻辑见 resolve_tracking / ksu_resolve_branch_sha。
SUKISU_REPO="SukiSU-Ultra/SukiSU-Ultra"

emit_env() {
  local key="$1"
  local value="$2"
  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "${key}=${value}" >> "$GITHUB_ENV"
  fi
  export "${key}=${value}"
}

get_success_action_sha() {
  local repo="$1"
  local branch="$2"
  local nabe="$3"
  ksu_latest_build_manager_sha_on_branch "$repo" "$branch" "$nabe" || true
}

check_ref() {
  local repo="$1"
  local ref="$2"
  local msg
  if [[ "$ref" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    msg="$(curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
      "https://api.github.com/repos/${repo}/commits/${ref}" | jq -r '.message // empty')"
  elif [[ "$ref" =~ ^[Vv]?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    msg="$(curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
      "https://api.github.com/repos/${repo}/git/ref/tags/${ref}" | jq -r '.message // empty')"
  else
    msg="$(curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
      "https://api.github.com/repos/${repo}/branches/${ref}" | jq -r '.message // empty')"
  fi
  if echo "$msg" | grep -qi "no.*found"; then
    echo "::error::'${ref}' not found in ${repo}" >&2
    exit 1
  fi
}

ksu_variant_repo() {
  case "$1" in
    Official) printf '%s\n' "tiann/KernelSU" ;;
    # GKI builds use main; builtin is for OnePlus only (oneplus-build.yml, not resolve-ksu-ref).
    SukiSU) printf '%s\n' "$SUKISU_REPO" ;;
    BakaSU) printf '%s\n' "Baka-SU/BakaSU" ;;
    *) return 1 ;;
  esac
}

# Resolve a tier that tracks a live upstream branch. Only Latest(最新) uses this now
# (-> always 'main'); Stable/Dev are static pins. The generic branch arg + 'dev'→'main'
# fallback is kept for any future tier that tracks a non-main branch.
# Sets RESOLVED_KSU_{REPO,SOURCE_BRANCH,SHA}.
resolve_tracking() {
  local preferred_branch="$1"
  local repo branch

  repo="$(ksu_variant_repo "$KSU_VARIANT")" || {
    echo "::error::Unknown KSU variant for tracking tier: ${KSU_VARIANT}" >&2
    exit 1
  }

  branch="$preferred_branch"
  if [ "$branch" != "main" ] && ! ksu_branch_exists "$repo" "$branch"; then
    echo "::notice::${repo} 无 '${branch}' 分支，改为追踪 'main' (Dev 与 Latest 同步)" >&2
    branch="main"
  fi

  if ! ksu_resolve_branch_sha "$repo" "$branch"; then
    return 1
  fi

  RESOLVED_KSU_REPO="$repo"
  RESOLVED_KSU_SOURCE_BRANCH="$branch"
  RESOLVED_KSU_SHA="$KSU_RESOLVED_LATEST_SHA"
}

OFFICIAL_CUSTOM_REF=""
SUKISU_CUSTOM_REF=""
BAKASU_CUSTOM_REF=""

if [ "$KSU_BRANCH" = "Custom(自定义)" ]; then
  if [[ "$CUSTOM_REF" =~ ^([A-Za-z0-9._/-]+):([0-9]+)$ ]]; then
    branch="${BASH_REMATCH[1]}"
    nabe="${BASH_REMATCH[2]}"
    case "$KSU_VARIANT" in
      Official) OFFICIAL_CUSTOM_REF="$(get_success_action_sha "tiann/KernelSU" "$branch" "$nabe")" ;;
      SukiSU) SUKISU_CUSTOM_REF="$(get_success_action_sha "$SUKISU_REPO" "$branch" "$nabe")" ;;
      BakaSU) BAKASU_CUSTOM_REF="$(get_success_action_sha "Baka-SU/BakaSU" "$branch" "$nabe")" ;;
    esac
  else
    case "$KSU_VARIANT" in
      Official) check_ref "tiann/KernelSU" "$CUSTOM_REF" ;;
      SukiSU) check_ref "$SUKISU_REPO" "$CUSTOM_REF" ;;
      BakaSU) check_ref "Baka-SU/BakaSU" "$CUSTOM_REF" ;;
    esac
    OFFICIAL_CUSTOM_REF="$CUSTOM_REF"
    SUKISU_CUSTOM_REF="$CUSTOM_REF"
    BAKASU_CUSTOM_REF="$CUSTOM_REF"
  fi
fi

case "$KSU_BRANCH" in
  "Stable(标准)")
    OFFICIAL_REF="$OFFICIAL_STABLE_REF"
    SUKISU_REF="$SUKISU_STABLE_REF"
    BAKASU_REF="$BAKASU_STABLE_REF"
    ;;
  "Dev(开发)")
    OFFICIAL_REF="$OFFICIAL_DEV_REF"
    SUKISU_REF="$SUKISU_DEV_REF"
    BAKASU_REF="$BAKASU_DEV_REF"
    ;;
  "Latest(最新)")
    resolve_tracking "main"
    OFFICIAL_REF="$RESOLVED_KSU_SHA"
    SUKISU_REF="$RESOLVED_KSU_SHA"
    BAKASU_REF="$RESOLVED_KSU_SHA"
    ;;
  "Custom(自定义)")
    OFFICIAL_REF="$OFFICIAL_CUSTOM_REF"
    SUKISU_REF="$SUKISU_CUSTOM_REF"
    BAKASU_REF="$BAKASU_CUSTOM_REF"
    ;;
  *)
    echo "::error::Unknown KSU branch: ${KSU_BRANCH}" >&2
    exit 1
    ;;
esac

case "$KSU_VARIANT" in
  Official)
    BRANCH="${OFFICIAL_REF}"
    RESOLVED_KSU_REPO="${RESOLVED_KSU_REPO:-tiann/KernelSU}"
    ;;
  SukiSU)
    BRANCH="${SUKISU_REF}"
    RESOLVED_KSU_REPO="${RESOLVED_KSU_REPO:-$SUKISU_REPO}"
    ;;
  BakaSU)
    BRANCH="${BAKASU_REF}"
    RESOLVED_KSU_REPO="${RESOLVED_KSU_REPO:-Baka-SU/BakaSU}"
    ;;
  *)
    echo "::error::Unknown KSU variant: ${KSU_VARIANT}" >&2
    exit 1
    ;;
esac

if [ -z "$BRANCH" ] || [ "$BRANCH" = "null" ] || [[ "$BRANCH" == *"null"* ]]; then
  echo "::error::Failed to resolve KernelSU ref (branch=${KSU_BRANCH} variant=${KSU_VARIANT})" >&2
  exit 1
fi

emit_env "EFFECTIVE_KSU_BRANCH" "$KSU_BRANCH"
emit_env "BRANCH" "$BRANCH"
emit_env "RESOLVED_KSU_SHA" "${RESOLVED_KSU_SHA:-$BRANCH}"
emit_env "RESOLVED_KSU_SOURCE_BRANCH" "${RESOLVED_KSU_SOURCE_BRANCH:-}"
emit_env "RESOLVED_KSU_REPO" "${RESOLVED_KSU_REPO:-}"

echo "KSU branch: ${KSU_BRANCH} -> ${BRANCH}"
if [ "$KSU_BRANCH" = "Latest(最新)" ]; then
  emit_env "KSU_LATEST_SOURCE" "${KSU_LATEST_SOURCE:-unknown}"
  echo "${KSU_BRANCH} resolved: repo=${RESOLVED_KSU_REPO} branch=${RESOLVED_KSU_SOURCE_BRANCH} sha=${RESOLVED_KSU_SHA} source=${KSU_LATEST_SOURCE:-unknown}"
fi
