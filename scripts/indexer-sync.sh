#!/bin/bash

# Script to keep Prowlarr/Indexers up to date with Jackett/Jackett
# Created by Bakerboy448

set -e

# Configurable variables
PROWLARR_GIT_PATH="./"
PROWLARR_RELEASE_BRANCH="master"
PROWLARR_REMOTE_NAME="origin"
PROWLARR_REPO_URL="https://github.com/Prowlarr/Indexers"
JACKETT_REPO_URL="https://github.com/Jackett/Jackett"
JACKETT_RELEASE_BRANCH="master"
JACKETT_REMOTE_NAME="z_Jackett"
JACKETT_PULLS_BRANCH="jackett-pulls"
PROWLARR_COMMIT_TEMPLATE="jackett indexers as of"
MIN_SCHEMA=9
MAX_SCHEMA=9
NEW_SCHEMA=$((MAX_SCHEMA + 1))
NEW_VERSION_DIR="definitions/v$NEW_SCHEMA"

# Function to print log with timestamp
log() {
    local message=$1
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $message"
}

# Check for required commands
if ! command -v npx &> /dev/null; then
    log "npx could not be found. Check your Node installation."
    exit 1
fi

if ! npm list --depth=0 ajv-cli-servarr &> /dev/null || ! npm list --depth=0 ajv-formats &> /dev/null; then
    log "Required npm packages are missing. Run 'npm install'."
    exit 2
fi

# Enhanced Logging
DEBUG=false
TRACE=false
SKIP_UPSTREAM=false

case $1 in
    debug)
        DEBUG=true
        log "Debug logging enabled"
        ;;
    trace)
        DEBUG=true
        TRACE=true
        log "Trace logging enabled"
        ;;
    dev)
        SKIP_UPSTREAM=true
        log "Skipping upstream Prowlarr pull, local only"
        ;;
esac

# Switch to Prowlarr directory
cd "$PROWLARR_GIT_PATH" || exit

# Configure Git and remotes
git config advice.statusHints false

if ! git remote get-url "$PROWLARR_REMOTE_NAME" &> /dev/null; then
    git remote add "$PROWLARR_REMOTE_NAME" "$PROWLARR_REPO_URL"
fi

if ! git remote get-url "$JACKETT_REMOTE_NAME" &> /dev/null; then
    git remote add "$JACKETT_REMOTE_NAME" "$JACKETT_REPO_URL"
fi

log "Configured Git"
JACKETT_BRANCH="$JACKETT_REMOTE_NAME/$JACKETT_RELEASE_BRANCH"
log "Fetching and pruning repos"
git fetch --all --prune --progress

# Check if jackett-pulls branch exists (remote and local)
REMOTE_PULLS_EXISTS=$(git ls-remote --heads "$PROWLARR_REMOTE_NAME" "$JACKETT_PULLS_BRANCH")
LOCAL_PULLS_EXISTS=$(git branch --list "$JACKETT_PULLS_BRANCH")

if [ -n "$LOCAL_PULLS_EXISTS" ]; then
    LOCAL_EXIST=true
    log "Local [$JACKETT_PULLS_BRANCH] exists"
else
    LOCAL_EXIST=false
    log "Local [$JACKETT_PULLS_BRANCH] does not exist"
fi

if [ -n "$REMOTE_PULLS_EXISTS" ]; then
    PULLS_EXISTS=true
    log "Remote [$PROWLARR_REMOTE_NAME/$JACKETT_PULLS_BRANCH] exists"
else
    PULLS_EXISTS=false
    log "Remote [$PROWLARR_REMOTE_NAME/$JACKETT_PULLS_BRANCH] does not exist"
fi

# Checkout or create the jackett-pulls branch
if $PULLS_EXISTS; then
    if $LOCAL_EXIST; then
        if $SKIP_UPSTREAM; then
            log "Skipping checkout of local branch [$JACKETT_PULLS_BRANCH]"
        else
            git reset --hard "$PROWLARR_REMOTE_NAME/$JACKETT_PULLS_BRANCH"
            log "Local [$JACKETT_PULLS_BRANCH] reset to remote"
        fi
        git checkout -B "$JACKETT_PULLS_BRANCH"
    else
        git checkout -B "$JACKETT_PULLS_BRANCH" "$PROWLARR_REMOTE_NAME/$JACKETT_PULLS_BRANCH"
        log "Local [$JACKETT_PULLS_BRANCH] created from remote"
    fi
else
    if $LOCAL_EXIST; then
        git reset --hard "$PROWLARR_REMOTE_NAME/$PROWLARR_RELEASE_BRANCH"
        log "Local [$JACKETT_PULLS_BRANCH] reset to [$PROWLARR_REMOTE_NAME/$PROWLARR_RELEASE_BRANCH]"
        git checkout -B "$JACKETT_PULLS_BRANCH"
    else
        git checkout -B "$JACKETT_PULLS_BRANCH" "$PROWLARR_REMOTE_NAME/$PROWLARR_RELEASE_BRANCH" --no-track
        log "Local [$JACKETT_PULLS_BRANCH] created from [$PROWLARR_REMOTE_NAME/$PROWLARR_RELEASE_BRANCH]"
    fi
fi

log "Branch setup complete"

# Review commits
EXISTING_MESSAGE=$(git log --format=%B -n1)
EXISTING_MESSAGE_LN1=$(echo "$EXISTING_MESSAGE" | awk 'NR==1')
PROWLARR_COMMITS=$(git log --format=%B -n1 -n 20 | grep "^$PROWLARR_COMMIT_TEMPLATE")
PROWLARR_JACKETT_COMMIT_MESSAGE=$(echo "$PROWLARR_COMMITS" | awk 'NR==1')
JACKETT_RECENT_COMMIT=$(git rev-parse "$JACKETT_BRANCH")
log "Most recent Jackett commit: [$JACKETT_RECENT_COMMIT] from [$JACKETT_BRANCH]"
RECENT_PULLED_COMMIT=$(echo "$PROWLARR_COMMITS" | awk 'NR==1{print $5}')
log "Most recent Prowlarr Jackett commit: [$RECENT_PULLED_COMMIT] from [$PROWLARR_REMOTE_NAME/$JACKETT_PULLS_BRANCH]"

if [ "$JACKETT_RECENT_COMMIT" = "$RECENT_PULLED_COMMIT" ]; then
    log "We are current with Jackett; nothing to do"
    exit 0
fi

if [ -z "$RECENT_PULLED_COMMIT" ]; then
    log "Error: Recent Pulled Commit is empty. Exiting."
    exit 3
fi

# Pull commits between the most recent pull and Jackett's latest commit
COMMIT_RANGE=$(git log --reverse --pretty="%n%H" "$RECENT_PULLED_COMMIT".."$JACKETT_RECENT_COMMIT")
COMMIT_COUNT=$(git rev-list --count "$RECENT_PULLED_COMMIT".."$JACKETT_RECENT_COMMIT")
log "Commit Range: [$COMMIT_RANGE]"
log "$COMMIT_COUNT commits to cherry-pick"
log "Starting cherry-picking"

git config merge.directoryRenames true
git config merge.verbosity 0

for PICK_COMMIT in $COMMIT_RANGE; do
    if git ls-files --unmerged &> /dev/null; then
        log "Conflicts detected. Resolve and press any key to continue."
        read -n1 -s
    fi
    log "Cherry-picking [$PICK_COMMIT]"
    git cherry-pick --no-commit --rerere-autoupdate --allow-empty --keep-redundant-commits "$PICK_COMMIT"
    if $TRACE; then
        log "Cherry-picked $PICK_COMMIT"
        log "Checking conflicts"
        read -n1 -s
    fi
    if git ls-files --unmerged &> /dev/null; then
        handle_conflicts
    fi
    git config merge.directoryRenames conflict
    git config merge.verbosity 2
done

log "Cherry-picking complete"
log "Evaluating and reviewing changes"

# TODO: find a better way to ignore schema.json changes from Jackett
git checkout HEAD -- "definitions/v*/schema.json"

handle_indexers() {
    local indexers=$1
    local action=$2
    if [ -n "$indexers" ]; then
        log "$action Indexers detected"
        for indexer in $indexers; do
            log "Evaluating [$indexer] Cardigann Version"
            if [ -f "$indexer" ]; then
                determine_schema_version "$indexer"
                if [ "$CHECK_VERSION" != "v0" ]; then
                    log "Schema Test passed."
                    UPDATED_INDEXER=$indexer
                else
                    log "Schema Test failed. Determining version"
                    determine_best_schema_version "$indexer"
                    if [ "$MATCHED_VERSION" -eq 0 ]; then
                        log "Version [$NEW_SCHEMA] required. Review definition [$indexer]"
                        V_MATCHED="v$NEW_SCHEMA"
                    else
                        V_MATCHED="v$MATCHED_VERSION"
                    fi
                    UPDATED_INDEXER=${indexer/v[0-9]/$V_MATCHED}
                    if [ "$indexer" != "$UPDATED_INDEXER" ]; then
                        log "Moving indexer from [$indexer] to [$UPDATED_INDEXER]"
                        mv "$indexer" "$UPDATED_INDEXER"
                        git rm -f "$indexer"
                        git add -f "$UPDATED_INDEXER"
                    else
                        log "Doing nothing; [$indexer] already is [$UPDATED_INDEXER]"
                    fi
                fi
            fi
        done
        unset indexer
        unset test
    fi
}

# Handle added, modified, and removed indexers
ADDED_INDEXERS=$(

git diff --cached --diff-filter=A --name-only | grep ".yml" | grep "v[$MIN_SCHEMA-$MAX_SCHEMA]")
MODIFIED_INDEXERS=$(git diff --cached --diff-filter=M --name-only | grep ".yml" | grep "v[$MIN_SCHEMA-$MAX_SCHEMA]")
REMOVED_INDEXERS=$(git diff --cached --diff-filter=D --name-only | grep ".yml" | grep "v[$MIN_SCHEMA-$MAX_SCHEMA]")

handle_indexers "$ADDED_INDEXERS" "Added"
handle_indexers "$MODIFIED_INDEXERS" "Modified"

log "Indexer handling complete"

# Backport indexers
log "Starting indexer backporting"

backport_indexers() {
    local indexers=$1
    for indexer in $indexers; do
        for ((i = MAX_SCHEMA; i >= MIN_SCHEMA; i--)); do
            version="v$i"
            log "Looking for [$version] indexer of [$indexer]"
            indexer_check=${indexer/v[0-9]/$version}
            if [ "$indexer_check" != "$indexer" ] && [ -f "$indexer_check" ]; then
                log "Found [v$i] indexer for [$indexer] - comparing to [$indexer_check]"
                if $DEBUG; then
                    log "Pausing for debugging"
                    read -n1 -s
                fi
                log "Review this change and ensure no incompatible updates are backported."
                git difftool --no-index "$indexer" "$indexer_check"
                git add "$indexer_check"
            fi
        done
    done
}

MODIFIED_INDEXERS_VCHECK=$(git diff --cached --diff-filter=AM --name-only | grep ".yml" | grep "v[$MIN_SCHEMA-$MAX_SCHEMA]")
backport_indexers "$MODIFIED_INDEXERS_VCHECK"

NEW_SCHEMA_INDEXERS=$(git diff --cached --diff-filter=A --name-only | grep ".yml" | grep "v$NEW_SCHEMA")
backport_indexers "$NEW_SCHEMA_INDEXERS"

log "Indexer backporting complete"

# Handle removed indexers
log "Starting removal of indexers"

remove_indexers() {
    local indexers=$1
    for indexer in $indexers; do
        log "Looking for previous versions of removed indexer [$indexer]"
        for ((i = MAX_SCHEMA; i >= MIN_SCHEMA; i--)); do
            indexer_remove=${indexer/v[0-9]/v$i}
            if [ "$indexer_remove" != "$indexer" ] && [ -f "$indexer_remove" ]; then
                log "Found [v$i] indexer for [$indexer] - removing [$indexer_remove]"
                if $DEBUG; then
                    log "Pausing for debugging"
                    read -n1 -s
                fi
                rm -f "$indexer_remove"
                git rm --f --ignore-unmatch "$indexer_remove"
            fi
        done
    done
}

remove_indexers "$REMOVED_INDEXERS"

log "Indexer removal complete"

log "Added Indexers: $ADDED_INDEXERS"
log "Modified Indexers: $MODIFIED_INDEXERS"
log "Removed Indexers: $REMOVED_INDEXERS"
log "New Schema Indexers: $NEW_SCHEMA_INDEXERS"

# Cleanup new version folder if unused
if [ -d "$NEW_VERSION_DIR" ]; then
    if [ "$(ls -A $NEW_VERSION_DIR)" ]; then
        log "WARNING: New Cardigann version required: Version [v$NEW_SCHEMA] needed. Review the following definitions for new Cardigann Version: $NEW_SCHEMA_INDEXERS"
    else
        rmdir "$NEW_VERSION_DIR"
    fi
fi

git rm -r -f -q --ignore-unmatch --cached node_modules

# Wait for user interaction to handle any conflicts and review
log "After review, the script will commit the changes."
read -p "Press any key to continue or [Ctrl+C] to abort. Waiting for human review..." -n1 -s
NEW_COMMIT_MSG="$PROWLARR_COMMIT_TEMPLATE $JACKETT_RECENT_COMMIT"

if $PULLS_EXISTS; then
    if $DEBUG; then
        log "Existing commit message line 1: [$EXISTING_MESSAGE_LN1]"
        log "Jackett Commit Message: [$PROWLARR_JACKETT_COMMIT_MESSAGE]"
        log "Pausing for debugging"
        read -n1 -s
    fi
    if [ "$EXISTING_MESSAGE_LN1" = "$PROWLARR_JACKETT_COMMIT_MESSAGE" ]; then
        git commit --amend -m "$NEW_COMMIT_MSG" -m "$EXISTING_MESSAGE"
        log "Commit appended: [$NEW_COMMIT_MSG]"
    else
        git commit -m "$NEW_COMMIT_MSG"
        log "New commit made: [$NEW_COMMIT_MSG]"
    fi
else
    git commit -m "$NEW_COMMIT_MSG"
    log "New commit made: [$NEW_COMMIT_MSG]"
fi

while true; do
    read -p "Do you wish to Force Push with Lease [Ff] or Push to $PROWLARR_REMOTE_NAME [Pp]? Enter any other value to exit: " -n1 FP
    case $FP in
        [Ff]*)
            if $DEBUG; then
                log "Pausing for debugging"
                read -n1 -s
            fi
            git push "$PROWLARR_REMOTE_NAME" "$JACKETT_PULLS_BRANCH" --force-if-includes --force-with-lease
            log "Branch force pushed"
            exit 0
            ;;
        [Pp]*)
            if $DEBUG; then
                log "Pausing for debugging"
                read -n1 -s
            fi
            git push "$PROWLARR_REMOTE_NAME" "$JACKETT_PULLS_BRANCH" --force-if-includes
            log "Branch pushed"
            exit 0
            ;;
        *)
            log "Exiting"
            exit 0
            ;;
    esac
done
