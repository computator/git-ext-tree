# Installation

```sh
sudo install -m 755 git-ext-tree.sh /usr/local/bin/git-ext-tree
```
or
```sh
mkdir -p ~/bin
install -m 755 git-ext-tree.sh ~/bin/git-ext-tree
```

# Usage

```
usage: git ext-tree init [repository] <ref>
   or: git ext-tree sync [repository] <ref>

    git ext-tree creates point-in-time tree object imports from an
    external tree or repository.

    Commands:
    init	creates an inital import of a commit's tree object and merges
    		the new commit into the current branch
    sync	imports a commit's tree object onto the first ancestor commit
    		that has a common tree shared with the external tree and then
    		merges the new commit into the current branch

    -h, --help            show the help
    -c, --no-edit         skip editing message before commit
    -q, --quiet           suppress unnecessary output
    -y, --yes             don't ask for confirmation before performing actions
```
