#!/bin/bash
set -e

self=$(basename -- "$0" | sed 's/-/ /')

OPTIONS_SPEC="\
${self} <ref>

${self} creates point-in-time tree imports from an external tree or repository

Typical usage:
git fetch <repository> <ref>
${self} FETCH_HEAD
--
h,help show the help
q,quiet suppress unnecessary output
"

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

confirm () {
	local key
	read -p "${1:-"Continue?"} (y/N) " key
	[ "$key" = "Y" -o "$key" = "y" ]
}

main () {
	#----- parse params -----

	SUBDIRECTORY_OK=1
	. "$(git --exec-path)/git-sh-setup"
	require_work_tree_exists

	while [ $# -gt 0 ]; do
		case "$1" in
			-q)
				GIT_QUIET=1
				;;
			--)
				shift
				break
				;;
			*)
				usage
				;;
		esac
		shift
	done
	test $# -eq 1 || usage

	#----- parse refs -----

	require_clean_work_tree "synchronize"

	head_ref=$(parse_ref HEAD)
	tpl_ref=$(git rev-parse --verify --symbolic --quiet "$1^{commit}") || die "fatal: bad revision '$1'"
	tpl_ref=${tpl_ref%'^{commit}'}

	#----- find sync point -----

	last_import_commit=$(first_commit_with_ancestor_tree $tpl_ref)
	if [ -z "$last_import_commit" ]; then
		die "fatal: '$head_ref' has no history in common with '$tpl_ref'"
	elif [ "$(git rev-parse "$last_import_commit^{tree}")" = "$(git rev-parse "$tpl_ref^{tree}")" ]; then
		say "'$head_ref' already up to date with '$tpl_ref', no new changes to synchronize"
		exit
	fi
	{ color_arg=$(test -t 3 && echo --color || true); } 3>&1
	say "Last synchronization commit to '$head_ref':  $(
		git log --oneline --decorate $color_arg -n 1 $last_import_commit
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
	[ -n "$c_msg" ] || die "Aborting commit due to empty commit message."

	new_commit=$(git commit-tree -p $last_import_commit -m "$c_msg" "${tpl_ref}^{tree}")
	[ $? -eq 0 ] || die "fatal: failed to create synchronization commit${new_commit:+": $new_commit"}"
	say "Successfully imported changes as new commit $new_commit"

	#----- merge created commit into HEAD -----

	confirm "Merge synchronization commit $(git rev-parse --short $new_commit) into '$(parse_ref HEAD)'?" || {
		say "Merge skipped! To merge the new commit manually run:"
		say
		say "  git merge $(git rev-parse --short $new_commit)"
		say
		exit
	}

	m_msg="Merge imported tree from $(ref_desc "$tpl_ref")"
	say "Merging..."
	git merge --no-ff --edit --log=1 -m "$m_msg" $new_commit \
		|| exit $?
	say "Synchronization complete!"
}

main "$@"
