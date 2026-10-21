#
#  common.zsh
#
#  What tools/sessiontest and tools/streamtest share. Sourced by each once it has set $tool,
#  its name for messages, and $cache, the folder it builds into.
#

die() { print -u2 "$tool: $*"; exit 1 }
say() { print "$tool: $*" }
pause() { perl -e "select(undef, undef, undef, $1)" }

# Builds $1 from the Swift file $2, which holds the top-level code, and any more after it,
# when one of them is newer than it. With more than one file swiftc takes top-level code only
# from main.swift, so $2 is built through a link by that name. The array swift_flags, if set,
# is passed along.
build_swift() {
    local binary=$1 main=$2
    shift 2
    local source newer=0
    for source in $main "$@"; do [[ $source -nt $binary ]] && newer=1; done
    [[ -x $binary ]] && (( ! newer )) && return 0
    local dir=$cache/${binary:t}.src
    mkdir -p $dir
    ln -sf $main $dir/main.swift
    DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
        swiftc -O -suppress-warnings ${swift_flags[@]:-} -o $binary $dir/main.swift "$@" || die "could not build ${main:t}"
}
