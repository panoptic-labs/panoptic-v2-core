import data from './FactoryNFT.json'
import { LibZip } from '../lib/solady/js/solady'

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

            let encoded = ""
            if (key == "art" || key == "frames" || key == "filters" || key == "descriptions") encoded = LibZip.flzCompress("0x"+Buffer.from(new TextEncoder().encode(v)).toString('hex')).slice(2)
            else encoded = encodeBytes(v)
            if (key == "rarities" && idx == 0) console.log("rarities 0", v, encoded, typeof encoded)

            // contract size (minus initcode) cannot exceed the Spurious Dragon limit
            if (bytecodes[bytecodes.length - 1].length + encoded.length > 24576 * 2) {
                prependInitcode()

                bytecodes.push(encoded)
                console.log("new contract, length", "\""+key+"\"", idx, bytecodes.length - 1, bytecodes[bytecodes.length - 1].length / 2, bytecodes[bytecodes.length - 1].length)
                pointers[indices.length - 1].push({"start": 0, "end": encoded.length / 2, "codeIndex": bytecodes.length - 1})
            } else {
                bytecodes[bytecodes.length - 1] += encoded
                console.log("postpending, new length: ", bytecodes.length - 1, bytecodes[bytecodes.length - 1].length / 2)
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
                console.log("postpending, new length: ", bytecodes.length - 1, bytecodes[bytecodes.length - 1].length / 2)
                pointers[indices.length - 1].push({"start": bytecodes[bytecodes.length - 1].length / 2 - encoded.length / 2, "end": encoded.length / 2, "codeIndex": bytecodes.length - 1})
            }
        }
    }
}

bytecodes.forEach((bytecode, idx) => console.log(`Item ${idx} bytecode length: ${bytecode.length / 2 - 14}`))

if (bytecodes[bytecodes.length - 1].length < (24576 + 14) * 2) prependInitcode()

Bun.write('./metadata/out/MetadataPackage.json', JSON.stringify({"bytecodes": bytecodes, "properties": properties, "indices": indices, "pointers": pointers}))

// prepend initcode to last item in bytecode array with its final size
function prependInitcode() {
    bytecodes[bytecodes.length - 1] = "63" + (bytecodes[bytecodes.length - 1].length / 2).toString(16).padStart(8, '0') + "80600E6000396000F3" + bytecodes[bytecodes.length - 1]
}

function encodeBytes(value) {
    if (typeof value === 'string') {
        return Buffer.from(new TextEncoder().encode(value)).toString('hex');
    } else {
        return value.toString(16).padStart(64, '0');
    }
}

