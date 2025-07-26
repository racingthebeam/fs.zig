import { OpenFlags, MaxTransferSize } from "../js/constants.js";

export { dump };

function dump(fs) {
    function dumpFile(inode) {
        const stat = fs.stat(inode);
        const fh = fs.open(inode, OpenFlags.READ);
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

    function dumpDir(inode)  {
        const out = new Map();
        
        const dh = fs.opendir(inode);
        while (true) {
            const entry = fs.readdir(dh);
            if (!entry) {
                break;
            }
            if (entry.isDir) {
                out.set(entry.name, {
                    type: 'dir',
                    entries: dumpDir(entry.inode),
                });
            } else {
                out.set(entry.name, {
                    type: 'file',
                    contents: dumpFile(entry.inode),
                    executable: entry.isExecutable
                });
            }
        }
        fs.closedir(id, dh);

        return out;
    }
    
    return dumpDir(0);
};