import { Abs, RelCurr, RelEnd } from './constants.js';

export class FileSystem {
    #bridge;
    #id;
    
    constructor(bridge, id) {
        this.#bridge = bridge;
        this.#id = id;
    }

    lookup(dirPtr, name) {
        return this.#bridge.lookup(this.#id, dirPtr, name);
    }

    exists(dirPtr, name) {
        return this.#bridge.exists(this.#id, dirPtr, name);
    }

    stat(ptr) {
        return this.#bridge.stat(this.#id, ptr);
    }
    
    open(filePtr, flags) {
        return this.#bridge.open(this.#id, filePtr, flags);
    }
    
    create(parentDirPtr, name) {
        return this.#bridge.create(this.#id, parentDirPtr, name);
    }

    statFd(fd) {
        return this.#bridge.statFd(this.#id, fd);
    }

    close(fd) {
        return this.#bridge.close(this.#id, fd);
    }
    
    unlink(parentDirPtr, name) {
        return this.#bridge.unlink(this.#id, parentDirPtr, name);
    }
    
    tell(fd) {
        return this.#bridge.tell(this.#id, fd);
    }

    eof(fd) {
        return this.#bridge.eof(this.#id, fd);
    }

    seek(fd, offset, whence) {
        return this.#bridge.seek(this.#id, fd, offset, whence);
    }

    read(dst, fd) {
        return this.#bridge.read(this.#id, dst, fd);
    }

    write(fd, src) {
        return this.#bridge.write(this.#id, fd, src);
    }

    mkdir(parentDirPtr, name) {
        return this.#bridge.mkdir(this.#id, parentDirPtr, name);
    }

    rmdir(parentDirPtr, name) {
        return this.#bridge.rmdir(this.#id, parentDirPtr, name);
    }

    opendir(dirPtr) {
        return this.#bridge.opendir(this.#id, dirPtr);
    }

    closedir(dh) {
        return this.#bridge.closedir(this.#id, dh);
    }
    
    readdir(dh) {
        return this.#bridge.readdir(this.#id, dh);
    }
}