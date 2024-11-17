#!/bin/bash
set -e

self=$(basename -- "$0" | sed 's/-/ /')
self_sp=$(printf "%${#self}s" '')

OPTIONS_SPEC="\
${self} init [repository] <ref>
${self} sync [repository] <ref>

${self} creates point-in-time tree object imports from an
${self_sp} external tree or repository

Commands:
init	creates an inital import of a commit's tree object and merges
		the new commit into the current branch
sync	imports a commit's tree object onto the first ancestor commit
		that has a common tree shared with the external tree and then
		merges the new commit into the current branch
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

resolve_ref_short () {
	local ref="$1"
	git symbolic-ref --short --quiet "$ref" || git rev-parse --short "$ref"
}

get_ref_desc () {
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

	test $# -ge 2 -a $# -le 3 || usage
	cmd=$1
	arg_url=${3:+$2}
	arg_ref=${3:-$2}
	case "$cmd" in init|sync) false ;; esac && usage

	#----- parse refs -----

	require_clean_work_tree "$cmd"

	if [ -n "$arg_url" ]; then
		ref=$(git check-ref-format --normalize --allow-onelevel "$arg_ref") || die "fatal: bad ref '${arg_ref}'"
		git fetch --no-recurse-submodules "$arg_url" "$ref" || die "fatal: fetch returned an error"
		arg_ref='FETCH_HEAD'
	fi

	head_ref=$(resolve_ref_short HEAD)
	ext_ref=$(git rev-parse --verify --symbolic --quiet "${arg_ref}^{commit}") || die "fatal: bad revision '${arg_ref}'"
	ext_ref=${ext_ref%'^{commit}'}

	#----- find sync point -----

	last_import_commit=$(first_commit_with_ancestor_tree $ext_ref)
	if [ -n "$last_import_commit" ]; then
		if [ "$cmd" = 'init' ]; then
			{ die "fatal: found existing import from '$ext_ref' in '$head_ref':  $(
				git log --oneline --decorate $(test -t 3 && echo --color) -n 1 $last_import_commit
			)"; } 3>&1
		elif [ "$(git rev-parse "$last_import_commit^{tree}")" = "$(git rev-parse "$ext_ref^{tree}")" ]; then
			say "'$head_ref' already up to date with '$ext_ref', no new changes to synchronize"
			exit
		fi
		{ say "Last synchronization commit to '$head_ref':  $(
			git log --oneline --decorate $(test -t 3 && echo --color) -n 1 $last_import_commit
		)"; } 3>&1
	elif [ "$cmd" = 'sync' ]; then
		die "fatal: '$head_ref' has no history in common with '$ext_ref'"
	fi

	#----- create commit with tree object from $ext_ref -----

	if [ "$cmd" = 'sync' ]; then
		confirm "Import tree as new descendant of commit $(git rev-parse --short $last_import_commit)?" || exit 0
	fi

	# edit_msg outputs message on FD 3, but needs to be able to use
	# stdin/stdout. Use FD 4 to save stdout for inside the subshell.
	{ c_msg=$(
		edit_msg "$(printf '%s\n' \
				"Import tree object from $(get_ref_desc "$ext_ref")" \
				"" \
				"  Latest commit: $(git log --oneline --format=reference -n 1 "$ext_ref")" \
				"" \
			)" \
			3>&1 >&4
	); } 4>&1
	[ -n "$c_msg" ] || die "Aborting commit due to empty commit message."

	new_commit=$(git commit-tree ${last_import_commit:+-p $last_import_commit} -m "$c_msg" "${ext_ref}^{tree}")
	[ $? -eq 0 ] || die "fatal: failed to create import commit${new_commit:+": $new_commit"}"
	say "Successfully imported tree as new commit $new_commit"

	#----- merge created commit into HEAD -----

	confirm "Merge imported commit $(git rev-parse --short $new_commit) into '$(resolve_ref_short HEAD)'?" || {
		say "Merge skipped! To merge the new commit manually run:"
		say
		say "  git merge $(git rev-parse --short $new_commit)"
		say
		exit
	}

	m_msg="Merge external tree import from $(get_ref_desc "$ext_ref")"
	say "Merging..."
	set_reflog_action "${self#git }: ${cmd} tree $(git rev-parse "$new_commit^{tree}")"
	git merge --no-ff $(test "$cmd" = 'init' && echo --allow-unrelated-histories) --edit --log=1 -m "$m_msg" $new_commit \
		|| exit $?

	say "${cmd} complete!"
}

main "$@"
