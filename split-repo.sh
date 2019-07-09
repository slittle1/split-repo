#!/bin/bash

#
# Copyright (c) 2018 Wind River Systems, Inc.
#
# SPDX-License-Identifier: Apache-2.0
#

# Extract subtrees from a git repository(s) and move them into a new or
# othe pre-existing repository.
#
# split-repo.sh new-repo.map [branch]
#
# The map file has four parts per line separated by a pipe ('|') character.
# The four fields are:
# 1) Path to the root of the source repository
# 2) Relative path to the subdirectory within the source repository that is
#    to be moved
# 3) Path to the roo of the destination repository. If non-existant, a new repo
#    will be created.
# 4) Relative path under the destination repository where the relocated subtree
#    is to be placed.
#
# e.g.
# cat new-repo.map
# stx/stx-integ|base/centos-release-config|stx/stx-config-files|centos-release-config
# stx/stx-integ|base/dhcp-config|stx/stx-config-files|dhcp-config
# stx/stx-integ|utilities/build-info|stx/stx-utilities|utilities/build-info
# stx/stx-config|pm-qos-mgr|stx/stx-utilities|utilities/pm-qos-mgr
#
# This will create repos stx-config-files and stx-utilities. Subdirectories
# base/centos-release-config and base/dhcp-config are moved from stx-integ into
# stx-config-files, dropping the 'base/' prefix.  Subdirectory utilities/build-info
# is moved from stx-integ to stx-utilities at the same relative path.  Finally
# pm-qos-mgr is moved from stx-config, under the utilities subdirectory of 
# stx-utilities.
#
# This tool uses filter_git_history.sh from OpenStack's oslo.tools library.
# It can be obtained from https://opendev.org/openstack/oslo.tools.git.
# Clone it, and set environment variable OSLO_TOOLS pointing to the top 
# directory of the oslo.tools repo.

# set -x

MAPFILE=${1:-repo.map}
BRANCH=${2:-master}

# Verify oslo.tools is present
OSLO_TOOLS=${OSLO_TOOLS:-""}
OSLO_TOOLS_REPO=https://opendev.org/openstack/oslo.tools.git
OSLO_FILTER_SCRIPT=filter_git_history.sh
OSLO_FILTER_CMD=$(which ${OSLO_FILTER_SCRIPT})
if [[ "$OSLO_FILTER_CMD" == "" ]]; then
    # not found in path
    if [[ -d ${OSLO_TOOLS} && -x ${OSLO_TOOLS}/${OSLO_FILTER_SCRIPT} ]]; then
        # found it!
        OSLO_FILTER_CMD=${OSLO_TOOLS}/${OSLO_FILTER_SCRIPT}
    else
        echo "${OSLO_FILTER_SCRIPT} is not found.  You need to get it and set OSLO_TOOLS to the directory"
        echo "\$ git clone ${OSLO_TOOLS_REPO} oslo.tools"
        echo "\$ export OSLO_TOOLS=$(pwd)/oslo.tools"
        exit 1
    fi
fi

set -e

# Wrapper around oslo.tools/filter_git_history.sh to remove everything
# not in $filter_list, then merge that into the new repo
function filter_repo {
    local src_repo=$1
    local dest_repo=$2
    shift; shift
    local filter_list="$@"

    # initial work is done in <new-repo>/<src-repo>.old_repo
    work_dir=$src_repo.old_repo

    # Source repo changed, batch up the filters for the last one and do it
    if [[ ! -d $dest_repo/$work_dir ]]; then
        # Start with a copy of the source repo as the filter process is destructive
        cp -pr $src_repo $dest_repo/$work_dir

        # Ensure no previous backup exists
        rm -rf $dest_repo/$work_dir/.git/packed_refs $dest_repo/$work_dir/.git/refs/original

        # Filter it
        (
            cd $dest_repo/$work_dir
            git checkout $BRANCH || true
            ${OSLO_TOOLS}/filter_git_history.sh $filter_list
        )
    fi
}

function merge_repo {
    local dest_repo=$1
    shift
    local src_repo_list="$@"

    # Merge the filtered repo into the destination repo
    for src_repo in ${src_repo_list}; do
        work_dir="${src_repo}.old_repo"
        tmp_remote="tmp-${src_repo}"
        merge_from="$tmp_remote/$BRANCH "
        merge_msg="Merge select content originating from repo '$src_repo'"

        extra_args=""
        if [ ${is_virgin[$dest_repo]} -eq 1 ]; then
            extra_args="-s ours"
            is_virgin[$dest_repo]=0
        fi

        (
            cd $dest_repo
            if [ ! -d $work_dir ]; then
                echo "ERROR: merge_repo: missing directory '$dest_repo/$work_dir'"
                exit 1
            fi

            git remote add $tmp_remote $work_dir
            git fetch $tmp_remote
            git merge -m "$merge_msg" $extra_args $merge_from

            tmp_remote="tmp-$src_repo"
            git remote remove $tmp_remote

            rm -rf $work_dir
        )
    done
}

# Loop through source subtrees
declare -A rewrite_list
declare -A filter_list
declare -A src_repo_list
declare -A is_virgin

line=1
error_count=0

#
# Parse map file.  Save data into dictionaries
#
while IFS="|" read src_repo src_path dest_repo dest_path; do
    if [[ "$src_repo" == "#"* ]]; then
        echo "skip comment at line $line"
        line=$((line + 1))
        continue
    fi

    if [ "$src_repo" == "" ] || [ "$dest_repo" == "" ] || \
       [ "$src_path" == "" ] || [ "$dest_path" == "" ]; then
        echo "ERROR: malformed line at line $line of '$MAPFILE'"
        error_count=$((error_count + 1))
        line=$((line + 1))
        continue
    fi

    if [ "${filter_list["$src_repo#$dest_repo"]}" == "" ]; then
        src_repo_list["$dest_repo"]+="$src_repo "
    fi

    filter_list["$src_repo#$dest_repo"]+="$src_path "
    rewrite_list["$dest_repo"]+="s|\t$src_path/|\t$dest_path/|;"
    line=$((line + 1))
done < "$MAPFILE"

if [ $error_count -ne 0 ]; then
    exit 1
fi

if [ ${#src_repo_list[@]} -eq 0 ]; then
    echo "src_repo_list is empty"
    exit 1
fi

#
# Check the data looks good. 
#
for key in "${!filter_list[@]}"; do
    src_repo=${key%#*}
    dest_repo=${key##*#}
    src_path=${filter_list[$key]}

    if [ "$src_repo" == "" ]; then
        echo "Error: No src_repo, skipping key=${key} of filter_list"
        exit 1
    fi

    if [ "$dest_repo" == "" ]; then
        echo "Error: No dest_repo, skipping key=${key} of filter_list"
        exit 1
    fi

    if [ ! -d $src_repo ]; then
        echo "ERROR: directory not found, src_repo='$src_repo'"
        exit 1
    fi

    if [ ! -d ${src_repo}/${src_path} ]; then
ls -al ${src_repo}/${src_path}
        echo "ERROR: directory not found, src_path='$src_path' within src_repo='$src_repo'"
        exit 1
    fi
done

#
# Create destination repos as required.  Then create a
# working direcory(s) under the destination repo which will
# contain a filtered copy of the src_repo(s).
#
for key in "${!filter_list[@]}"; do
    src_repo=${key%#*}
    dest_repo=${key##*#}

    # Set up destination repo
    if [ ! -d $dest_repo ]; then
        echo "Creating destination repo '$dest_repo'"
        mkdir -p $dest_repo
        (
           cd $dest_repo
           git init
        )
        is_virgin[$dest_repo]=1
    else
        is_virgin[$dest_repo]=0
    fi

    echo "Processing moves from '$src_repo' to '$dest_repo'"
    filter_repo $src_repo $dest_repo ${filter_list[$key]}
done

#
# Merge content from the working direcory(s) into the destination repo.
#
for key in "${!src_repo_list[@]}"; do
    dest_repo=${key}

    if [[ "$dest_repo" == "" ]]; then
        echo "Error: No dest_repo, skipping key=${key} of src_repo_list"
        exit 1
    fi

    merge_repo $dest_repo ${src_repo_list[$dest_repo]}
done

#
# Modify paths to reflect what we desire to see in the destination repo.
#
for key in "${!rewrite_list[@]}"; do
    dest_repo=${key}

    if [ "$dest_repo" == "" ]; then
        echo "Error: No dest_repo, skipping key=${key} of rewrite_list"
        exit 1
    fi

    if [ ! -d $dest_repo ]; then
        echo "ERROR: directory not found, dest_repo='$dest_repo'"
        exit 1
    fi

    echo "Processing renames within '$dest_repo'"
    index_filter="
        git ls-files -s | sed '${rewrite_list[$dest_repo]}' | \
        GIT_INDEX_FILE=\$GIT_INDEX_FILE.new \
        git update-index --index-info && mv \$GIT_INDEX_FILE.new \$GIT_INDEX_FILE || true
    "

    # Do the git mv to the final home
    (
        cd $dest_repo; \
        git filter-branch -f --index-filter "$index_filter" HEAD

        # Set the branch name
        git branch -m master $BRANCH || true
    )
done

#
# Remove relocated subdirectories from the source repos.
#
for key in "${!filter_list[@]}"; do
    src_repo=${key%#*}
    dest_repo=${key##*#}
    src_paths=${filter_list[$key]}

    (
        cd $src_repo
        git rm -rf $src_paths
        git commit -m "Subdirectories '$src_paths' relocated to repo '$(basename $dest_repo)'"
    )
done

