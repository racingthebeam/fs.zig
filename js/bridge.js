import * as E from "./errors.js";
import { Stat } from "./stat.js";

export async function load(wasmUrl, { onBlockChanged = () => {} } = {}) {
  const res = await WebAssembly.instantiateStreaming(fetch(wasmUrl), {
    env: {
      notifyBlockChanged: onBlockChanged,
      now: () => { return BigInt(Math.floor(Date.now() / 1000)); }
    }
  });
  return new Bridge(res.instance);
}

export class Bridge {
  #api;                         // WASM functions
  #mem;                         // WASM memory
  #shuttle;                     // memory region for transferring data blocks to/from WASM
  #str;                         // memory region for transferring input strings to WASM
  #strPtr = 0;                  // string write pointer
  #strEnc = new TextEncoder();
  #blockDevices = new Map();    // active block devices
  
  constructor(instance) {
    this.#api = instance.exports;
    this.#mem = instance.exports.memory;
    this.#shuttle = new MemoryRegion(instance.exports.memory, this.#api.getShuttleBufferPtr(), this.#api.getShuttleBufferSize());
    this.#str = new MemoryRegion(instance.exports.memory, this.#api.getStringBufferPtr(), this.#api.getStringBufferSize());

    this.#api.init();
  }

  //
  // Block Device Management

  createBlockDevice(blockSize, blockCount) {
    const id = this.#api.createBlockDevice(blockSize, blockCount);
    this.#checkStatus(id);
    this.#blockDevices.set(id, {size: blockSize, count: blockCount});
    return id;
  }

  destroyBlockDevice(deviceId) {
    const status = this.#api.destroyBlockDevice(deviceId);
    this.#checkStatus(status);
    this.#blockDevices.delete(deviceId);
  }

  //
  // Block Device Access

  readBlock(dst, deviceId, block) {
    this.#assertDeviceExists(deviceId, dst.length);
    this.#checkStatus(this.#api.readBlock(deviceId, block));
    this.#shuttle.read(dst);
  }

  writeBlock(deviceId, block, src) {
    this.#assertDeviceExists(deviceId, src.length);
    this.#shuttle.write(src);
    this.#checkStatus(this.#api.writeBlock(deviceId, block));
  }

  zeroBlock(deviceId, block) {
    this.#checkStatus(this.#api.zeroBlock(deviceId, block)); 
  }

  //
  // File System Management

  formatFS(deviceId, inodeBlockCount) {
    this.#assertDeviceExists(deviceId);
    const id = this.#checkStatus(this.#api.fileSystemFormat(deviceId, inodeBlockCount));
    return this.#shuttle.view.slice(0, 16);
  }

  initFS(deviceId, config) {
    if (config.length !== 16) {
      throw new Error(`FS config must be exactly 16 bytes`);
    }
    this.#shuttle.write(config);
    return this.#checkStatus(this.#api.fileSystemInit(deviceId));
  }

  destroyFS(fsId) {
    return this.#checkStatus(this.#api.fileSystemDestroy(fsId)); 
  }

  //
  // File System Access

  lookup(fsId, inode, name) {
    this.#resetStringBuffer();
    const {ptr, len} = this.#writeString(name);
    const res = this.#api.fsLookup(fsId, inode, ptr, len);
    return this.#checkStatus(res);
  }

  exists(fsId, inode, name) {
    this.#resetStringBuffer();
    const {ptr, len} = this.#writeString(name);
    const res = this.#api.fsExists(fsId, inode, ptr, len);
    return this.#checkStatus(res) > 0;
  }

  stat(fsId, inode) {
    const len = this.#checkStatus(this.#api.fsStat(fsId, inode));
    return this.#readStat(len);
  }

  open(fsId, inode, flags) {
    return this.#checkStatus(this.#api.fsOpen(fsId, inode, flags));
  }

  create(fsId, parentDirPtr, name) {
    this.#resetStringBuffer();
    const {ptr, len} = this.#writeString(name);
    const res = this.#api.fsCreate(fsId, parentDirPtr, ptr, len);
    return this.#checkStatus(res);
  }

  close(fsId, fd) {
    return this.#checkStatus(this.#api.fsClose(fsId, fd));
  }

  unlink(fsId, inode, name) {
    this.#resetStringBuffer();
    const {ptr, len} = this.#writeString(name);
    return this.#checkStatus(this.#api.fsUnlink(fsId, inode, ptr, len));
  }

  tell(fsId, fd) {
    return this.#checkStatus(this.#api.fsTell(fsId, fd));
  }

  eof(fsId, fd) {
    return this.#checkStatus(this.#api.fsEof(fsId, fd)) > 0;
  }

  seek(fsId, fd, offset, whence) {
    return this.#checkStatus(this.#api.fsSeek(fsId, fd, offset, whence));
  }

  read(fsId, dst, fd) {
    if (dst.length > this.#shuttle.length) throw new Error("max size exceeded");
    const read = this.#checkStatus(this.#api.fsRead(fsId, fd, dst.length));
    this.#shuttle.read(dst.subarray(0, read));
    return read;
  }

  write(fsId, fd, src) {
    if (src.length > this.#shuttle.length) throw new Error("max size exceeded");
    this.#shuttle.write(src);
    return this.#checkStatus(this.#api.fsWrite(fsId, fd, src.length));
  }

  mkdir(fsId, inode, name) {
    this.#resetStringBuffer();
    const {ptr, len} = this.#writeString(name);
    return this.#checkStatus(this.#api.fsMkdir(fsId, inode, ptr, len));
  }

  rmdir(fsId, inode, name) {
    this.#resetStringBuffer();
    const {ptr, len} = this.#writeString(name);
    return this.#checkStatus(this.#api.fsRmdir(fsId, inode, ptr, len));
  }

  opendir(fsId, inode) {
    return this.#checkStatus(this.#api.fsOpendir(fsId, inode));
  }

  closedir(fsId, fd) {
    return this.#checkStatus(this.#api.fsClosedir(fsId, fd));
  }

  readdir(fsId, fd) {
    const len = this.#checkStatus(this.#api.fsReaddir(fsId, fd));
    return (len > 0) ? this.#readStat(len) : false;
  }

  //
  // Internals

  #assertDeviceExists(id, expectedBlockSize = null) {
    const device = this.#blockDevices.get(id);
    if (!device) throw new Error(`unknown block device ${id}`);
    if (expectedBlockSize !== null && expectedBlockSize !== device.size) {
      throw new Error(`incorrect block size for device ${id} (expected=${expectedBlockSize}, actual=${device.size})`);
    }
  }

  #checkStatus(status) {
    if (status < 0) {
      // TODO: proper error type
      throw new Error(`fs op failed with status: ${status}`);
    }
    return status;
  }

  //
  // String encoding

  #resetStringBuffer() {
    this.#strPtr = 0;
  }

  // Write a string to WASM memory and return the pointer/length so it can
  #writeString(str) {
    const res = this.#strEnc.encodeInto(str, this.#str.view.subarray(this.#strPtr));
    const out = {ptr: this.#str.offset + this.#strPtr, len: res.written};
    this.#strPtr += res.written;
    return out;
  }

  #readStat(len) {
    return Stat.fromWasm(this.#shuttle.get(), len);
  }
}

class MemoryRegion {
  #mem;
  #buf = null;
  #ary = null;

  constructor(memory, offset, length) {
    this.#mem = memory;
    this.offset = offset;
    this.length = length;
  }

  get view() {
    this.#reset(); 
    return this.#ary;
  }

  get() {
    this.#reset(); 
    return this.#ary;
  }

  read(dst) {
    this.#reset();
    dst.set(this.#ary.subarray(0, dst.length), 0);
  }

  write(src) {
    this.#reset();
    this.#ary.subarray(0, src.length).set(src, 0);
  }

  #reset() {
    if (this.#buf !== this.#mem.buffer) {
      this.#buf = this.#mem.buffer;
      this.#ary = new Uint8Array(this.#buf, this.offset, this.length);
    }
  }
}
