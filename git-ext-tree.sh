#!/bin/bash
set -eu

self=$(basename "$0") && self=${self#git-}

first_commit_with_ancestor_tree () {
	local ref="$1"
	git rev-list --no-commit-header --format=%T "$ref" \
		| grep -Ff - -m 1 <(git rev-list --no-commit-header --format='%T %H' HEAD) \
		| cut -d ' ' -f 2
}

parse_ref () {
	local ref="$1"
	git symbolic-ref --short --quiet "$ref" || git rev-parse --short "$ref"
}

ref_desc () {
	local ref="$1"
	if [ "$ref" = "FETCH_HEAD" ]; then
		git fmt-merge-msg -F $(git rev-parse --git-path FETCH_HEAD) | sed 's/^Merge //'
	else
		echo "ref '$ref'"
	fi
}

edit_msg () {
	local msg="$1"
	# subshell to isolate trap
	(
		local tfile=
		trap '[ -n "$tfile" ] && rm "$tfile"' EXIT
		tfile=$(mktemp -p "$(git rev-parse --git-dir)")
		echo "$msg" > "$tfile"
		$(git var GIT_EDITOR) "$tfile"
		# output final message to FD 3
		git stripspace -s < "$tfile" >&3
	)
}

verify_clean () {
	git diff --cached --quiet HEAD || {
		echo "fatal: uncomitted changes"
		exit 1
	}
	! git rev-parse --verify --quiet MERGE_HEAD > /dev/null || {
		echo "fatal: merge in progress"
		exit 1
	}
}

confirm () {
	local key
	read -p "${1:-"Continue?"} (y/N) " key
	[ "$key" = "Y" -o "$key" = "y" ]
}

main () {
	! test -t 1; is_tty=${?#0}

	#----- parse params -----

	test $# -ne 1 && set -- -h
	eval "$(git rev-parse --parseopt -- "$@" <<-EOF || echo exit $?
		git ${self} <ref>

		git ${self} creates point-in-time tree imports from an external tree or repository

		Typical usage:
		git fetch <repository> <ref>
		git ${self} FETCH_HEAD
		--
		h,help show the help
	EOF
	)"
	test "$1" = "--" && shift

	#----- parse refs -----

	verify_clean

	head_ref=$(parse_ref HEAD)
	tpl_ref=$(git rev-parse --verify --symbolic --quiet "$1^{commit}") || {
		echo "fatal: bad revision '$1'" >&2
		exit 1
	}
	tpl_ref=${tpl_ref%'^{commit}'}

	#----- find sync point -----

	last_import_commit=$(first_commit_with_ancestor_tree $tpl_ref)
	if [ -z "$last_import_commit" ]; then
		echo "fatal: '$head_ref' has no history in common with '$tpl_ref'" >&2
		exit 1
	elif [ "$(git rev-parse "$last_import_commit^{tree}")" = "$(git rev-parse "$tpl_ref^{tree}")" ]; then
		echo "'$head_ref' already up to date with '$tpl_ref', no new changes to synchronize"
		exit
	fi
	echo "Last synchronization commit to '$head_ref':  $(
		git log --oneline --decorate ${is_tty:+"--color"} -n 1 $last_import_commit
	)"

	#----- create commit with parent $last_import_commit and tree from $tpl_ref -----

	confirm "Synchronize changes as new descendant of commit $(git rev-parse --short $last_import_commit)?" || exit 0

	# edit_msg outputs message on FD 3, but needs to be able to use
	# stdin/stdout. Use FD 4 to save stdout for inside the subshell.
	{ c_msg=$(
		edit_msg "$(printf '%s\n' \
				"Import tree from $(ref_desc "$tpl_ref")" \
				"" \
				"  Latest commit: $(git log --oneline --format=reference -n 1 "$tpl_ref")" \
				"" \
			)" \
			3>&1 >&4
	); } 4>&1
	[ -n "$c_msg" ] || {
		echo "Aborting commit due to empty commit message."
		exit 1
	}

	new_commit=$(git commit-tree -p $last_import_commit -m "$c_msg" "${tpl_ref}^{tree}")
	if [ $? -gt 0 ]; then
		echo "fatal: failed to create synchronization commit${new_commit:+": $new_commit"}"
		exit 1
	fi
	echo "Successfully imported changes as new commit $new_commit"

	#----- merge created commit into HEAD -----

	confirm "Merge synchronization commit $(git rev-parse --short $new_commit) into '$(parse_ref HEAD)'?" || {
		echo "Merge skipped! To merge the new commit manually run:"
		echo
		echo "  git merge $(git rev-parse --short $new_commit)"
		echo
		exit
	}

	m_msg="Merge imported tree from $(ref_desc "$tpl_ref")"
	echo "Merging..."
	git merge --no-ff --edit --log=1 -m "$m_msg" $new_commit \
		|| exit $?
	echo "Synchronization complete!"
}

main "$@"
