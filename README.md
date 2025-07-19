## Directories

Directories are represented as files, where the data blocks store the
names of the files, alongside the corresponding inodes.

Each directory entry is 16 bytes - 14 bytes for the filename, and 2 bytes
for the inode pointer. Empty entries are zero'd out (i.e. those caused by
deleted files).

### Compaction

When a directory is closed and no more open handles to it remain, a ratio
should be calculated between the size of the directory file, and the number
of file entries contained within. If this ratio is less than some threshold,
compaction should take place by copying the directory file to a new location
(of course omitting zero entries), then updating the directory's inode so that
the data block points to the new copy. The old blocks can then be freed.

# Future Plans

We need to support partially loaded block devices (so if we're mounting a
large disk over the network we don't need to load it all in one go).

In order to support this we're going to need to introduce the concept of
a transaction, through which all state access (blocks and other internal
data structures) is routed. If at any point the transaction receives an
error that a block is not loaded the transaction is discarded and the
caller is invited to try again later. A notification is also triggered
so that the network sync layer may fetch the missing block(s) from the
server.

Thought: the transaction system should be smart enough to know that if
a block is zero'd there is no need to read it from the server.