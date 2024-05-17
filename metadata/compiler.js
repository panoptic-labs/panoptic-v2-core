import data from './FactoryNFT.json'
import { LibZip } from '../lib/solady/js/solady'

// array of data contracts to deploy
let bytecodes = [""]
// array of property names to be encoded by the deployment script
let properties = []
// array of indices for each property where an index is a key corresponding to a pointer in `pointers`
let indices = []
// array of slices for each property where a slice is a starting index and size associated with a bytecode index in `bytecodes`
let pointers = []

// This script "compiles" a 2-level deep JSON object, encoding it into a series of data contracts that can be deployed to the blockchain
// It also provides a series of indices and pointers that can be used to structure and access the data in the contracts
// The resulting structure is K_1 -> K_2 -> V where K_1 is a property name, K_2 is an index, and V is a pointer to the value in the contract
// If the value of a top-level key is an array, the indices correspond to the array indices
// If the second level of the JSON is an object, the indices are encoded key strings
for (const [key, value] of Object.entries(data)) {
    properties.push(key)
    indices.push([])
    pointers.push([])

    // 
    if (Array.isArray(value)) {
        value.forEach((v, idx) => {
            indices[indices.length - 1].push(idx.toString())

            let encoded = ""

            // compress large values using LZ77
            if (key == "art" || key == "frames" || key == "filters" || key == "descriptions") encoded = LibZip.flzCompress("0x"+Buffer.from(new TextEncoder().encode(v)).toString('hex')).slice(2)
            else encoded = encodeBytes(v)

            // contract size (minus initcode) cannot exceed the Spurious Dragon limit, so complete the current contract and place `encoded` in a new contract
            if (bytecodes[bytecodes.length - 1].length + encoded.length > 24576 * 2) {
                prependInitcode()

                bytecodes.push(encoded)
                pointers[indices.length - 1].push({"start": 0, "size": encoded.length / 2, "codeIndex": bytecodes.length - 1})
            } else {
                bytecodes[bytecodes.length - 1] += encoded
                pointers[indices.length - 1].push({"start": bytecodes[bytecodes.length - 1].length / 2 - encoded.length / 2, "size": encoded.length / 2, "codeIndex": bytecodes.length - 1})
            }
        })
    } else {
        for (const [k, v] of Object.entries(value)) {
            indices[indices.length - 1].push(BigInt("0x"+Buffer.from(new TextEncoder().encode(k)).toString('hex').padEnd(64, '0')).toString())

            const encoded = encodeBytes(v)

            // contract size (minus initcode) cannot exceed the Spurious Dragon limit, so complete the current contract and place `encoded` in a new contract
            if (bytecodes[bytecodes.length - 1].length + encoded.length > 24576 * 2) {
                prependInitcode()

                bytecodes.push(encoded)
                pointers[indices.length - 1].push([{"start": 0, "size": encoded.length / 2, "codeIndex": bytecodes.length - 1}])
            } else {
                bytecodes[bytecodes.length - 1] += encoded
                pointers[indices.length - 1].push({"start": bytecodes[bytecodes.length - 1].length / 2 - encoded.length / 2, "size": encoded.length / 2, "codeIndex": bytecodes.length - 1})
            }
        }
    }
}

// complete the last contract
if (bytecodes[bytecodes.length - 1].length < (24576 + 14) * 2) prependInitcode()

Bun.write('./metadata/out/MetadataPackage.json', JSON.stringify({"bytecodes": bytecodes, "properties": properties, "indices": indices, "pointers": pointers}))

// prepend initcode to last item in bytecode array with its final size
// this code copies the rest of the bytecode (encoded data) and returns it, resulting in a deplyoed contract with the desired data encoded in the "code"
// that data can be read cheaply using the provided pointer information using the `extcodecopy` opcode
function prependInitcode() {
    bytecodes[bytecodes.length - 1] = "63" + (bytecodes[bytecodes.length - 1].length / 2).toString(16).padStart(8, '0') + "80600E6000396000F3" + bytecodes[bytecodes.length - 1]
}

// ABI-encodes strings (excluding the size) and integers
function encodeBytes(value) {
    if (typeof value === 'string') {
        return Buffer.from(new TextEncoder().encode(value)).toString('hex');
    } else {
        return value.toString(16).padStart(64, '0');
    }
}

