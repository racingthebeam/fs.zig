[ ] Finish rmdir implementation

[ ] Rework files so final block is not eagerly allocated

[ ] Test outstanding operations

[ ] Full fuzz tester
Implementation idea: after every operation that mutates the directory
structure, dump the structure to JSON array (including inode numbers).
Then - every fuzz operation just picks a random inode + operation.
Another challenge is that there will need to be some smarts to avoid
running out of blocks/inodes.

[ ] Docs
