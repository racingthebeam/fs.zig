import { MaxTransferSize } from "../js/constants.js";

export { dumpFile, dumpFileToString, dumpDir, dumpFS };

function dumpFile(fs, inode) {
    const size = fs.stat(inode).size;
    const fh = fs.open(inode, 0);

    try {
        const out = new Uint8Array(size);
        let rp = 0;
        while (rp < size) {
            const bytesToRead = Math.min(MaxTransferSize, size - rp);
            const bytesRead = fs.read(out.subarray(rp, rp + bytesToRead), fh);
            if (bytesToRead !== bytesRead) {
                throw new Error(`Expected to read ${bytesToRead} bytes, but got ${bytesRead}`);
            }
            rp += bytesRead;
        }
        return out;
    } finally {
        fs.close(fh);
    }
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
