export { dump };

function dump(fs, id) {
    function dumpDir(inode)  {
        const out = new Map();
        
        const dh = fs.opendir(id, inode);
        while (true) {
            const entry = fs.readdir(id, dh);
            if (!entry) {
                break;
            }
            if (entry.isDir) {
                out.set(entry.name, {
                    type: 'dir',
                    contents: dumpDir(entry.inode),
                });
            } else {
                out.set(entry.name, {
                    type: 'file',
                    executable: entry.isExecutable,
                    size: entry.size,
                });
            }
        }
        fs.closedir(id, dh);

        return out;
    }
    
    return dumpDir(0);
};