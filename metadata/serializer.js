import data from './FactoryNFT.json'

let bytecodes = [""]
let properties = []
let indices = []
// slice start/end -- 
let pointers = []

// This script processes 
for (const [key, value] of Object.entries(data)) {
    properties.push(key)
    indices.push([])
    pointers.push([])
    if (Array.isArray(value)) {
        value.forEach((v, idx) => {
            indices[indices.length - 1].push(idx.toString())

            const encoded = encodeBytes(v)

            // contract size (minus initcode) cannot exceed the Spurious Dragon limit
            if (bytecodes[bytecodes.length - 1].length + encoded.length > 24576 * 2) {
                prependInitcode()

                bytecodes.push(encoded)
                pointers[indices.length - 1].push({"start": 0, "end": encoded.length / 2, "codeIndex": bytecodes.length - 1})
            } else {
                bytecodes[bytecodes.length - 1] += encoded
                pointers[indices.length - 1].push({"start": bytecodes[bytecodes.length - 1].length / 2 - encoded.length / 2, "end": encoded.length / 2, "codeIndex": bytecodes.length - 1})
            }
        })
    } else {
        for (const [k, v] of Object.entries(value)) {
            indices[indices.length - 1].push(BigInt("0x"+Buffer.from(new TextEncoder().encode(k)).toString('hex').padEnd(64, '0')).toString())

            const encoded = encodeBytes(v)

            if (bytecodes[bytecodes.length - 1].length + encoded.length > 24576 * 2) {
                prependInitcode()

                bytecodes.push(encoded)
                pointers[indices.length - 1].push([{"start": 0, "end": encoded.length / 2, "codeIndex": bytecodes.length - 1}])
            } else {
                bytecodes[bytecodes.length - 1] += encoded
                pointers[indices.length - 1].push({"start": bytecodes[bytecodes.length - 1].length / 2 - encoded.length / 2, "end": encoded.length / 2, "codeIndex": bytecodes.length - 1})
            }
        }
    }
}

if (bytecodes[bytecodes.length - 1].length < (24576 + 14) * 2) prependInitcode()

Bun.write('./metadata/out/MetadataPackage.json', JSON.stringify({"bytecodes": bytecodes, "properties": properties, "indices": indices, "pointers": pointers}))

// prepend initcode to last item in bytecode array with its final size
function prependInitcode() {
    bytecodes[bytecodes.length - 1] = "63" + (bytecodes[bytecodes.length - 1].length / 2).toString(16).padStart(8, '0') + "80600E6000396000F3" + bytecodes[bytecodes.length - 1]
}

// ABI-encodes the metadata as a (string/bytes/bytes1[])
// Number types are right-padded so they can be interpreted as `uint256`
function encodeBytes(value) {
    if (typeof value === 'string') {
        const utf8Bytes = new TextEncoder().encode(value);
        const lengthHex = utf8Bytes.length.toString(16).padStart(64, '0');
        const utf8Hex = Buffer.from(utf8Bytes).toString('hex');
        return lengthHex + utf8Hex;    
    } else {
        const numHex = value.toString(16).padStart(64, '0');
        const lengthHex = '20'.padStart(64, '0');
        return lengthHex + numHex;
    }
}