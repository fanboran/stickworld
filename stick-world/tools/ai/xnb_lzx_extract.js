// XNB 贴图提取：LZX 解压 + Texture2D 载荷导出（复用 XnbCli 的纯 JS Lzx 解码器）
// 依赖：XNBCLI_DIR 环境变量指向 XnbCli clone（默认 F:/tmp/XnbCli，
//       github.com/LeonBlade/XnbCli，其 lz4/dxt-js 原生/旧依赖与本脚本无关）
// 用法：node xnb_lzx_extract.js <输入.xnb> <输出.bin> ；载荷格式 JSON 打到 stdout
const fs = require('fs');
const path = require('path');
const XNBCLI_DIR = process.env.XNBCLI_DIR || 'F:/tmp/XnbCli';
const Presser = require(path.join(XNBCLI_DIR, 'app/Presser'));
const BufferReader = require(path.join(XNBCLI_DIR, 'app/BufferReader'));

function decompressLzx(buffer, compressedTodo, decompressedTodo) {
	return Presser.decompress(buffer, compressedTodo, decompressedTodo);
}

function extract(file) {
	const raw = fs.readFileSync(file);
	if (raw.slice(0, 3).toString() !== 'XNB') throw new Error('not XNB');
	const flags = raw[5];
	const fileSize = raw.readUInt32LE(6);
	let contentStart = 10;
	let buf;
	if (flags & 0x80) {
		const decompressedSize = raw.readUInt32LE(10);
		const br = new BufferReader(file);
		br.bytePosition = 14;
		const decompressed = decompressLzx(br, fileSize - 14, decompressedSize);
		// 逻辑内容 = 解压后从 0 开始（等价于 copyFrom 到 14 的视图）
		buf = decompressed;
		contentStart = 0;
	} else {
		buf = raw;
	}
	let p = contentStart;
	// 7bit 数量读取器
	function read7() {
		let result = 0, shift = 0;
		for (;;) {
			const b = buf[p++];
			result |= (b & 0x7f) << shift;
			if (!(b & 0x80)) return result;
			shift += 7;
		}
	}
	const readerCount = read7();
	const readers = [];
	for (let i = 0; i < readerCount; i++) {
		const len = read7();
		readers.push(buf.slice(p, p + len).toString('ascii'));
		p += len + 4; // + version int32
	}
	const shared = read7();
	if (shared !== 0) throw new Error('unexpected shared resources');
	const readerIdx = read7();
	if (!readers[readerIdx - 1].includes('Texture2DReader')) {
		throw new Error('not Texture2D: ' + readers[readerIdx - 1]);
	}
	// Texture2D 载荷
	const format = buf.readInt32LE(p); p += 4;
	const width = buf.readUInt32LE(p); p += 4;
	const height = buf.readUInt32LE(p); p += 4;
	const mipCount = buf.readUInt32LE(p); p += 4;
	const dataSize = buf.readUInt32LE(p); p += 4;
	const data = buf.slice(p, p + dataSize);
	return { format, width, height, mipCount, dataSize, data, readers };
}

const [input, output] = process.argv.slice(2);
const r = extract(input);
fs.writeFileSync(output, r.data);
console.log(JSON.stringify({ format: r.format, width: r.width, height: r.height, mipCount: r.mipCount, dataSize: r.dataSize }));
