#!/usr/bin/env bash

set -euo pipefail

PR_LIST_FILE="prs_to_migrate.txt" # TODO Add a file with this name containing PR numbers to migrate
OLD_REPO_PATH="Paper-old"
TEMP_DIR="temp"
OUTPUT_DIR="output"

# Initial clone of Paper to be copied from
if [ ! -d "$OLD_REPO_PATH" ]; then
    git clone https://github.com/PaperMC/Paper-archive.git -b ver/1.21.4 "$OLD_REPO_PATH"
else
    echo "Directory $OLD_REPO_PATH already exists. Skipping clone."
fi

cleanup() {
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

mkdir -p "$OUTPUT_DIR"

get_pr_base_commit() {
    local pr_number=$1
    local work_dir=$2

    # Get merge base between PR head and base branch
    cd "${work_dir}/pr"
    local merge_base
    merge_base=$(git merge-base HEAD "origin/ver/1.21.4")
    cd - > /dev/null
    echo "$merge_base"
}

apply_patches() {
    local repo_dir=$1
    echo "Applying patches in $repo_dir..."

    # We don't trust Gradle
    cd "$repo_dir"
    ./gradlew --stop
    ./gradlew applyPatches --no-daemon

    if [ $? -ne 0 ]; then
        echo "Failed to apply patches in $repo_dir"
        return 1
    fi
    cd - > /dev/null
}

# Get applied source diff
extract_source_diff() {
    local base_dir=$1
    local pr_dir=$2
    local output_file=$3

    local api_diff="${pr_dir}/api.diff"
    local server_diff="${pr_dir}/server.diff"

    # Compare Paper-API sources
    diff -Nur \
        "${base_dir}/Paper-API/src/main/java/" \
        "${pr_dir}/Paper-API/src/main/java/" \
        > "$api_diff" || true

    # Compare Paper-Server sources
    diff -Nur \
        "${base_dir}/Paper-Server/src/main/java/" \
        "${pr_dir}/Paper-Server/src/main/java/" \
        > "$server_diff" || true

    # Combine diffs and process paths
    {
        sed 's|Paper-API/src/main/java|paper-api/src/main/java|g' "$api_diff"
        sed -E '
            # If path contains net/minecraft or com/mojang, use vanilla path
            /(net\/minecraft|com\/mojang)/ s|Paper-Server/src/main/java|paper-server/src/vanilla/java|g
            # Otherwise use regular java path
            /(net\/minecraft|com\/mojang)/ !s|Paper-Server/src/main/java|paper-server/src/main/java|g
        ' "$server_diff"
    } > "$output_file"
}

main() {
    if [ ! -f "$PR_LIST_FILE" ]; then
        echo "Error: PR list file not found at $PR_LIST_FILE"
        exit 1
    fi

    echo "Starting migration process..."

    # Process each PR
    while read -r pr_number || [ -n "$pr_number" ]; do
        echo "Processing PR #${pr_number}..."
        local work_dir="${TEMP_DIR}/pr_${pr_number}"
        mkdir -p "$work_dir"

        # Clone repositories
        git clone "$OLD_REPO_PATH" "${work_dir}/base"
        git clone "$OLD_REPO_PATH" "${work_dir}/pr"

        # Setup PR version first (needed to find base commit)
        cd "${work_dir}/pr"
        git remote set-url origin git@github.com:PaperMC/Paper.git
        gh pr checkout "$pr_number"
        cd - > /dev/null

        # Get base commit of the PR
        local base_commit
        base_commit=$(get_pr_base_commit "$pr_number" "$work_dir")
        echo "PR #${pr_number} base commit: ${base_commit}"

        # Setup base version at the correct commit
        cd "${work_dir}/base"
        git checkout "$base_commit"
        cd - > /dev/null

        # Apply Gradle patches to both versions
        apply_patches "${work_dir}/base"
        apply_patches "${work_dir}/pr"

        # Extract source differences
        local diff_file="${OUTPUT_DIR}/pr-${pr_number}.patch"
        extract_source_diff "${work_dir}/base" "${work_dir}/pr" "$diff_file"
        if [ -s "$diff_file" ]; then
            echo "Created patch for PR #${pr_number}"
        else
            echo "No changes found for PR #${pr_number}"
        fi

    done < "$PR_LIST_FILE"

    echo "Update process complete. Copy paste the contents of the output/pr-x/changes.patch file, then open IntelliJ and use the 'Apply Patch From Clipboard' action (you can search for it via Ctrl+Shift+A). Resolve conflicts and make sure everything applied correctly."
}

main "$@"
