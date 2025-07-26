import * as E from './errors.js';
import { Stat } from './stat.js';
import { Abs, RelCurr, RelEnd, OpenFlags } from './constants.js';

export class MockFs {
    constructor() {
        this.inodes = new Map();
        this.nextInodePtr = 0;
        
        const rootInode = this.#makeDirectoryInode();
        this.inodes.set(rootInode.ptr, rootInode);

        this.openFileFds = new Map();
        this.openDirFds = new Map();
        this.nextFd = 1;
    };

    lookup(parentPtr, name) {
        const dirInode = this.#getDirInode(parentPtr);
        const inode = dirInode.entries.get(name);
        if (typeof inode !== 'number') this.#raise(E.NOENT);
        return inode;
    }

    exists(parentPtr, name) {
        try {
            this.lookup(parentPtr, name);
            return true;
        } catch (err) {
            if (err.message === E.NOENT) {
                return false;
            }
            throw err; // rethrow other errors
        }
    }

    stat(inodePtr) {
        const ent = this.inodes.get(inodePtr);
        if (!ent) this.#raise(E.NOENT);

        const stat = new Stat();
        stat.name = null;
        stat.inode = inodePtr;
        stat.type = ent.type === 'file' ? 1 : 2; // 1 for file, 2 for directory
        stat.executable = ent.executable || false;
        stat.mtime = ent.mtime;
        stat.size = ent.size;

        return stat;
    }

    statFd(fd) {
        const openFile = this.#getOpenFile(fd);
        return this.stat(openFile.inode.ptr);
    }

    open(inodePtr, flags) {
        const inode = this.inodes.get(inodePtr);
        if (!inode) this.#raise(E.NOENT);
        if (inode.type !== 'file') this.#raise(E.ISDIR);
        
        const openFile = {
            fd: this.nextFd++,
            flags: flags,
            inode: inode,
            offset: 0
        };

        if (flags & OpenFlags.TRUNCATE) {
            if (inode.refCount > 0) {
                this.#raise(E.BUSY);
            }
            inode.data = new Uint8Array(16); // reset data to empty
            inode.size = 0;
            inode.mtime = this.#now();
        } else if (flags & OpenFlags.SEEK_END) {
            openFile.offset = inode.size;
        }

        inode.refCount++;

        this.openFileFds.set(openFile.fd, openFile);

        return openFile.fd;
    }

    create(parentDirPtr, name) {
        const parentInode = this.#getDirInode(parentDirPtr);
        if (parentInode.type !== 'directory') {
            this.#raise(E.NOTDIR);
        } else if (parentInode.entries.has(name)) {
            this.#raise(E.EXIST);
        }

        const newInode = this.#makeFileInode();
        this.inodes.set(newInode.ptr, newInode);
        parentInode.entries.set(name, newInode.ptr);

        return newInode.ptr;
    }

    close(fd) {
        const openFile = this.#getOpenFile(fd);
        this.openFileFds.delete(fd);

        const inode = openFile.inode;
        inode.refCount--;
        if (inode.refCount === 0 && inode.deleted) {
            this.inodes.delete(inode.inode);
        }
    }

    unlink(inode, name) {
        const dir = this.#getDirInode(inode);
        if (!dir.entries.has(name)) this.#raise(E.NOENT);
        
        const childPtr = dir.entries.get(name);
        const childInode = this.inodes.get(childPtr);
        
        if (!childInode) {
            throw new Error("INTERNAL ERROR: Child inode not found");
        } else if (childInode.type !== 'file') {
            this.#raise(E.ISDIR);
        }
        
        dir.entries.delete(name);
        dir.mtime = this.#now();

        if (childInode.refCount > 0) {
            childInode.deleted = true;
        } else {
            this.inodes.delete(childPtr);
        }
    }

    tell(fd) {
        const openFile = this.#getOpenFile(fd);
        return openFile.offset;
    }
    
    eof(fd) {
        const openFile = this.#getOpenFile(fd);
        return openFile.offset >= openFile.inode.size;
    }
    
    seek(fd, offset, whence = Abs) {
        const openFile = this.#getOpenFile(fd);

        if (whence === RelCurr) {
            offset += openFile.offset;
        } else if (whence === RelEnd) {
            offset += openFile.inode.size;
        } else if (whence !== Abs) {
            this.#raise(E.ARG);
        }

        if (offset < 0 || offset > openFile.inode.size) {
            this.#raise(E.BADOFFSET);
        }
        
        openFile.offset = offset;
    }

    read(dst, fd) {
        const openFile = this.#getOpenFile(fd);
        const inode = openFile.inode;
        const bytesToRead = Math.min(dst.length, inode.size - openFile.offset);
        dst.set(inode.data.subarray(openFile.offset, openFile.offset + bytesToRead));
        openFile.offset += bytesToRead;
        return bytesToRead;
    }

    write(fd, src) {
        const openFile = this.#getOpenFile(fd);
        const inode = openFile.inode;

        const end = openFile.offset + src.length;
        this.#growInodeToMinSize(inode, end);

        inode.data.set(src, openFile.offset);
        openFile.offset += src.length;

        inode.size = Math.max(inode.size, openFile.offset);
        inode.mtime = this.#now();

        return src.length;
    }

    mkdir(parentPtr, name) {
        const dirInode = this.#getDirInode(parentPtr);
        if (dirInode.entries.has(name)) this.#raise(E.EXIST);
        const newInode = this.#makeDirectoryInode();
        this.inodes.set(newInode.ptr, newInode);
        dirInode.entries.set(name, newInode.ptr);
        
        return newInode.ptr;
    }

    rmdir(parentPtr, name) {
        const dirInode = this.#getDirInode(parentPtr);
        
        const childInodePtr = dirInode.entries.get(name);
        if (typeof childInodePtr !== 'number') this.#raise(E.NOENT);
        
        const childInode = this.inodes.get(childInodePtr);
        if (!childInode) {
            throw new Error("INTERNAL ERROR: Child inode not found");
        } else if (childInode.type !== 'directory') {
            this.#raise(E.NOTDIR);
        }

        // TOOD: check directory is empty
        
        dirInode.entries.delete(name);
        dirInode.mtime = this.#now();
        
        if (childInode.refCount > 0) {
            childInode.deleted = true;
        } else {
            this.inodes.delete(childInodePtr);
        }
    }

    opendir(dirPtr) {
        const dirInode = this.#getDirInode(dirPtr);

        const openDir = {
            fd: this.nextFd++,
            inode: dirInode,
            // for simplicity we just cache the entries that exist at the time of opening.
            // this means will not reflect changes made to the directory after opening,
            // but in a real filesystem it's not guaranteed we'd observe those changes either
            // since new entries could be written before the read pointer.
            // Note: we still check for deletions that occur after opening.
            entries: Array.from(dirInode.entries.keys()),
            offset: 0
        };

        this.openDirFds.set(openDir.fd, openDir);
        dirInode.refCount++;

        return openDir.fd;
    }

    closedir(dh) {
        const openDir = this.#getOpenDir(dh);
        this.openDirFds.delete(dh);
        
        const dir = openDir.inode
        dir.refCount--;
        if (dir.refCount === 0 && dir.deleted) {
            this.inodes.delete(dir.inode);
        }
    }

    readdir(dh) {
        const openDir = this.#getOpenDir(dh);
        
        while (true) {
            if (openDir.offset >= openDir.entries.length) {
                return false;
            }

            const name = openDir.entries[openDir.offset++];
            if (!openDir.inode.entries.has(name)) {
                continue;
            }

            const childPtr = openDir.inode.entries.get(name);
            const childInode = this.inodes.get(childPtr);
            
            const out = new Stat();
            out.name = name;
            out.inode = childPtr;
            out.type = childInode.type === 'file' ? 1 : 2;
            out.executable = childInode.executable || false;
            out.mtime = childInode.mtime;
            out.size = childInode.size;

            return out;
        }
    }

    #raise(err) {
        throw new Error(err);
    }

    #getDirInode(inode) {
        const dir = this.inodes.get(inode);
        if (!dir) this.#raise(E.NOENT);
        if (dir.type !== 'directory') this.#raise(E.NOTDIR);
        return dir;
    }
    
    #getOpenDir(fd) {
        const openDir = this.openDirFds.get(fd);
        if (!openDir) this.#raise(E.BADFD);
        return openDir;
    }
    
    #getOpenFile(fd) {
        const openFile = this.openFileFds.get(fd);
        if (!openFile) this.#raise(E.BADFD);
        return openFile;
    }

    #now() {
        return Date.now();
    }

    #growInodeToMinSize(inode, size) {
        let targetSize = this.#roundUpToNextPowerOfTwo(size);
        if (inode.data.length >= targetSize) return;
        const newData = new Uint8Array(targetSize);
        newData.set(inode.data);
        inode.data = newData;
    }

    #roundUpToNextPowerOfTwo(size) {
        if (size <= 0) return 1;
        size--;
        size |= size >> 1;
        size |= size >> 2;
        size |= size >> 4;
        size |= size >> 8;
        size |= size >> 16;
        return size + 1;  
    }

    #makeDirectoryInode() {
        return {
            ptr: this.nextInodePtr++,
            type: 'directory',
            entries: new Map(),
            size: 0,
            mtime: this.#now(),
            refCount: 0,
            deleted: false,
        };
    }

    #makeFileInode() {
        return {
            ptr: this.nextInodePtr++,
            type: 'file',
            data: new Uint8Array(16),
            size: 0,
            mtime: this.#now(),
            executable: false,
            refCount: 0,
            deleted: false,
        };
    }   
};