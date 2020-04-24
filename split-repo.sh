#!/bin/bash

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

set -x


# Verify oslo.tools is present
OSLO_TOOLS=${OSLO_TOOLS:-""}
OSLO_FILTER_SCRIPT=filter_git_history.sh
OSLO_TOOLS_REPO=https://opendev.org/openstack/oslo.tools.git

if [[ -d ${OSLO_TOOLS} && -x ${OSLO_TOOLS}/${OSLO_FILTER_SCRIPT} ]]; then
    # found it!
    OSLO_FILTER_CMD=${OSLO_TOOLS}/${OSLO_FILTER_SCRIPT}
else
    OSLO_FILTER_CMD=$(which ${OSLO_FILTER_SCRIPT})
    if [[ "$OSLO_FILTER_CMD" == "" ]]; then
        echo "${OSLO_FILTER_SCRIPT} is not found.  You need to get it and set OSLO_TOOLS to the directory"
        echo "\$ git clone ${OSLO_TOOLS_REPO} oslo.tools"
        echo "\$ export OSLO_TOOLS=$(pwd)/oslo.tools"
        exit 1
    fi
fi

set -e

function usage {
    cat >&2 <<EOF
Usage:
    split-repo.sh [options]
        -M, --map-file <file>
                Path to map file.  Default is 'repo.map'
        -n, --new-repo-branch <branch>
                Branch to create for new repos.  Default is 'master'
        -m, --modified-repo-branch <branch>
                Branch to create for modified repos.  Default is 'work'

    -h
    --help
            Give this help list
EOF
}


OPTS=$(getopt -o h,n:,m:,M: -l help,new-repo-branch:,modified-repo-branch:,map-file: -- "$@")
if [ $? -ne 0 ]; then
    usage
    exit 1
fi

eval set -- "${OPTS}"

modified_branch="work"
new_branch="master"
MAPFILE="repo.map"

while true; do
    case $1 in
        --)
            # End of getopt arguments
            shift
            break
            ;;
        -M | --map-file)
            MAPFILE=$2
            shift 2
            ;;
        -m | --modified-repo-branch)
            modified_branch=$2
            shift 2
            ;;
        -n | --new-repo-branch)
            new_branch=$2
            shift 2
            ;;
        -h | --help )
            usage
            exit 1
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

CHANGE_IDS_FILE=$(mktemp /tmp/change_ids_XXXXXX)

capture_change_id () {
    local key="$1"
    local change_id

    # Note, a merge commit may show multiple change-id's.  First the merge, then of the parents.
    change_id=$(git log --pretty=%B HEAD^..HEAD | grep Change-Id: | head -n 1 | sed 's/^Change-Id: //')
    echo "$key|$change_id" >> $CHANGE_IDS_FILE
}

git_commit_append () {
    local msg="$1"
    ( git log --pretty=%B HEAD^..HEAD | sed ':a;/^[ \n]*$/{$d;N;ba}'; echo "$msg" ) | git commit --amend -F -
}

git_commit_depends_on () {
    local key="$1"
    local change_id

    change_id=$(grep "$key" $CHANGE_IDS_FILE | tail -n 1 | cut -d '|' -f 2)
    if [ "${change_id}" != "" ]; then
        git_commit_append "Depends-On: ${change_id}"
    fi
}

copy_commit_hook () {
    local src_repo=$1
    local dest_repo=$2

    if [ -f $dest_repo/.git/hooks/commit-msg ]; then
        # Hook already exists
        return 0
    fi

    (
    cd  $src_repo
    git review -s
    )

    if [ ! -f $src_repo/.git/hooks/commit-msg ]; then
        # No hook to copy
        return 1
    fi

    cp -p $src_repo/.git/hooks/commit-msg $dest_repo/.git/hooks/commit-msg
}

find_repo_root () {
    local d=${1:-$PWD}

    d=$(readlink -f $d)
    while [ "$d" != "/" ]; do
        if [ -d "$d/.repo" ]; then
            echo $d
            return 0
        fi
        d=$(dirname $d)
    done

    return 1
}

find_git_root () {
    local d=${1:-$PWD}

    d=$(readlink -f $d)
    while [ "$d" != "/" ]; do
        if [ -d "$d/.git" ]; then
            echo $d
            return 0
        fi
        d=$(dirname $d)
    done

    return 1
}

is_repo_controlled () {
    local d=${1:-$PWD}
    local repo_root=""
    local git_root=""
    local rel_d=""

    d=$(readlink -f $d)
    repo_root=$(find_repo_root $d)
    if [ "$repo_root" == "" ]; then
        return 1
    fi
    git_root=$(find_git_root $d)
    if [ "$git_root" == "" ]; then
        return 1
    fi
    rel_d=$(echo $git_root | sed "s#^$repo_root/##")
    check=$(repo forall -c 'if [ "$REPO_PATH" == "'$rel_d'" ]; then echo $REPO_PATH; fi')
    [ "$check" == "$rel_d" ]
}

current_branch () {
    local d=${1:-$PWD}
    (
    cd $d
    git branch | grep \* | sed 's/^* //'
    )
}

create_branch () {
    local branch=$1
    local current=""

    current=$(current_branch)
    if [ "$current" != "$branch" ]; then
        if is_repo_controlled .; then
            repo start --head $branch
        else
            git checkout -b $branch
        fi
    fi
}

# Wrapper around oslo.tools/filter_git_history.sh to remove everything
# not in $filter_list
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
        mkdir -p $dest_repo/$(dirname $work_dir)
        cp -pLr $src_repo $dest_repo/$work_dir

        # Ensure no previous backup exists
        rm -rf $dest_repo/$work_dir/.git/packed_refs $dest_repo/$work_dir/.git/refs/original

        # Filter it
        (
            cd $dest_repo/$work_dir
            git checkout -b $modified_branch || true
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
        if [ "$dest_repo" == "$src_repo" ]; then
            continue
        fi

        work_dir="${src_repo}.old_repo"
        tmp_remote="tmp-${src_repo}"
        merge_from="$tmp_remote/$modified_branch "
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
            git review -s || ( cd -; copy_commit_hook $src_repo $dest_repo )
            git merge -m "$merge_msg" $extra_args $merge_from
            git commit --amend --no-edit -s
            capture_change_id "${src_repo}#${dest_repo}#merge"

            tmp_remote="tmp-$src_repo"
            git remote remove $tmp_remote

            rm -rf $work_dir
        )
    done
}

fixup_pkg_info () {
    local src_repo=$1
    local dest_repo=$2
    local mapping=""
    local src_path=""
    local dest_path=""
    local dest_pkg_info=""
    local from_name=""
    local to_name=""

    for mapping in ${path_mapping_list["$src_repo#$dest_repo"]}; do
        src_path=${mapping%#*}
        dest_path=${mapping##*#}
        from_name=$(basename $src_path)
        to_name=$(basename $dest_path)

        if [ "$from_name" == "$to_name" ]; then
            continue
        fi

        for dest_pkg_info in $(find $dest_repo/$dest_path -maxdepth 1 -type f -name 'PKG-INFO'); do
            if grep -q "^Name: $from_name$" $dest_pkg_info; then
                 sed -i "s#^Name: $from_name\$#Name: $to_name#" $dest_pkg_info
                 ( cd $(dirname $dest_pkg_info); git add $(basename $dest_pkg_info) )
            fi
        done
    done
}

fixup_spec () {
    local src_repo=$1
    local dest_repo=$2
    local mapping=""
    local src_path=""
    local dest_path=""
    local dest_spec=""
    local from_name=""
    local to_name=""

    for mapping in ${path_mapping_list["$src_repo#$dest_repo"]}; do
        src_path=${mapping%#*}
        dest_path=${mapping##*#}
        from_name=$(basename $src_path)
        to_name=$(basename $dest_path)

        if [ "$from_name" == "$to_name" ]; then
            continue
        fi

        for dest_spec in $(find $dest_repo/$dest_path/${OS} -maxdepth 1 -type f -name '*.spec'); do
            if grep -q "$from_name" $dest_spec; then
                 sed -e "s#^Name: $from_name\$#Name: $to_name#" \
                     -e "s#^Summary: $from_name#Summary: $to_name#" \
                     -e "s#^\(%[a-z]* -n \)$from_name#\1$to_name#" \
                     -i $dest_spec
                 ( cd $(dirname $dest_spec); git add $(basename $dest_spec) )
            fi
        done
    done
}

fixup_client_spec () {
    local src_repo=$1
    local dest_repo=$2
    local mapping=""
    local src_path=""
    local dest_path=""
    local spec=""
    local from_name=""
    local to_name=""
    local extra_from_name=""
    local extra_to_name=""
    local git_root=""

    for mapping in ${path_mapping_list["$src_repo#$dest_repo"]}; do
        src_path=${mapping%#*}
        dest_path=${mapping##*#}
        from_name=$(basename $src_path)
        to_name=$(basename $dest_path)

        if [ "$from_name" == "$to_name" ]; then
            continue
        fi
echo "fixup_client_spec: processing $from_name to $to_name"

        for spec in $(find . -type f -name '*.spec'); do
            if echo $spec | grep -q $dest_repo/$dest_path/${OS}; then
                # Our own spec, not a client
echo "    skip own spec $spec"
                continue
            fi

            for key in "${!path_mapping_list[@]}"; do
                extra_src_repo=${key%#*}
                extra_dest_repo=${key##*#}
                for extra_mapping in ${path_mapping_list["${extra_src_repo}#${extra_dest_repo}"]}; do
                    extra_src_path=${extra_mapping%#*}
                    if echo $spec | grep -q $extra_src_repo/$extra_src_path; then
                        # The original version of a spec that has been relocated, but not yet deleted
echo "    skip relocated spec $spec"
                        continue 3
                    fi
                done
            done

            git_root=""
            for extra_from_name in $(echo ${from_name}; target_pkg_list "${from_name}" "${dest_spec}"); do
                extra_to_name=${extra_from_name/#${from_name}/${to_name}}

                if grep -q "Requires:[ ]*$extra_from_name" $spec; then
                    git_root=$(find_git_root $spec)

                    sed -e "s#^\(BuildRequires:[ ]*\)${extra_from_name}\$#\1${extra_to_name}#" \
                        -e "s#^\(Requires:[ ]*\)${extra_from_name}\$#\1${extra_to_name}#" \
                        -i $spec
                    (
                        cd $(dirname $spec)
                        create_branch $modified_branch
                        git add $(basename $spec)
                    )
                fi
            done

            if [ "$git_root" != "" ]; then
                (
                    cd $git_root
                    git review -s || ( cd -; copy_commit_hook $src_repo $git_root )
                    git commit -s -m "Fix spec's Requires due to rename of package '${from_name}' to '${to_name}'"
                    git_commit_depends_on "${src_repo}#${dest_repo}#to_config"
                )
            fi
        done
    done
}

fixup_build_srpm_data () {
    local src_repo=$1
    local dest_repo=$2
    local mapping=""
    local src_path=""
    local dest_path=""
    local dest_data=""
    local from_name=""
    local to_name=""

    for mapping in ${path_mapping_list["$src_repo#$dest_repo"]}; do
        src_path=${mapping%#*}
        dest_path=${mapping##*#}
        from_name=$(basename $src_path)
        to_name=$(basename $dest_path)

        if [ "$from_name" == "$to_name" ]; then
            continue
        fi

        for dest_data in $(find $dest_repo/$dest_path/${OS} -maxdepth 1 -type f -name 'build_srpm.data'); do
            if grep -q "$from_name" $dest_data; then
                 sed -e "s#^SRC_DIR=\"$from_name#SRC_DIR=\"$to_name#" \
                     -e "s#^SRC_DIR=\"\$PKG_BASE/$from_name#SRC_DIR=\"\$PKG_BASE/$to_name#" \
                     -e "s#^SRC_DIR=$from_name#SRC_DIR=$to_name#" \
                     -e "s#^SRC_DIR=\$PKG_BASE/$from_name#SRC_DIR=\$PKG_BASE/$to_name#" \
                     -e "s#^TAR_NAME=\"$from_name\"#TAR_NAME=\"$to_name\"#" \
                     -e "s#^TAR_NAME=$from_name#TAR_NAME=$to_name#" \
                     -e "s#^COPY_LIST=\"$from_name#COPY_LIST=\"$to_name#" \
                     -e "s#^COPY_LIST=\"\$PKG_BASE/$from_name#COPY_LIST=\"\$PKG_BASE/$to_name#" \
                     -e "s# \$PKG_BASE/$from_name# \$PKG_BASE/$to_name#" \
                     -i $dest_data
                 ( cd $(dirname $dest_spec); git add $(basename $dest_data) )
            fi   
        done
    done
}

fixup_pkg_dirs () {
    local src_repo=$1
    local dest_repo=$2
    local src_cfg=""
    local dest_cfg=""
    local mapping=""
    local src_path=""
    local dest_path=""

    for src_cfg in $(find $src_repo -maxdepth 1 -type f -name "${OS}_pkg_dirs*"); do
        dest_cfg="$dest_repo/$(basename $src_cfg)"
        for mapping in ${path_mapping_list["$src_repo#$dest_repo"]}; do
            src_path=${mapping%#*}
            dest_path=${mapping##*#}
            if grep -q "^$src_path$" $src_cfg; then
                 grep "^$src_path$" $src_cfg | sed "s#^$src_path\$#$dest_path#" >> $dest_cfg
                 ( cd $(dirname $dest_cfg); git add $(basename $dest_cfg) )
                 sed "/^${src_path//\//\\/}$/d" -i $src_cfg
                 ( cd $(dirname $src_cfg); git add $(basename $src_cfg) )
            fi
        done
    done
}

fixup_wheels_inc () {
    local src_repo=$1
    local dest_repo=$2
    local src_cfg=""
    local dest_cfg=""
    local mapping=""
    local src_whl=""
    local dest_whl=""

    for src_cfg in $(find $src_repo -maxdepth 1 -type f -name "${OS}_*_wheels.inc"); do
        dest_cfg="$dest_repo/$(basename $src_cfg)"
        for mapping in ${path_mapping_list["$src_repo#$dest_repo"]}; do
            src_whl=$(basename ${mapping%#*})-wheels
            dest_whl=$(basename ${mapping##*#})-wheels
            if grep -q "^$src_whl$" $src_cfg; then
                 grep "^$src_whl$" $src_cfg | sed "s#^$src_whl\$#$dest_whl#" >> $dest_cfg
                 ( cd $(dirname $dest_cfg); git add $(basename $dest_cfg) )
                 sed "/^${src_whl//\//\\/}$/d" -i $src_cfg
                 ( cd $(dirname $src_cfg); git add $(basename $src_cfg) )
            fi
        done
    done
}

#
# list packages generated by a spec file that start with a target prefix
#
target_pkg_list () {
    local target_pkg=$1
    local spec=$2

    grep "^%package -n %{name}" ${spec} | sed "s#%package -n %{name}#${target_pkg}#"
    grep "^%package -n ${target_pkg}" ${spec} | sed "s#%package -n ${target_pkg}#${target_pkg}#"
}

fixup_image_inc () {
    local src_repo=$1
    local dest_repo=$2
    local src_cfg=""
    local dest_cfg=""
    local mapping=""
    local src_pkg=""
    local dest_pkg=""
    local src_path=""
    local dest_path=""
    local extra_src_pkg=""
    local extra_dest_pkg=""

    for src_cfg in $(find $src_repo -maxdepth 1 -type f -name "${OS}_iso_image.inc" -o -name "${OS}_guest_image*.inc"); do
        dest_cfg="$dest_repo/$(basename $src_cfg)"
        for mapping in ${path_mapping_list["$src_repo#$dest_repo"]}; do
            src_path=${mapping%#*}
            dest_path=${mapping##*#}
            src_pkg=$(basename ${src_path})
            dest_pkg=$(basename ${dest_path})

            if grep -q "^${src_pkg}$" $src_cfg; then
                grep "^# ${src_pkg}$" $src_cfg | sed "s%^# ${src_pkg}\$%\n# ${dest_pkg}%" >> ${dest_cfg}
                grep "^${src_pkg}$" $src_cfg | sed "s#^${src_pkg}\$#${dest_pkg}#" >> ${dest_cfg}
                ( cd $(dirname ${dest_cfg}); git add $(basename ${dest_cfg}) )
                sed "/^# ${src_pkg//\//\\/}$/d" -i ${src_cfg}
                sed "/^${src_pkg//\//\\/}$/d" -i ${src_cfg}
                ( cd $(dirname ${src_cfg}); git add $(basename ${src_cfg}) )
            fi

            for dest_spec in $(find ${dest_repo}/${dest_path}/${OS} -maxdepth 1 -type f -name '*.spec'); do
                # for extra_src_pkg in $(grep "^%package -n %{name}" ${dest_spec} | sed "s#%package -n %{name}#${src_pkg}#"; \
                #                        grep "^%package -n ${src_pkg}" ${dest_spec} | sed "s#%package -n ${src_pkg}#${src_pkg}#"); do
                for extra_src_pkg in $(target_pkg_list "${src_pkg}" "${dest_spec}"); do
                    extra_dest_pkg=${extra_src_pkg/#${src_pkg}/${dest_pkg}}
                    if grep -q "^${extra_src_pkg}$" $src_cfg; then
                        grep "^${extra_src_pkg}$" $src_cfg | sed "s#^${extra_src_pkg}\$#${extra_dest_pkg}#" >> ${dest_cfg}
                        ( cd $(dirname ${dest_cfg}); git add $(basename ${dest_cfg}) )
                        sed "/^${extra_src_pkg//\//\\/}$/d" -i ${src_cfg}
                        ( cd $(dirname ${src_cfg}); git add $(basename ${src_cfg}) )
                    fi
                done
            done
        done
    done
}

fixup_helm_inc () {
    local src_repo=$1
    local dest_repo=$2
    local src_cfg=""
    local dest_cfg=""
    local mapping=""

    # for src_cfg in $(find $src_repo -maxdepth 1 -type f -name "${OS}_helm.inc"); do
    # done
    return 0
}

fixup_branch () {
    local src_repo=$1
    local dest_repo=$2
    local mapping=""

    (
        cd $src_repo
        create_branch $modified_branch
    )
    (
        cd $dest_repo
        if [ ${is_new[$dest_repo]} -eq 1 ]; then
            create_branch $new_branch
        else
            create_branch $modified_branch
        fi
    )
}

fixup_commit () {
    local src_repo=$1
    local dest_repo=$2
    local mapping=""
    local src_paths=""
    local dest_paths=""

    for mapping in ${path_mapping_list["$src_repo#$dest_repo"]}; do
        src_paths+="${mapping%#*} "
        dest_paths+="${mapping##*#} "
    done

    (
        cd $src_repo
        stagged=$(git diff --name-only --cached | head -n 1)
        if [ "$stagged" != "" ]; then
            git review -s || ( cd -; copy_commit_hook $src_repo $dest_repo )
            git commit -s -m "Config file changes to remove '$src_paths' after relocation to '$dest_repo'"
            capture_change_id "${src_repo}#${dest_repo}#from_config"
        fi
    )
    (
        cd $dest_repo
        stagged=$(git diff --name-only --cached | head -n 1)
        if [ "$stagged" != "" ]; then
            git review -s || ( cd -; copy_commit_hook $src_repo $dest_repo )
            git commit -s -m "Config file changes to add '$dest_paths' after relocation from '$src_repo'"
            git_commit_depends_on "${src_repo}#${dest_repo}#merge"
            capture_change_id "${src_repo}#${dest_repo}#to_config"
        fi
    )
}

OS="centos"
declare -A rewrite_list
declare -A filter_list
declare -A path_mapping_list
declare -A src_repo_list
declare -A is_virgin
declare -A is_new
declare -A change_ids

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

    filter_list["$src_repo#$dest_repo"]+="^$src_path "

    if [ "$src_path" != "." ]; then
        if [ "$dest_path" != "." ]; then
            # sed patter to rewrite foo/ to bar/
            rewrite_list["$dest_repo"]+="s|\t$src_path/|\t$dest_path/|;"
            path_mapping_list["$src_repo#$dest_repo"]+="$src_path#$dest_path "

            # sed patter to rewrite foo/foo to bar/bar ...
            # Ok, really we are rewriting bar/foo/ to bar/bar/
            # because the lower directory was rewriten by the first rule
            alt_src_path=$src_path/$(basename $src_path)
            alt_intermediate_path=$dest_path/$(basename $src_path)
            alt_dest_path=$dest_path/$(basename $dest_path)
            if [ -d $src_repo/$alt_src_path ]; then
                rewrite_list["$dest_repo"]+="s|\t$alt_intermediate_path/|\t$alt_dest_path/|;"
            fi

            # sed patter to rewrite foo/centos/foo to bar/centos/bar ...
            # Ok, really we are rewriting bar/centos/foo/ to bar/centos/bar/
            # because the lower directory was rewriten by the first rule
            alt_src_path=$src_path/${OS}/$(basename $src_path)
            alt_intermediate_path=$dest_path/${OS}/$(basename $src_path)
            alt_dest_path=$dest_path/${OS}/$(basename $dest_path)
            if [ -d $src_repo/$alt_src_path ]; then
                rewrite_list["$dest_repo"]+="s|\t$alt_intermediate_path/|\t$alt_dest_path/|;"
            fi

            # sed patter to rewrite foo/centos/foo.spec to bar/centos/bar.spec ...
            # Ok, really we are rewriting bar/centos/foo.spec to bar/centos/bar.spec
            # because the lower directory was rewriten by the first rule
            alt_src_path=$src_path/${OS}/$(basename $src_path).spec
            alt_intermediate_path=$dest_path/${OS}/$(basename $src_path).spec
            alt_dest_path=$dest_path/${OS}/$(basename $dest_path).spec
            if [ -f $src_repo/$alt_src_path ]; then
                rewrite_list["$dest_repo"]+="s|\t$alt_intermediate_path/|\t$alt_dest_path/|;"
            fi

        else
            # If we are moving 'foo' to '.', it isn't a conventional package, so keep it simple
            rewrite_list["$dest_repo"]+="s|\t$src_path/|\t|;"
        fi
    else
        # If we are moving '.' to 'bar/', it isn't a conventional package, so keep it simple
        if [ "$dest_path" != "." ]; then
            rewrite_list["$dest_repo"]+="s|\t|\t$dest_path/|;"
            rewrite_list["$dest_repo"]+="s|^\([^#]*\)$|$dest_path/\1|;"
        fi
    fi

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
    src_path=${filter_list[$key]//^/}

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

    is_virgin[$src_repo]=0
    is_new[$src_repo]=0

    if [ -d $dest_repo ]; then
        is_virgin[$dest_repo]=0
        is_new[$dest_repo]=0
    else
        is_virgin[$dest_repo]=1
        is_new[$dest_repo]=1
    fi

    for src_path in ${filter_list[$key]//^/}; do
        # SAL if [ ! -d ${src_repo}/${src_path} ]; then
        if [ ! -d ${src_repo}/${src_path} ] && [ ! -f ${src_repo}/${src_path} ] ; then
            # echo "ERROR: directory not found, src_path='$src_path' within src_repo='$src_repo'"
            echo "ERROR: path not found, src_path='$src_path' within src_repo='$src_repo'"
            exit 1
        fi
    done
done

#
# Create destination repos as required.  Then create a
# working direcory(s) under the destination repo which will
# contain a filtered copy of the src_repo(s).
#
for key in "${!filter_list[@]}"; do
    src_repo=${key%#*}
    dest_repo=${key##*#}

    if [ "$src_repo" == "$dest_repo" ]; then
       continue
    fi

    # Set up destination repo
    if [ ! -d $dest_repo ]; then
        echo "Creating destination repo '$dest_repo'"
        mkdir -p $dest_repo
        (
            cd $dest_repo
            git init
        )
    else
        if [ ${is_virgin[$dest_repo]} -ne 1 ]; then
            (
                cd $dest_repo
                create_branch $modified_branch
            )
        fi
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
        echo "ERROR: No dest_repo, skipping key=${key} of rewrite_list"
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
        if [ ${is_new[$dest_repo]} -eq 1 ]; then
            git branch -m master $new_branch || true
        fi
    )
done

#
# Fix config files to reflect the package movements
#
for key in "${!path_mapping_list[@]}"; do
    src_repo=${key%#*}
    dest_repo=${key##*#}

    fixup_branch $src_repo $dest_repo
    fixup_pkg_dirs $src_repo $dest_repo
    fixup_wheels_inc $src_repo $dest_repo
    fixup_image_inc $src_repo $dest_repo
    fixup_helm_inc $src_repo $dest_repo
    fixup_pkg_info $src_repo $dest_repo
    fixup_spec $src_repo $dest_repo
    fixup_build_srpm_data $src_repo $dest_repo
    fixup_commit $src_repo $dest_repo
    fixup_client_spec $src_repo $dest_repo
done

#
# Remove relocated subdirectories from the source repos.
#
for key in "${!filter_list[@]}"; do
    src_repo=${key%#*}
    dest_repo=${key##*#}
    src_paths=${filter_list[$key]//^/}

    (
        something_to_commit=0
        cd $src_repo
        for p in $src_paths; do
            if [ -e $p ]; then
                git rm -rf $p
                something_to_commit=1
            fi
        done
        if [ $something_to_commit -eq 1 ]; then
            create_branch $modified_branch
            git review -s || ( cd -; copy_commit_hook $src_repo $dest_repo )
            git commit -s -m "Subdirectories '$src_paths' relocated to repo '$(basename $dest_repo)'"
            git_commit_depends_on "${src_repo}#${dest_repo}#from_config"
            capture_change_id "${src_repo}#${dest_repo}#rm"
        fi
    )
done

#
# List new repos created
#
new_repo_list=""
for dest_repo in "${!is_new[@]}"; do
    echo $dest_repo
    if [ ${is_new[$dest_repo]} -eq 1 ]; then
        new_repo_list+="$dest_repo "
    fi
done

if [ "$new_repo_list" != "" ]; then
    echo
    echo "New repos created at: $new_repo_list"
fi
