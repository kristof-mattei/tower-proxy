#!/bin/bash

set -euo pipefail

# Configuration
org=""
user=""
package_name="package"
per_page=100
max_attempts=3
dry_run=false
skip_confirmation=false
cleanup_pr_images=true
pr_image_age_days=30
untagged_grace_days=1

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --org)
            if [[ -n "$user" ]]; then
                echo "Error: --org and --user are mutually exclusive" >&2
                exit 1
            fi
            org="$2"
            shift 2
            ;;
        --user)
            if [[ -n "$org" ]]; then
                echo "Error: --org and --user are mutually exclusive" >&2
                exit 1
            fi
            user="$2"
            shift 2
            ;;
        --package)
            package_name="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --yes)
            skip_confirmation=true
            shift
            ;;
        --skip-pr-cleanup)
            cleanup_pr_images=false
            shift
            ;;
        --pr-age-days)
            pr_image_age_days="$2"
            shift 2
            ;;
        --untagged-grace-days)
            untagged_grace_days="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--org ORG | --user USER] [--package PACKAGE_NAME] [--dry-run] [--yes] [--skip-pr-cleanup] [--pr-age-days DAYS] [--untagged-grace-days DAYS] [--help]"
            echo "  --org                   GitHub organization name"
            echo "  --user                  GitHub username"
            echo "  --package               Package name (default: $package_name)"
            echo "  --dry-run               Show what would be deleted without actually deleting"
            echo "  --yes                   Skip confirmation prompt"
            echo "  --skip-pr-cleanup       Skip cleanup of old PR images"
            echo "  --pr-age-days           Age in days for PR images to be considered old (default: $pr_image_age_days)"
            echo "  --untagged-grace-days   Age in days before untagged versions are deleted (default: $untagged_grace_days)"
            echo "  --help                  Show this help message"
            echo ""
            echo "Note: --org and --user are mutually exclusive. One must be specified."
            echo "Note: Images with the 'edge' or 'latest' tag, or a release tag (vX.Y.Z), will never be deleted."
            echo "Note: Platform-specific images referenced by protected multi-platform manifests will not be deleted."
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Validate that either --org or --user is specified
if [[ -z "$org" && -z "$user" ]]; then
    echo "Error: Either --org or --user must be specified" >&2
    exit 1
fi

# Set the target and API path based on whether we're using org or user
if [[ -n "$org" ]]; then
    target="$org"
    api_path="/orgs/$org"
else
    target="$user"
    api_path="/users/$user"
fi

# Docker references must be lowercase
registry_base="ghcr.io/${target,,}/${package_name,,}"

# Check if gh CLI is installed and authenticated
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed" >&2
    exit 1
fi

if ! gh auth status &> /dev/null; then
    echo "Error: Not authenticated with GitHub CLI. Run 'gh auth login' first." >&2
    exit 1
fi

# Check for delete:packages scope
# auth_scopes=$(gh auth status 2>&1)
# if ! echo "$auth_scopes" | grep --quiet --extended-regexp "(delete:packages|write:packages)"; then
#     echo "Error: GitHub token lacks required scope. Need 'delete:packages' or 'write:packages'." >&2
#     echo "       Run 'gh auth refresh --scopes delete:packages' to add the scope." >&2
#     exit 1
# fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed" >&2
    exit 1
fi

# Check if skopeo or docker is available for manifest inspection
# Without manifest inspection every untagged platform-specific image looks orphaned, so refuse to run
manifest_tool=""
if command -v skopeo &> /dev/null; then
    manifest_tool="skopeo"
elif command -v docker &> /dev/null; then
    manifest_tool="docker"
else
    echo "Error: Neither 'skopeo' nor 'docker' found. Cannot inspect multi-platform manifests, refusing to delete anything." >&2
    exit 1
fi

# ========== UTILITY FUNCTIONS ==========

# Run gh api, retrying transient failures with backoff
# Only emits stdout of the last attempt, so partial output of failed attempts is discarded
gh_api() {
    local attempt output
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if output=$(gh api "$@"); then
            printf '%s' "$output"
            return 0
        fi

        if [[ "$attempt" -lt "$max_attempts" ]]; then
            echo "Warning: gh api call failed (attempt $attempt of $max_attempts), retrying in $((attempt * 2))s..." >&2
            sleep $((attempt * 2))
        fi
    done

    printf '%s' "$output"
    return 1
}

# Get versions for a specific page
get_versions_page() {
    local page=$1
    gh_api \
        --header "Accept: application/vnd.github+json" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        "$api_path/packages/container/$package_name/versions?per_page=$per_page&page=$page"
}

# Delete a version
delete_version() {
    local version_id=$1
    local description="$2"

    if [[ "$dry_run" == "true" ]]; then
        echo "[DRY RUN] Would delete version ID: $version_id ($description)"
        return 0
    fi

    echo "Deleting version ID: $version_id ($description)"
    if gh_api \
        --method DELETE \
        --header "Accept: application/vnd.github+json" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        "$api_path/packages/container/$package_name/versions/$version_id" 2> /dev/null; then
        echo "Successfully deleted version ID: $version_id"
        return 0
    else
        echo "Failed to delete version ID: $version_id" >&2
        return 1
    fi
}

# Check if a date is older than specified days
is_older_than_days() {
    local date_str="$1"
    local days="$2"

    local date_epoch
    if ! date_epoch=$(date --date "$date_str" +%s 2> /dev/null); then
        echo "Warning: Could not parse date: $date_str" >&2
        return 1
    fi

    local cutoff_epoch=$(($(date +%s) - (days * 24 * 60 * 60)))
    [[ $date_epoch -lt $cutoff_epoch ]]
}

# Tag pattern checks
has_pr_latest_tag() {
    local tags_json="$1"
    echo "$tags_json" | jq --exit-status '.[] | select(test("^pr-.*-latest$"))' > /dev/null 2>&1
}

has_pr_sha_tag() {
    local tags_json="$1"
    echo "$tags_json" | jq --exit-status '.[] | select(test("^pr-[a-f0-9]{40}-[a-f0-9]{40}(-[a-zA-Z0-9_-]+)?$"))' > /dev/null 2>&1
}

has_edge_tag() {
    local tags_json="$1"
    echo "$tags_json" | jq --exit-status '.[] | select(. == "edge")' > /dev/null 2>&1
}

has_latest_tag() {
    local tags_json="$1"
    echo "$tags_json" | jq --exit-status '.[] | select(. == "latest")' > /dev/null 2>&1
}

has_release_tag() {
    local tags_json="$1"
    echo "$tags_json" | jq --exit-status '.[] | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+(-(alpha|beta|rc)\\.[0-9]+)?$"))' > /dev/null 2>&1
}

has_attestation_tag() {
    local tags_json="$1"
    echo "$tags_json" | jq --exit-status '.[] | select(test("^sha256-[a-f0-9]{64}$"))' > /dev/null 2>&1
}

extract_sha256_from_attestation() {
    local tags_json="$1"
    echo "$tags_json" | jq --raw-output '.[] | select(test("^sha256-[a-f0-9]{64}$")) | sub("^sha256-"; "")'
}

# Get the first available tag for manifest inspection
get_first_tag() {
    local tags_json="$1"
    echo "$tags_json" | jq --raw-output '.[0] // empty'
}

# Fetch the raw manifest, retrying transient registry failures with backoff
# skopeo's --retry-times does not retry a bare 500, so retry at the shell level too
fetch_manifest() {
    local image_ref="$1"
    local attempt output rc

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        rc=0
        if [[ "$manifest_tool" == "skopeo" ]]; then
            output=$(skopeo inspect --raw --command-timeout 70s --retry-times 5 "docker://${image_ref}") || rc=$?
        else
            output=$(docker buildx imagetools inspect --raw "$image_ref") || rc=$?
        fi

        if [[ "$rc" -eq 0 ]]; then
            printf '%s' "$output"
            return 0
        fi

        if [[ "$attempt" -lt "$max_attempts" ]]; then
            echo "Warning: manifest inspection of $image_ref failed (attempt $attempt of $max_attempts), retrying in $((attempt * 2))s..." >&2
            sleep $((attempt * 2))
        fi
    done

    return 1
}

# Fetch manifest and extract referenced digests (for multi-platform images)
# Returns newline-separated list of sha256 digests (without 'sha256:' prefix)
# Fails when the manifest cannot be fetched, an empty result only means "not an index"
get_referenced_digests() {
    local image_ref="$1"

    local manifest=""
    manifest=$(fetch_manifest "$image_ref") || return 1

    if [[ -z "$manifest" ]]; then
        return 1
    fi

    if echo "$manifest" | jq --exit-status '.manifests' > /dev/null 2>&1; then
        echo "$manifest" | jq --raw-output '.manifests[].digest // empty' | sed 's/^sha256://'
    fi
}

# Protect every digest referenced by the manifest of the version's first tag
# An uninspectable manifest aborts the run: treating it as "no children" would delete live platform-specific images
protect_referenced_digests() {
    local tags_json="$1"
    local first_tag ref_digest ref_digests

    first_tag=$(get_first_tag "$tags_json")
    if [[ -z "$first_tag" ]]; then
        return 0
    fi

    echo "Inspecting manifest for protected image: $registry_base:$first_tag"

    if ! ref_digests=$(get_referenced_digests "$registry_base:$first_tag"); then
        echo "Error: Failed to inspect manifest for $registry_base:$first_tag, refusing to delete anything" >&2
        exit 1
    fi

    while IFS= read -r ref_digest; do
        [[ -z "$ref_digest" ]] && continue
        echo "  Protected platform-specific digest: ${ref_digest:0:12}..."
        protected_digests["$ref_digest"]="referenced by $first_tag manifest"
    done <<< "$ref_digests"
}

# ========== PHASE 1: COLLECT ALL VERSION DATA ==========

echo "Querying container versions for $target, package $package_name..."

# Associative arrays for version data
declare -A version_tags=()      # version_id -> tags JSON
declare -A version_digest=()    # version_id -> sha256 digest (without prefix)
declare -A version_created=()   # version_id -> created_at timestamp
declare -A digest_to_version=() # sha256 digest -> version_id

# Arrays for tracking
all_version_ids=()

page=1
while true; do
    echo "Fetching page $page..."

    response=$(get_versions_page $page)

    if [[ -z "$response" ]]; then
        break
    fi

    if echo "$response" | jq --exit-status '.message' > /dev/null 2>&1; then
        echo "Error: $(echo "$response" | jq --raw-output '.message')" >&2
        exit 1
    fi

    version_count=$(echo "$response" | jq '. | length')
    if [[ "$version_count" -eq 0 ]]; then
        break
    fi

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue

        version_id=$(echo "$version" | jq --raw-output '.id')
        tags=$(echo "$version" | jq --compact-output '.metadata.container.tags')
        created_at=$(echo "$version" | jq --raw-output '.created_at')
        name=$(echo "$version" | jq --raw-output '.name // empty')

        all_version_ids+=("$version_id")
        version_tags["$version_id"]="$tags"
        version_created["$version_id"]="$created_at"

        # Extract digest from name (format: sha256:xxx)
        if [[ "$name" =~ ^sha256:([a-f0-9]{64})$ ]]; then
            digest="${BASH_REMATCH[1]}"
            version_digest["$version_id"]="$digest"
            digest_to_version["$digest"]="$version_id"
        fi
    done <<< "$(echo "$response" | jq --compact-output '.[]')"

    if [[ "$version_count" -lt "$per_page" ]]; then
        break
    fi

    ((page++))
done

echo "Found ${#all_version_ids[@]} total versions"

# ========== PHASE 2: DETERMINE PROTECTED VERSIONS ==========

echo ""
echo "=== PHASE 2: DETERMINING PROTECTED VERSIONS ==="

# Protected digests: sha256 hashes that must not be deleted
declare -A protected_digests=() # sha256 -> reason

# Track versions by category
declare -A protected_versions=() # version_id -> reason
declare -A delete_candidates=()  # version_id -> reason

for version_id in "${all_version_ids[@]}"; do
    tags="${version_tags[$version_id]}"
    created_at="${version_created[$version_id]}"
    digest="${version_digest[$version_id]:-}"

    # Check for permanently protected tags
    # A release tag is added to the version the PR built, next to its pr-* tags, so the old PR rule below would delete released images
    if has_edge_tag "$tags" || has_latest_tag "$tags" || has_release_tag "$tags"; then
        protected_versions["$version_id"]="has edge/latest/release tag"

        if [[ -n "$digest" ]]; then
            protected_digests["$digest"]="referenced by edge/latest/release tagged image"
        fi

        # Fetch manifest to protect referenced platform-specific images
        protect_referenced_digests "$tags"
        continue
    fi

    # Check for attestations - handle separately later
    if has_attestation_tag "$tags"; then
        continue
    fi

    # Check for untagged versions
    # A concurrent push uploads child manifests before the tagged index, so
    # recent untagged versions may belong to an image that is still being pushed
    if echo "$tags" | jq --exit-status '. == []' > /dev/null 2>&1; then
        if is_older_than_days "$created_at" "$untagged_grace_days"; then
            delete_candidates["$version_id"]="untagged"
        else
            protected_versions["$version_id"]="untagged, younger than $untagged_grace_days day(s)"
        fi
        continue
    fi

    # Check for old PR images
    if [[ "$cleanup_pr_images" == "true" ]]; then
        if is_older_than_days "$created_at" "$pr_image_age_days"; then
            tags_str=$(echo "$tags" | jq --raw-output '.[]' | tr '\n' ',' | sed 's/,$//')

            if has_pr_latest_tag "$tags"; then
                delete_candidates["$version_id"]="old PR latest ($created_at) [$tags_str]"
                continue
            fi

            if has_pr_sha_tag "$tags"; then
                delete_candidates["$version_id"]="old PR SHA ($created_at) [$tags_str]"
                continue
            fi
        fi
    fi

    # Not a delete candidate, protect everything its manifest references
    # Unconditionally: gating on delete_candidates would make protection depend on API return order
    protect_referenced_digests "$tags"
done

# ========== PHASE 3: FILTER DELETE CANDIDATES ==========

echo ""
echo "=== PHASE 3: FILTERING DELETE CANDIDATES ==="

# Remove from delete candidates any version whose digest is protected
final_delete_versions=()
final_delete_reasons=()

# Sort delete candidate keys for consistent output
# printf emits one empty line for an empty array, which mapfile would turn into a bogus entry
sorted_candidates=()
if ((${#delete_candidates[@]} > 0)); then
    mapfile -t sorted_candidates < <(printf '%s\n' "${!delete_candidates[@]}" | sort --numeric-sort)
fi

for version_id in "${sorted_candidates[@]}"; do
    digest="${version_digest[$version_id]:-}"
    reason="${delete_candidates[$version_id]}"

    if [[ -n "$digest" && -n "${protected_digests[$digest]:-}" ]]; then
        echo "Skipping $version_id ($reason): ${protected_digests[$digest]}"
        protected_versions["$version_id"]="platform-specific image: ${protected_digests[$digest]}"
        continue
    fi

    final_delete_versions+=("$version_id")
    final_delete_reasons+=("$reason")
done

# ========== PHASE 4: HANDLE ATTESTATIONS ==========

echo ""
echo "=== PHASE 4: CHECKING ATTESTATIONS ==="

orphaned_attestations=()
orphaned_attestation_reasons=()

for version_id in "${all_version_ids[@]}"; do
    tags="${version_tags[$version_id]}"

    if ! has_attestation_tag "$tags"; then
        continue
    fi

    attestation_sha=$(extract_sha256_from_attestation "$tags")
    [[ -z "$attestation_sha" ]] && continue

    # Check if the referenced image exists and is not being deleted
    ref_version_id="${digest_to_version[$attestation_sha]:-}"

    if [[ -z "$ref_version_id" ]]; then
        # Referenced image doesn't exist at all
        orphaned_attestations+=("$version_id")
        orphaned_attestation_reasons+=("attestation for non-existent sha256:${attestation_sha:0:12}...")
    else
        # Check if referenced image is being deleted
        for i in "${!final_delete_versions[@]}"; do
            if [[ "${final_delete_versions[$i]}" == "$ref_version_id" ]]; then
                orphaned_attestations+=("$version_id")
                orphaned_attestation_reasons+=("attestation for deleted sha256:${attestation_sha:0:12}...")
                break
            fi
        done
    fi
done

# ========== PHASE 5: SUMMARY AND CONFIRMATION ==========

echo ""
echo "=========================================="
echo "           CLEANUP SUMMARY"
echo "=========================================="
echo ""
echo "Protected versions:        ${#protected_versions[@]}"
echo "Versions to delete:        ${#final_delete_versions[@]}"
echo "Orphaned attestations:     ${#orphaned_attestations[@]}"
echo ""

total_to_delete=$((${#final_delete_versions[@]} + ${#orphaned_attestations[@]}))

if [[ ${#final_delete_versions[@]} -gt 0 ]]; then
    echo "--- Versions to delete ---"
    for i in "${!final_delete_versions[@]}"; do
        echo "  ${final_delete_versions[$i]}: ${final_delete_reasons[$i]}"
    done
    echo ""
fi

if [[ ${#orphaned_attestations[@]} -gt 0 ]]; then
    echo "--- Orphaned attestations to delete ---"
    for i in "${!orphaned_attestations[@]}"; do
        echo "  ${orphaned_attestations[$i]}: ${orphaned_attestation_reasons[$i]}"
    done
    echo ""
fi

if [[ $total_to_delete -eq 0 ]]; then
    echo "No versions to delete."
    exit 0
fi

if [[ "$dry_run" == "true" ]]; then
    echo "[DRY RUN] Would delete $total_to_delete versions total"
fi

# ========== PHASE 6: DELETION ==========

if [[ "$dry_run" == "false" && "$skip_confirmation" == "false" ]]; then
    echo ""
    read -p "Are you sure you want to delete $total_to_delete versions? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deletion cancelled."
        exit 0
    fi
fi

echo ""
echo "=== STARTING DELETION ==="

deleted_count=0
failed_count=0
current=0

# Delete regular versions first
for i in "${!final_delete_versions[@]}"; do
    ((++current))
    echo "[$current/$total_to_delete] Deleting version ${final_delete_versions[$i]}..."
    if delete_version "${final_delete_versions[$i]}" "${final_delete_reasons[$i]}"; then
        ((++deleted_count)) || true
    else
        ((++failed_count)) || true
    fi
done

# Delete orphaned attestations
for i in "${!orphaned_attestations[@]}"; do
    ((++current))
    echo "[$current/$total_to_delete] Deleting attestation ${orphaned_attestations[$i]}..."
    if delete_version "${orphaned_attestations[$i]}" "${orphaned_attestation_reasons[$i]}"; then
        ((++deleted_count)) || true
    else
        ((++failed_count)) || true
    fi
done

# ========== FINAL SUMMARY ==========

echo ""
echo "=========================================="
echo "           CLEANUP COMPLETE"
echo "=========================================="
if [[ "$dry_run" == "false" ]]; then
    echo "Successfully deleted: $deleted_count"
    if [[ $failed_count -gt 0 ]]; then
        echo "Failed to delete:     $failed_count"
    fi
else
    echo "[DRY RUN] Would have deleted $total_to_delete versions"
fi
