import { File, Directory } from './constants.js';

export class Stat {
    static fromWasm(buffer, len) {
        if (len !== 29) throw new Error(`invalid stat format - expected 25 bytes, got ${len}`);
          
        const nameEnd = buffer.indexOf(0);
        const name = (nameEnd <= 0)
            ? null
            : new TextDecoder().decode(buffer.subarray(0, nameEnd));

        const slice = buffer.subarray(15, 29);
        const dv = new DataView(slice.buffer, slice.byteOffset, slice.byteLength);

        const out = new Stat();
        out.name = name;
        out.inode = dv.getUint32(0);
        out.type = dv.getUint8(4);
        out.executable = dv.getUint8(5) > 0;
        out.mtime = dv.getUint32(6, false);
        out.size = dv.getUint32(10, false);
        
        return out;
    }

    name = null;
    inode = null;
    type = null;
    executable = null;
    mtime = null; 
    size = null;
    
    get isFile() { return this.type === File; }
    get isDir() { return this.type === Directory; }
    get isExecutable() { return this.executable; }
};
