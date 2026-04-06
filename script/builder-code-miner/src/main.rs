use std::env;
use std::error::Error;
use std::fmt::{self, Display, Write};
use std::fs::{self, OpenOptions};
use std::io::Write as IoWrite;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::thread;
use std::time::Instant;

const MAX_U48: u64 = (1u64 << 48) - 1;
const KECCAKF_ROUNDS: usize = 24;
const RATE_BYTES: usize = 136;
const ROTATION_OFFSETS: [[u32; 5]; 5] = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
];
const ROUND_CONSTANTS: [u64; KECCAKF_ROUNDS] = [
    0x0000_0000_0000_0001,
    0x0000_0000_0000_8082,
    0x8000_0000_0000_808a,
    0x8000_0000_8000_8000,
    0x0000_0000_0000_808b,
    0x0000_0000_8000_0001,
    0x8000_0000_8000_8081,
    0x8000_0000_0000_8009,
    0x0000_0000_0000_008a,
    0x0000_0000_0000_0088,
    0x0000_0000_8000_8009,
    0x0000_0000_8000_000a,
    0x0000_0000_8000_808b,
    0x8000_0000_0000_008b,
    0x8000_0000_0000_8089,
    0x8000_0000_0000_8003,
    0x8000_0000_0000_8002,
    0x8000_0000_0000_0080,
    0x0000_0000_0000_800a,
    0x8000_0000_8000_000a,
    0x8000_0000_8000_8081,
    0x8000_0000_0000_8080,
    0x0000_0000_8000_0001,
    0x8000_0000_8000_8008,
];

#[derive(Clone, Copy, Debug)]
struct Hit {
    builder_code: u64,
    address: [u8; 20],
    leading_zero_nibbles: u8,
}

#[derive(Debug)]
struct CliArgs {
    factory: [u8; 20],
    init_code_hash: [u8; 32],
    start: u64,
    end: u64,
    min_zeros: u8,
    threads: usize,
    json: bool,
    collect_all: bool,
    output: Option<String>,
}

#[derive(Debug)]
struct CliError(String);

impl Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl Error for CliError {}

fn main() -> Result<(), Box<dyn Error>> {
    let args = parse_args()?;
    let started_at = Instant::now();

    let factory = args.factory;
    let init_code_hash = args.init_code_hash;
    let min_zeros = args.min_zeros;

    let worker_count = effective_threads(args.threads, args.end - args.start);
    let ranges = split_range(args.start, args.end - args.start, worker_count);

    let total_searched = Arc::new(AtomicU64::new(0));
    let stop = Arc::new(AtomicBool::new(false));

    // Channel for workers to stream hits to the main thread.
    let (tx, rx) = mpsc::channel::<Hit>();

    let mut handles = Vec::with_capacity(ranges.len());
    for (seg_start, seg_len) in ranges {
        let total_searched = Arc::clone(&total_searched);
        let stop = Arc::clone(&stop);
        let collect_all = args.collect_all;
        let tx = tx.clone();
        handles.push(thread::spawn(move || {
            let seg_end = seg_start + seg_len;
            let mut code = seg_start;

            while code < seg_end {
                if !collect_all && stop.load(Ordering::Relaxed) {
                    break;
                }

                let address = create2_address(factory, code, init_code_hash);
                let zeros = leading_zero_nibbles(address);

                if zeros >= min_zeros {
                    let hit = Hit {
                        builder_code: code,
                        address,
                        leading_zero_nibbles: zeros,
                    };
                    let _ = tx.send(hit);

                    if !collect_all {
                        stop.store(true, Ordering::Relaxed);
                        break;
                    }
                }

                code += 1;
            }

            total_searched.fetch_add(code - seg_start, Ordering::Relaxed);
        }));
    }
    drop(tx); // close sender so rx iterator terminates when all workers finish

    // Open output file if requested (append mode to survive restarts).
    let mut outfile = args.output.as_ref().map(|path| {
        // Write header if file is new or empty.
        let needs_header = fs::metadata(path).map(|m| m.len() == 0).unwrap_or(true);
        let mut f = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .expect("failed to open output file");
        if needs_header {
            if args.json {
                // JSON-lines mode: no header needed
            } else {
                writeln!(f, "builderCode,builderCodeHex,wallet,leadingZeros,fitsUint128")
                    .expect("write header");
            }
        }
        f
    });

    // Print header to stderr.
    eprintln!("factory: {}", hex_address(args.factory));
    eprintln!("init_code_hash: {}", hex_bytes(&args.init_code_hash));
    eprintln!("range: [{}..{})", args.start, args.end);
    eprintln!("min_zeros: {}", args.min_zeros);
    eprintln!("threads: {}", args.threads);
    if let Some(ref path) = args.output {
        eprintln!("output: {}", path);
    }
    eprintln!();

    // Stream hits as they arrive.
    let mut hit_count = 0u64;
    for hit in rx {
        hit_count += 1;
        let fits = hit.leading_zero_nibbles >= 8;

        if args.json {
            let line = format!(
                "{{\"builderCode\":{},\"builderCodeHex\":\"0x{:x}\",\"wallet\":\"{}\",\"leadingZeros\":{},\"fitsUint128\":{}}}",
                hit.builder_code,
                hit.builder_code,
                hex_address(hit.address),
                hit.leading_zero_nibbles,
                fits,
            );
            println!("{}", line);
            if let Some(ref mut f) = outfile {
                writeln!(f, "{}", line).expect("write to output file");
            }
        } else {
            let line = format!(
                "builderCode={} (0x{:x})  wallet={}  leading_zeros={}  fits_uint128={}",
                hit.builder_code,
                hit.builder_code,
                hex_address(hit.address),
                hit.leading_zero_nibbles,
                if fits { "YES" } else { "no" },
            );
            println!("{}", line);
            if let Some(ref mut f) = outfile {
                writeln!(
                    f,
                    "{},0x{:x},{},{},{}",
                    hit.builder_code,
                    hit.builder_code,
                    hex_address(hit.address),
                    hit.leading_zero_nibbles,
                    fits,
                )
                .expect("write to output file");
            }
        }
    }

    for handle in handles {
        handle.join().map_err(|_| CliError("worker panicked".into()))?;
    }

    let elapsed = started_at.elapsed();
    let searched = total_searched.load(Ordering::Relaxed);
    let hps = if elapsed.as_secs_f64() > 0.0 {
        searched as f64 / elapsed.as_secs_f64()
    } else {
        0.0
    };

    eprintln!();
    eprintln!("searched: {}", searched);
    eprintln!("hits: {}", hit_count);
    eprintln!("elapsed_seconds: {:.3}", elapsed.as_secs_f64());
    eprintln!("hashes_per_second: {:.0}", hps);

    Ok(())
}

/// Compute CREATE2 address for a given builderCode.
///
/// `address = keccak256(0xff ++ factory ++ bytes32(uint256(builderCode)) ++ initCodeHash)[12..32]`
fn create2_address(factory: [u8; 20], builder_code: u64, init_code_hash: [u8; 32]) -> [u8; 20] {
    let mut preimage = [0u8; 85];
    preimage[0] = 0xff;
    preimage[1..21].copy_from_slice(&factory);
    // salt = bytes32(uint256(builderCode)) → builderCode in last 8 bytes (big-endian u64),
    // but builderCode fits in u48 so bytes 21..53 are mostly zero.
    // bytes 21..45 = 0 (24 zero bytes), bytes 45..53 = builderCode as big-endian u64
    preimage[45..53].copy_from_slice(&builder_code.to_be_bytes());
    preimage[53..85].copy_from_slice(&init_code_hash);

    let hash = keccak256(&preimage);
    let mut address = [0u8; 20];
    address.copy_from_slice(&hash[12..32]);
    address
}

/// Count leading zero hex nibbles in an address.
/// For uint128 compatibility we need >= 8 (top 4 bytes zero).
fn leading_zero_nibbles(address: [u8; 20]) -> u8 {
    let mut count = 0u8;
    for byte in address {
        if byte == 0 {
            count += 2;
        } else if byte < 0x10 {
            count += 1;
            break;
        } else {
            break;
        }
    }
    count
}

fn parse_args() -> Result<CliArgs, CliError> {
    let mut factory = None;
    let mut init_code_hash = None;
    let mut start = 1u64; // builderCode 0 is invalid
    let mut end = None;
    let mut loops = None;
    let mut min_zeros = 8u8; // 8 hex nibbles = 4 bytes = fits in uint128
    let mut threads = available_threads();
    let mut json = false;
    let mut collect_all = true;
    let mut output = None;

    let mut args = env::args().skip(1);
    while let Some(flag) = args.next() {
        match flag.as_str() {
            "--factory" => factory = Some(parse_address(&take_value(&mut args, &flag)?)?),
            "--init-code-hash" => {
                init_code_hash = Some(parse_bytes32(&take_value(&mut args, &flag)?)?)
            }
            "--start" => start = parse_u64_arg(&take_value(&mut args, &flag)?, "start")?,
            "--end" => end = Some(parse_u64_arg(&take_value(&mut args, &flag)?, "end")?),
            "--loops" => loops = Some(parse_u64_arg(&take_value(&mut args, &flag)?, "loops")?),
            "--min-zeros" => {
                min_zeros = parse_u64_arg(&take_value(&mut args, &flag)?, "min-zeros")? as u8
            }
            "--threads" => {
                threads = parse_u64_arg(&take_value(&mut args, &flag)?, "threads")? as usize
            }
            "--json" => json = true,
            "--first" => collect_all = false,
            "--output" | "-o" => output = Some(take_value(&mut args, &flag)?),
            "--help" | "-h" => {
                print_help();
                std::process::exit(0);
            }
            other => {
                return Err(CliError(format!(
                    "unrecognized argument `{other}`; run with --help for usage"
                )));
            }
        }
    }

    let factory = factory.ok_or_else(|| CliError("missing required --factory".into()))?;
    let init_code_hash =
        init_code_hash.ok_or_else(|| CliError("missing required --init-code-hash".into()))?;

    if start == 0 {
        return Err(CliError("builderCode 0 is invalid; --start must be >= 1".into()));
    }

    let end = match (end, loops) {
        (Some(_), Some(_)) => return Err(CliError("pass --end or --loops, not both".into())),
        (Some(e), None) => e,
        (None, Some(l)) => start.checked_add(l).ok_or_else(|| CliError("range overflow".into()))?,
        (None, None) => MAX_U48 + 1, // full uint48 range
    };

    if end > MAX_U48 + 1 {
        return Err(CliError(format!("end {} exceeds uint48 max {}", end, MAX_U48)));
    }
    if start >= end {
        return Err(CliError("start must be less than end".into()));
    }
    if threads == 0 {
        return Err(CliError("threads must be at least 1".into()));
    }

    Ok(CliArgs {
        factory,
        init_code_hash,
        start,
        end,
        min_zeros,
        threads,
        json,
        collect_all,
        output,
    })
}

fn print_help() {
    println!(
        "\
Multithreaded miner for BuilderFactory builder codes whose CREATE2 wallet
addresses fit inside a uint128 (i.e. have leading zero bytes).

Required inputs:
  --factory <address>          BuilderFactory contract address
  --init-code-hash <bytes32>   keccak256 of BuilderWallet init code
                               (creationCode ++ abi.encode(factory))

Search controls:
  --start <uint48>             First builder code to try (default: 1)
  --end <uint48>               Exclusive upper bound (default: 2^48)
  --loops <count>              Number of codes to scan (alternative to --end)
  --min-zeros <n>              Minimum leading zero hex nibbles (default: 8, i.e. uint128-safe)
  --threads <n>                Worker threads (default: logical CPU count)
  --first                      Stop after finding the first hit (default: collect all)
  --json                       Emit JSON-lines output (one JSON object per hit)
  --output <path>              Append hits to a file (CSV or JSON-lines depending on --json)

The default --min-zeros 8 means the wallet address has 4 leading zero bytes,
so uint160(address) <= type(uint128).max and can be packed into RiskParameters.

Examples:
  # Find the first uint128-compatible builder code
  cargo run --release --manifest-path script/builder-code-miner/Cargo.toml -- \\
    --factory 0xYOUR_FACTORY_ADDRESS \\
    --init-code-hash 0xYOUR_INIT_CODE_HASH \\
    --first

  # Scan first 10M codes, collect all hits with >= 8 leading zero nibbles
  cargo run --release --manifest-path script/builder-code-miner/Cargo.toml -- \\
    --factory 0xYOUR_FACTORY_ADDRESS \\
    --init-code-hash 0xYOUR_INIT_CODE_HASH \\
    --start 1 --loops 10_000_000

  # Find codes with even more leading zeros (>= 10 nibbles = 5 zero bytes)
  cargo run --release --manifest-path script/builder-code-miner/Cargo.toml -- \\
    --factory 0xYOUR_FACTORY_ADDRESS \\
    --init-code-hash 0xYOUR_INIT_CODE_HASH \\
    --min-zeros 10 --first
"
    );
}

fn effective_threads(requested: usize, total: u64) -> usize {
    if total == 0 {
        return 1;
    }
    requested.min(total as usize).max(1)
}

fn split_range(start: u64, total: u64, segments: usize) -> Vec<(u64, u64)> {
    let mut result = Vec::with_capacity(segments);
    let base = total / segments as u64;
    let remainder = total % segments as u64;
    let mut cursor = start;

    for index in 0..segments {
        let extra = if (index as u64) < remainder { 1 } else { 0 };
        let len = base + extra;
        if len > 0 {
            result.push((cursor, len));
            cursor += len;
        }
    }
    result
}

fn available_threads() -> usize {
    thread::available_parallelism()
        .map(usize::from)
        .unwrap_or(1)
}

fn take_value(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, CliError> {
    args.next()
        .ok_or_else(|| CliError(format!("missing value for {flag}")))
}

fn parse_address(value: &str) -> Result<[u8; 20], CliError> {
    let bytes = parse_hex_bytes(value, 20, "address")?;
    let mut address = [0u8; 20];
    address.copy_from_slice(&bytes);
    Ok(address)
}

fn parse_bytes32(value: &str) -> Result<[u8; 32], CliError> {
    let bytes = parse_hex_bytes(value, 32, "bytes32")?;
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

fn parse_hex_bytes(value: &str, expected_len: usize, kind: &str) -> Result<Vec<u8>, CliError> {
    let hex = value.strip_prefix("0x").unwrap_or(value);
    if hex.len() != expected_len * 2 {
        return Err(CliError(format!(
            "{kind} must be {expected_len} bytes (got {} hex chars)",
            hex.len()
        )));
    }
    let mut bytes = Vec::with_capacity(expected_len);
    let chars = hex.as_bytes();
    for index in (0..chars.len()).step_by(2) {
        let high = from_hex_nibble(chars[index])
            .ok_or_else(|| CliError(format!("invalid hex character `{}`", chars[index] as char)))?;
        let low = from_hex_nibble(chars[index + 1]).ok_or_else(|| {
            CliError(format!(
                "invalid hex character `{}`",
                chars[index + 1] as char
            ))
        })?;
        bytes.push((high << 4) | low);
    }
    Ok(bytes)
}

fn from_hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn parse_u64_arg(value: &str, name: &str) -> Result<u64, CliError> {
    let sanitized = value.replace('_', "");
    if let Some(hex) = sanitized.strip_prefix("0x") {
        u64::from_str_radix(hex, 16).map_err(|_| CliError(format!("invalid {name}: `{value}`")))
    } else {
        sanitized
            .parse::<u64>()
            .map_err(|_| CliError(format!("invalid {name}: `{value}`")))
    }
}

fn hex_address(address: [u8; 20]) -> String {
    hex_bytes(&address)
}

fn hex_bytes(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(2 + bytes.len() * 2);
    out.push_str("0x");
    for byte in bytes {
        write!(&mut out, "{byte:02x}").expect("writing to string");
    }
    out
}

// ─── Keccak-256 (same standalone impl as pool-address-miner) ───

fn keccak256(data: &[u8]) -> [u8; 32] {
    let mut state = [0u64; 25];
    let mut chunks = data.chunks_exact(RATE_BYTES);
    for chunk in &mut chunks {
        absorb_block(&mut state, chunk);
        keccakf(&mut state);
    }
    let remainder = chunks.remainder();
    let mut final_block = [0u8; RATE_BYTES];
    final_block[..remainder.len()].copy_from_slice(remainder);
    final_block[remainder.len()] ^= 0x01;
    final_block[RATE_BYTES - 1] ^= 0x80;
    absorb_block(&mut state, &final_block);
    keccakf(&mut state);
    let mut out = [0u8; 32];
    for (index, byte) in out.iter_mut().enumerate() {
        let lane = state[index / 8];
        *byte = ((lane >> (8 * (index % 8))) & 0xff) as u8;
    }
    out
}

fn absorb_block(state: &mut [u64; 25], block: &[u8]) {
    for (lane_index, lane_bytes) in block.chunks_exact(8).enumerate() {
        let mut lane = [0u8; 8];
        lane.copy_from_slice(lane_bytes);
        state[lane_index] ^= u64::from_le_bytes(lane);
    }
}

fn keccakf(state: &mut [u64; 25]) {
    for round in 0..KECCAKF_ROUNDS {
        let mut c = [0u64; 5];
        for x in 0..5 {
            c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];
        }
        let mut d = [0u64; 5];
        for x in 0..5 {
            d[x] = c[(x + 4) % 5] ^ c[(x + 1) % 5].rotate_left(1);
        }
        for x in 0..5 {
            for y in 0..5 {
                state[x + 5 * y] ^= d[x];
            }
        }
        let mut b = [0u64; 25];
        for x in 0..5 {
            for y in 0..5 {
                let rotated = state[x + 5 * y].rotate_left(ROTATION_OFFSETS[x][y]);
                b[y + 5 * ((2 * x + 3 * y) % 5)] = rotated;
            }
        }
        for x in 0..5 {
            for y in 0..5 {
                state[x + 5 * y] =
                    b[x + 5 * y] ^ ((!b[((x + 1) % 5) + 5 * y]) & b[((x + 2) % 5) + 5 * y]);
            }
        }
        state[0] ^= ROUND_CONSTANTS[round];
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keccak_empty_matches_known_hash() {
        assert_eq!(
            hex_bytes(&keccak256(&[])),
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        );
    }

    #[test]
    fn create2_address_matches_solidity_formula() {
        // Verify against the Solidity CREATE2 formula:
        //   address = address(uint160(uint256(keccak256(abi.encodePacked(
        //     bytes1(0xff), factory, bytes32(uint256(builderCode)), initCodeHash
        //   )))))
        let factory = parse_address("0x1111111111111111111111111111111111111111").unwrap();
        let init_code_hash =
            parse_bytes32("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                .unwrap();

        let address = create2_address(factory, 1, init_code_hash);

        // Manually compute: preimage = ff + factory + bytes32(1) + init_code_hash
        let mut preimage = [0u8; 85];
        preimage[0] = 0xff;
        preimage[1..21].copy_from_slice(&factory);
        preimage[52] = 1; // bytes32(uint256(1)) → last byte is 1
        preimage[53..85].copy_from_slice(&init_code_hash);
        let hash = keccak256(&preimage);
        let mut expected = [0u8; 20];
        expected.copy_from_slice(&hash[12..32]);

        assert_eq!(address, expected);
    }

    #[test]
    fn leading_zero_nibbles_counts_correctly() {
        let mut addr = [0u8; 20];
        assert_eq!(leading_zero_nibbles(addr), 40); // all zeros

        addr[0] = 0x01;
        assert_eq!(leading_zero_nibbles(addr), 1); // 0x01... → 1 zero nibble (high nibble is 0)

        addr[0] = 0x10;
        assert_eq!(leading_zero_nibbles(addr), 0); // 0x10... → no leading zeros

        addr[0] = 0x00;
        addr[1] = 0x00;
        addr[2] = 0x00;
        addr[3] = 0x00;
        addr[4] = 0x0a;
        assert_eq!(leading_zero_nibbles(addr), 9); // 4 zero bytes (8) + one zero nibble (0x0a)
    }

    #[test]
    fn uint128_compatible_means_8_leading_zero_nibbles() {
        // An address like 0x00000000XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
        // has 4 zero bytes = 8 zero nibbles → fits in uint128
        let mut addr = [0xffu8; 20];
        addr[0] = 0;
        addr[1] = 0;
        addr[2] = 0;
        addr[3] = 0;
        assert_eq!(leading_zero_nibbles(addr), 8);
        // uint256(uint160(addr)) = addr as a 160-bit number
        // top 32 bits are zero → fits in uint128
    }

    #[test]
    fn salt_encoding_matches_solidity_bytes32_cast() {
        // In Solidity: bytes32 salt = bytes32(uint256(builderCode))
        // For builderCode = 0x123456, this is 32 bytes with 0x123456 at the end (big-endian)
        let code: u64 = 0x123456;
        let mut expected_salt = [0u8; 32];
        expected_salt[29] = 0x12;
        expected_salt[30] = 0x34;
        expected_salt[31] = 0x56;

        // Our preimage puts code.to_be_bytes() at offset 45..53 of the 85-byte preimage
        // Offset 45..53 in preimage = offset 24..32 in the salt portion (bytes 21..53)
        // That means bytes 24..32 of salt get the big-endian u64
        // For code=0x123456: be bytes = [0,0,0,0,0,0x12,0x34,0x56]
        // So salt[24]=0, salt[25]=0, ..., salt[29]=0x12, salt[30]=0x34, salt[31]=0x56
        // This matches expected_salt. ✓

        let mut actual_salt = [0u8; 32];
        actual_salt[24..32].copy_from_slice(&code.to_be_bytes());
        assert_eq!(actual_salt, expected_salt);
    }
}
