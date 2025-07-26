import { MaxTransferSize } from "../js/constants.js";

export { dumpFile, dumpFileToString, dumpDir, dumpFS };

function dumpFile(fs, inode) {
    const stat = fs.stat(inode);
    const fh = fs.open(inode, 0);
    const out = new Uint8Array(stat.size);
    
    let offset = 0;
    while (offset < stat.size) {
        const bytesToRead = Math.min(MaxTransferSize, stat.size - offset);
        const bytesRead = fs.read(out.subarray(offset, offset + bytesToRead), fh);
        if (bytesToRead !== bytesRead) {
            throw new Error(`Expected to read ${bytesToRead} bytes, but got ${bytesRead}`);
        }
        offset += bytesRead;
    }
    
    fs.close(fh);
    return out;
}

function dumpFileToString(fs, inode) {
    const data = dumpFile(fs, inode);
    return new TextDecoder().decode(data);
}

function dumpDir(fs, inode)  {
    const out = {};
    
    const dh = fs.opendir(inode);
    while (true) {
        const entry = fs.readdir(dh);
        if (!entry) {
            break;
        }
        out[entry.name] = entry.isDir ? {
            type: 'dir',
            entries: dumpDir(fs, entry.inode)
        } : {
            type: 'file',
            contents: dumpFile(fs, entry.inode),
            executable: entry.isExecutable
        };
    }
    fs.closedir(dh);

    return out;
}

function dumpFS(fs) {
    return dumpDir(fs, 0);
};
