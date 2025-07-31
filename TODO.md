[x] Rework files so final block is not eagerly allocated
[ ] write some tests designed to reveal any flaws in this new approach
    - e.g. write to block boundary then read, seek to first block, etc.

[ ] rework the public interface:
    - create(type) - create a file and return its inode
    - purge(inode) - purge contents
    - link(dir_inode, name, inode)
    - unlink(dir_inode, name)

If we do this it pushes responsibility to the VFS layer; for example it will
be necessary for it to keep track of open/deleted files, handling the removal
once the deletion has occurred.

Wondering if it might just be simpler to keep things as-is and implement
move/rename in the FS layer and deal with the complexity that comes along
with it.

[ ] Finish rmdir implementation

[ ] Implement "move"

[ ] Test outstanding operations

[ ] Full fuzz tester
Implementation idea: after every operation that mutates the directory
structure, dump the structure to JSON array (including inode numbers).
Then - every fuzz operation just picks a random inode + operation.
Another challenge is that there will need to be some smarts to avoid
running out of blocks/inodes.

[ ] Docs
