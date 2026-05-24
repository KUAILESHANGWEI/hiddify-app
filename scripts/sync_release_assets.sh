#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 <source-owner/repo> <source-tag|latest> [target-owner/repo] [target-tag]" >&2
  exit 2
fi

source_repo="$1"
source_ref="$2"
target_repo="${3:-${GITHUB_REPOSITORY:-KUAILESHANGWEI/hiddify-app}}"
target_tag="${4:-}"

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
