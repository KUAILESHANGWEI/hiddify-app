#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--sync-hiddify-app-assets" ]; then
  if [ "$#" -gt 2 ]; then
    echo "Usage: $0 --sync-hiddify-app-assets [target-owner/repo]" >&2
    exit 2
  fi

  target_repo="${2:-${GITHUB_REPOSITORY:-KUAILESHANGWEI/hiddify-app}}"
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  script_path="${script_dir}/$(basename -- "${BASH_SOURCE[0]}")"
  repo_root="$(cd -- "${script_dir}/.." && pwd)"

  app_tag="$(gh release view --repo hiddify/hiddify-app --json tagName --jq .tagName)"
  "${script_path}" hiddify/hiddify-app "${app_tag}" "${target_repo}" "${app_tag}" true
  "${script_path}" hiddify/hiddify-app v0.13.6 "${target_repo}" v0.13.6 false

  core_version="$(sed -n 's/^core.version=//p' "${repo_root}/dependencies.properties")"
  core_version_base="${core_version%%-*}"
  "${script_path}" hiddify/hiddify-core "v${core_version_base}" "${target_repo}" "core-v${core_version_base}" false

  "${script_path}" AppImage/appimagetool continuous "${target_repo}" thirdparty-appimagetool-continuous false
  gh release edit "${app_tag}" --repo "${target_repo}" --latest
  exit 0
fi

if [ "$#" -lt 2 ] || [ "$#" -gt 5 ]; then
  echo "Usage: $0 <source-owner/repo> <source-tag|latest> [target-owner/repo] [target-tag] [latest-mode]" >&2
  echo "latest-mode: auto, true, or false. Defaults to auto." >&2
  exit 2
fi

source_repo="$1"
source_ref="$2"
target_repo="${3:-${GITHUB_REPOSITORY:-KUAILESHANGWEI/hiddify-app}}"
target_tag="${4:-}"
latest_mode="${5:-auto}"

case "${latest_mode}" in
  auto|true|false) ;;
  *)
    echo "Invalid latest-mode: ${latest_mode}" >&2
    exit 2
    ;;
esac

if [ "${source_ref}" = "latest" ]; then
  release_json="$(gh release view --repo "${source_repo}" --json tagName,name,isPrerelease,assets)"
else
  release_json="$(gh release view "${source_ref}" --repo "${source_repo}" --json tagName,name,isPrerelease,assets)"
fi

source_tag="$(jq -r '.tagName' <<<"${release_json}")"
release_name="$(jq -r '.name // .tagName' <<<"${release_json}")"
is_prerelease="$(jq -r '.isPrerelease' <<<"${release_json}")"
target_tag="${target_tag:-${source_tag}}"

mapfile -t asset_names < <(jq -r '.assets[].name' <<<"${release_json}")
if [ "${#asset_names[@]}" -eq 0 ]; then
  echo "No release assets found in ${source_repo}@${source_tag}" >&2
  exit 0
fi

tmp_dir="$(mktemp -d)"
notes_file="$(mktemp)"
trap 'rm -rf "${tmp_dir}" "${notes_file}"' EXIT

cat > "${notes_file}" <<EOF
Mirrored release assets from \`${source_repo}\` tag \`${source_tag}\`.

Source release: https://github.com/${source_repo}/releases/tag/${source_tag}
EOF

if gh release view "${target_tag}" --repo "${target_repo}" >/dev/null 2>&1; then
  gh release edit "${target_tag}" \
    --repo "${target_repo}" \
    --title "${release_name}" \
    --notes-file "${notes_file}"
else
  create_args=(--repo "${target_repo}" --title "${release_name}" --notes-file "${notes_file}" --target main)
  if [ "${is_prerelease}" = "true" ]; then
    create_args+=(--prerelease)
  fi
  if [ "${latest_mode}" = "true" ]; then
    create_args+=(--latest)
  elif [ "${latest_mode}" = "false" ]; then
    create_args+=(--latest=false)
  fi
  gh release create "${target_tag}" "${create_args[@]}"
fi

gh release download "${source_tag}" \
  --repo "${source_repo}" \
  --dir "${tmp_dir}" \
  --clobber \
  --pattern '*'

for asset_name in "${asset_names[@]}"; do
  asset_path="${tmp_dir}/${asset_name}"
  if [ ! -f "${asset_path}" ]; then
    echo "Skipping missing downloaded asset: ${asset_name}" >&2
    continue
  fi

  if gh release view "${target_tag}" --repo "${target_repo}" --json assets --jq '.assets[].name' | grep -Fxq "${asset_name}"; then
    gh release delete-asset "${target_tag}" "${asset_name}" --repo "${target_repo}" --yes
  fi

  gh release upload "${target_tag}" "${asset_path}" --repo "${target_repo}" --clobber
done

echo "Synced ${#asset_names[@]} asset(s) from ${source_repo}@${source_tag} to ${target_repo}@${target_tag}."
