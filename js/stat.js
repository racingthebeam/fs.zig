import { File, Directory } from './constants.js';

export class Stat {
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
