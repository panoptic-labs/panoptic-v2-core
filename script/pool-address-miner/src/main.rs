use std::cmp::Ordering;
use std::env;
use std::error::Error;
use std::fmt::{self, Display, Write};
use std::thread;
use std::time::Instant;

const CREATE3_PROXY_BYTECODE_HASH: [u8; 32] = [
    0x21, 0xc3, 0x5d, 0xbe, 0x1b, 0x34, 0x4a, 0x24, 0x88, 0xcf, 0x33, 0x21, 0xd6, 0xce, 0x54, 0x2f,
    0x8e, 0x9f, 0x30, 0x55, 0x44, 0xff, 0x09, 0xe4, 0x99, 0x3a, 0x62, 0x31, 0x9a, 0x49, 0x7c, 0x1f,
];
#[cfg(test)]
const CREATE3_PROXY_BYTECODE: [u8; 16] = [
    0x67, 0x36, 0x3d, 0x3d, 0x37, 0x36, 0x3d, 0x34, 0xf0, 0x3d, 0x52, 0x60, 0x08, 0x60, 0x18, 0xf3,
];
const MAX_U96: u128 = (1u128 << 96) - 1;
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Candidate {
    salt: u128,
    rarity: u8,
    address: [u8; 20],
}

#[derive(Clone, Copy, Debug)]
struct ChunkResult {
    best: Candidate,
    earliest_hit: Option<Candidate>,
    type_buckets: TypeBuckets,
}

#[derive(Clone, Copy, Debug)]
struct SearchResult {
    result: Candidate,
    hit_found: bool,
    lower_rarity_choices: TypeChoices,
    type_buckets: TypeBuckets,
}

#[derive(Clone, Copy, Debug)]
struct PoolKeyInput {
    currency0: [u8; 20],
    currency1: [u8; 20],
    fee: u32,
    tick_spacing: i32,
    hooks: [u8; 20],
}

#[derive(Debug)]
struct CliArgs {
    factory: [u8; 20],
    deployer: [u8; 20],
    risk_engine: [u8; 20],
    pool_id: [u8; 32],
    start_salt: u128,
    loops: Option<u128>,
    min_target_rarity: u8,
    threads: usize,
    until_target: bool,
    chunk_loops: u128,
    json: bool,
}

type TypeBuckets = [[Option<Candidate>; 16]; 41];
type TypeChoices = [Option<Candidate>; 16];

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
    let fixed_prefix = make_fixed_prefix(args.deployer, args.pool_id, args.risk_engine);
    let started_at = Instant::now();

    let (result, hashed_loops) = if args.until_target {
        search_until_target(&args, fixed_prefix)?
    } else {
        let loops = args.loops.ok_or_else(|| {
            CliError("missing required --loops when --until-target is not set".into())
        })?;
        (
            search_range(
                args.factory,
                fixed_prefix,
                args.start_salt,
                loops,
                args.min_target_rarity,
                args.threads,
            )?,
            loops,
        )
    };

    let elapsed = started_at.elapsed();
    let full_salt = make_full_salt(fixed_prefix, result.result.salt);
    let hashes_per_second = if elapsed.as_secs_f64() == 0.0 {
        0.0
    } else {
        hashed_loops as f64 / elapsed.as_secs_f64()
    };

    if args.json {
        print_json(
            &args,
            fixed_prefix,
            result,
            full_salt,
            hashed_loops,
            elapsed.as_secs_f64(),
            hashes_per_second,
        );
    } else {
        print_human(
            &args,
            fixed_prefix,
            result,
            full_salt,
            hashed_loops,
            elapsed.as_secs_f64(),
            hashes_per_second,
        );
    }

    Ok(())
}

fn parse_args() -> Result<CliArgs, CliError> {
    let mut factory = None;
    let mut deployer = None;
    let mut risk_engine = None;
    let mut pool_id = None;
    let mut pool_key = ParsedPoolKey::default();
    let mut start_salt = 0u128;
    let mut loops = None;
    let mut min_target_rarity = 0u8;
    let mut threads = available_threads();
    let mut until_target = false;
    let mut chunk_loops = 5_000_000u128;
    let mut json = false;

    let mut args = env::args().skip(1);
    while let Some(flag) = args.next() {
        match flag.as_str() {
            "--factory" => factory = Some(parse_address(&take_value(&mut args, &flag)?)?),
            "--deployer" => deployer = Some(parse_address(&take_value(&mut args, &flag)?)?),
            "--risk-engine" => risk_engine = Some(parse_address(&take_value(&mut args, &flag)?)?),
            "--pool-id" => pool_id = Some(parse_bytes32(&take_value(&mut args, &flag)?)?),
            "--currency0" => {
                pool_key.currency0 = Some(parse_address(&take_value(&mut args, &flag)?)?)
            }
            "--currency1" => {
                pool_key.currency1 = Some(parse_address(&take_value(&mut args, &flag)?)?)
            }
            "--fee" => pool_key.fee = Some(parse_u32_arg(&take_value(&mut args, &flag)?, "fee")?),
            "--tick-spacing" => {
                pool_key.tick_spacing = Some(parse_i32_arg(
                    &take_value(&mut args, &flag)?,
                    "tick spacing",
                )?)
            }
            "--hooks" => pool_key.hooks = Some(parse_address(&take_value(&mut args, &flag)?)?),
            "--salt" => start_salt = parse_u128_arg(&take_value(&mut args, &flag)?, "salt")?,
            "--loops" => loops = Some(parse_u128_arg(&take_value(&mut args, &flag)?, "loops")?),
            "--min-target-rarity" => {
                let parsed = parse_u128_arg(&take_value(&mut args, &flag)?, "min target rarity")?;
                min_target_rarity = u8::try_from(parsed)
                    .map_err(|_| CliError("min target rarity must fit in u8".into()))?;
            }
            "--threads" => {
                threads = parse_usize_arg(&take_value(&mut args, &flag)?, "threads")?;
            }
            "--chunk-loops" => {
                chunk_loops = parse_u128_arg(&take_value(&mut args, &flag)?, "chunk loops")?;
            }
            "--until-target" => until_target = true,
            "--json" => json = true,
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
    let deployer = deployer.ok_or_else(|| CliError("missing required --deployer".into()))?;
    let risk_engine =
        risk_engine.ok_or_else(|| CliError("missing required --risk-engine".into()))?;
    let pool_id = match (pool_id, pool_key.finish()?) {
        (Some(id), None) => id,
        (None, Some(key)) => encode_pool_id(key),
        (Some(_), Some(_)) => {
            return Err(CliError(
                "pass either --pool-id or the full PoolKey fields, not both".into(),
            ))
        }
        (None, None) => {
            return Err(CliError(
                "missing pool input; pass --pool-id or --currency0/--currency1/--fee/--tick-spacing/--hooks"
                    .into(),
            ))
        }
    };

    if start_salt > MAX_U96 {
        return Err(CliError(format!(
            "start salt {start_salt} exceeds uint96 maximum {MAX_U96}"
        )));
    }
    if min_target_rarity > 40 {
        return Err(CliError(
            "min target rarity must be between 0 and 40".into(),
        ));
    }
    if threads == 0 {
        return Err(CliError("threads must be at least 1".into()));
    }
    if until_target && min_target_rarity == 0 {
        return Err(CliError(
            "--until-target requires --min-target-rarity greater than 0".into(),
        ));
    }
    if chunk_loops == 0 {
        return Err(CliError("chunk loops must be at least 1".into()));
    }
    if let Some(loops) = loops {
        validate_range(start_salt, loops)?;
    }

    Ok(CliArgs {
        factory,
        deployer,
        risk_engine,
        pool_id,
        start_salt,
        loops,
        min_target_rarity,
        threads,
        until_target,
        chunk_loops,
        json,
    })
}

fn search_until_target(
    args: &CliArgs,
    fixed_prefix: [u8; 20],
) -> Result<(SearchResult, u128), CliError> {
    let mut next_salt = args.start_salt;
    let mut total_loops = 0u128;
    let mut global_best = Candidate {
        salt: args.start_salt,
        rarity: 0,
        address: address_of_clone3(args.factory, make_full_salt(fixed_prefix, args.start_salt)),
    };
    global_best.rarity = leading_zero_hex_chars(global_best.address);
    let mut global_type_buckets = empty_type_buckets();
    record_type_candidate(&mut global_type_buckets, global_best);

    loop {
        if next_salt > MAX_U96 {
            return Ok((
                SearchResult {
                    result: global_best,
                    hit_found: false,
                    lower_rarity_choices: lower_rarity_choices(
                        global_best.rarity,
                        &global_type_buckets,
                    ),
                    type_buckets: global_type_buckets,
                },
                total_loops,
            ));
        }

        let remaining = (MAX_U96 - next_salt) + 1;
        let loops = args.chunk_loops.min(remaining);
        let result = search_range(
            args.factory,
            fixed_prefix,
            next_salt,
            loops,
            args.min_target_rarity,
            args.threads,
        )?;
        total_loops += loops;

        merge_type_buckets(&mut global_type_buckets, &result.type_buckets);

        if result.hit_found {
            return Ok((
                SearchResult {
                    result: result.result,
                    hit_found: true,
                    lower_rarity_choices: lower_rarity_choices(
                        result.result.rarity,
                        &global_type_buckets,
                    ),
                    type_buckets: global_type_buckets,
                },
                total_loops,
            ));
        }

        if is_better(result.result, global_best) {
            global_best = result.result;
        }

        if !args.json {
            let lower_choices = lower_rarity_choices(global_best.rarity, &global_type_buckets);
            let lower_count = count_type_choices(&lower_choices);
            eprintln!(
                "searched [{}..{}), best so far rarity {} at salt {} ({})",
                next_salt,
                next_salt + loops,
                global_best.rarity,
                global_best.salt,
                hex_address(global_best.address),
            );
            if global_best.rarity > 0 && lower_count > 0 {
                eprintln!(
                    "  rarity {} type spectrum ({}/16): {}",
                    global_best.rarity - 1,
                    lower_count,
                    progress_type_spectrum(&lower_choices),
                );
            }
        }

        next_salt += loops;
    }
}

fn search_range(
    factory: [u8; 20],
    fixed_prefix: [u8; 20],
    start_salt: u128,
    loops: u128,
    min_target_rarity: u8,
    threads: usize,
) -> Result<SearchResult, CliError> {
    validate_range(start_salt, loops)?;

    let worker_count = effective_threads(threads, loops);
    let ranges = split_range(start_salt, loops, worker_count);
    let mut handles = Vec::with_capacity(ranges.len());

    for (segment_start, segment_len) in ranges {
        let factory_copy = factory;
        let fixed_prefix_copy = fixed_prefix;
        handles.push(thread::spawn(move || {
            search_segment(
                factory_copy,
                fixed_prefix_copy,
                segment_start,
                segment_len,
                min_target_rarity,
            )
        }));
    }

    let mut global_best: Option<Candidate> = None;
    let mut earliest_hit: Option<Candidate> = None;
    let mut type_buckets = empty_type_buckets();

    for handle in handles {
        let chunk = handle
            .join()
            .map_err(|_| CliError("miner thread panicked".into()))?;

        global_best = Some(match global_best {
            Some(existing) if !is_better(chunk.best, existing) => existing,
            _ => chunk.best,
        });

        if let Some(hit) = chunk.earliest_hit {
            earliest_hit = Some(match earliest_hit {
                Some(existing) if existing.salt <= hit.salt => existing,
                _ => hit,
            });
        }

        merge_type_buckets(&mut type_buckets, &chunk.type_buckets);
    }

    if let Some(hit) = earliest_hit {
        Ok(SearchResult {
            result: hit,
            hit_found: true,
            lower_rarity_choices: lower_rarity_choices(hit.rarity, &type_buckets),
            type_buckets,
        })
    } else {
        let best = global_best.expect("at least one worker segment");
        Ok(SearchResult {
            result: best,
            hit_found: false,
            lower_rarity_choices: lower_rarity_choices(best.rarity, &type_buckets),
            type_buckets,
        })
    }
}

fn search_segment(
    factory: [u8; 20],
    fixed_prefix: [u8; 20],
    start_salt: u128,
    loops: u128,
    min_target_rarity: u8,
) -> ChunkResult {
    let mut best = evaluate_candidate(factory, fixed_prefix, start_salt);
    let mut type_buckets = empty_type_buckets();
    record_type_candidate(&mut type_buckets, best);
    let mut earliest_hit = if best.rarity >= min_target_rarity {
        Some(best)
    } else {
        None
    };

    if earliest_hit.is_some() {
        return ChunkResult {
            best,
            earliest_hit,
            type_buckets,
        };
    }

    let end = start_salt + loops;
    let mut salt = start_salt + 1;
    while salt < end {
        let candidate = evaluate_candidate(factory, fixed_prefix, salt);
        record_type_candidate(&mut type_buckets, candidate);
        if is_better(candidate, best) {
            best = candidate;
        }
        if candidate.rarity >= min_target_rarity {
            earliest_hit = Some(candidate);
            break;
        }
        salt += 1;
    }

    ChunkResult {
        best,
        earliest_hit,
        type_buckets,
    }
}

fn evaluate_candidate(factory: [u8; 20], fixed_prefix: [u8; 20], user_salt: u128) -> Candidate {
    let full_salt = make_full_salt(fixed_prefix, user_salt);
    let address = address_of_clone3(factory, full_salt);
    Candidate {
        salt: user_salt,
        rarity: leading_zero_hex_chars(address),
        address,
    }
}

fn empty_type_buckets() -> TypeBuckets {
    [[None; 16]; 41]
}

fn record_type_candidate(type_buckets: &mut TypeBuckets, candidate: Candidate) {
    let rarity_index = candidate.rarity as usize;
    let type_index = last_nibble(candidate.address) as usize;
    let slot = &mut type_buckets[rarity_index][type_index];
    if slot.is_none_or(|existing| candidate.salt < existing.salt) {
        *slot = Some(candidate);
    }
}

fn merge_type_buckets(dst: &mut TypeBuckets, src: &TypeBuckets) {
    for rarity in 0..dst.len() {
        for type_index in 0..dst[rarity].len() {
            if let Some(candidate) = src[rarity][type_index]
                && dst[rarity][type_index].is_none_or(|existing| candidate.salt < existing.salt)
            {
                dst[rarity][type_index] = Some(candidate);
            }
        }
    }
}

fn lower_rarity_choices(best_rarity: u8, type_buckets: &TypeBuckets) -> TypeChoices {
    if best_rarity == 0 {
        [None; 16]
    } else {
        type_buckets[(best_rarity - 1) as usize]
    }
}

fn effective_threads(requested: usize, loops: u128) -> usize {
    if loops == 0 {
        return 1;
    }
    let max_workers = if loops > usize::MAX as u128 {
        requested
    } else {
        requested.min(loops as usize)
    };
    max_workers.max(1)
}

fn split_range(start_salt: u128, loops: u128, segments: usize) -> Vec<(u128, u128)> {
    let mut result = Vec::with_capacity(segments);
    let base = loops / segments as u128;
    let remainder = loops % segments as u128;
    let mut cursor = start_salt;

    for index in 0..segments {
        let extra = u128::from(index < remainder as usize);
        let len = base + extra;
        if len > 0 {
            result.push((cursor, len));
            cursor += len;
        }
    }

    result
}

fn validate_range(start_salt: u128, loops: u128) -> Result<(), CliError> {
    if loops == 0 {
        return Err(CliError("loops must be at least 1".into()));
    }
    let end = start_salt
        .checked_add(loops)
        .ok_or_else(|| CliError("salt range overflows u128".into()))?;
    if end == 0 || end - 1 > MAX_U96 {
        return Err(CliError(format!(
            "salt range [{}..{}) exceeds uint96 maximum {}",
            start_salt, end, MAX_U96
        )));
    }
    Ok(())
}

fn encode_pool_id(key: PoolKeyInput) -> [u8; 32] {
    let mut encoded = [0u8; 160];
    write_address_word(&mut encoded[0..32], key.currency0);
    write_address_word(&mut encoded[32..64], key.currency1);
    write_uint_word(&mut encoded[64..96], key.fee as u128);
    write_int24_word(&mut encoded[96..128], key.tick_spacing);
    write_address_word(&mut encoded[128..160], key.hooks);
    keccak256(&encoded)
}

fn make_fixed_prefix(deployer: [u8; 20], pool_id: [u8; 32], risk_engine: [u8; 20]) -> [u8; 20] {
    let mut prefix = [0u8; 20];
    prefix[0..10].copy_from_slice(&deployer[0..10]);
    // The factory does `uint40(uint256(PoolId.unwrap(idV4)) >> 120)`, which keeps
    // bytes 12..16 of the 32-byte pool id after the uint40 truncation.
    prefix[10..15].copy_from_slice(&pool_id[12..17]);
    prefix[15..20].copy_from_slice(&risk_engine[0..5]);
    prefix
}

fn make_full_salt(fixed_prefix: [u8; 20], user_salt: u128) -> [u8; 32] {
    let mut full = [0u8; 32];
    full[0..20].copy_from_slice(&fixed_prefix);
    full[20..32].copy_from_slice(&u96_to_be_bytes(user_salt));
    full
}

fn address_of_clone3(factory: [u8; 20], salt: [u8; 32]) -> [u8; 20] {
    let mut proxy_preimage = [0u8; 85];
    proxy_preimage[0] = 0xff;
    proxy_preimage[1..21].copy_from_slice(&factory);
    proxy_preimage[21..53].copy_from_slice(&salt);
    proxy_preimage[53..85].copy_from_slice(&CREATE3_PROXY_BYTECODE_HASH);
    let proxy_hash = keccak256(&proxy_preimage);

    let mut deployed_preimage = [0u8; 23];
    deployed_preimage[0] = 0xd6;
    deployed_preimage[1] = 0x94;
    deployed_preimage[2..22].copy_from_slice(&proxy_hash[12..32]);
    deployed_preimage[22] = 0x01;
    let deployed_hash = keccak256(&deployed_preimage);

    let mut address = [0u8; 20];
    address.copy_from_slice(&deployed_hash[12..32]);
    address
}

fn leading_zero_hex_chars(address: [u8; 20]) -> u8 {
    let mut total = 0u8;
    for byte in address {
        match byte.cmp(&0) {
            Ordering::Equal => total += 2,
            Ordering::Greater if byte < 0x10 => {
                total += 1;
                break;
            }
            _ => break,
        }
    }
    total
}

fn is_better(candidate: Candidate, current: Candidate) -> bool {
    candidate.rarity > current.rarity
        || (candidate.rarity == current.rarity && candidate.salt < current.salt)
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

fn parse_u128_arg(value: &str, name: &str) -> Result<u128, CliError> {
    let sanitized = value.replace('_', "");
    if let Some(hex) = sanitized.strip_prefix("0x") {
        u128::from_str_radix(hex, 16).map_err(|_| CliError(format!("invalid {name}: `{value}`")))
    } else {
        sanitized
            .parse::<u128>()
            .map_err(|_| CliError(format!("invalid {name}: `{value}`")))
    }
}

fn parse_u32_arg(value: &str, name: &str) -> Result<u32, CliError> {
    let parsed = parse_u128_arg(value, name)?;
    u32::try_from(parsed).map_err(|_| CliError(format!("{name} must fit in u32")))
}

fn parse_usize_arg(value: &str, name: &str) -> Result<usize, CliError> {
    let parsed = parse_u128_arg(value, name)?;
    usize::try_from(parsed).map_err(|_| CliError(format!("{name} must fit in usize")))
}

fn parse_i32_arg(value: &str, name: &str) -> Result<i32, CliError> {
    let sanitized = value.replace('_', "");
    if let Some(hex) = sanitized.strip_prefix("-0x") {
        let magnitude = i64::from_str_radix(hex, 16)
            .map_err(|_| CliError(format!("invalid {name}: `{value}`")))?;
        i32::try_from(-magnitude).map_err(|_| CliError(format!("{name} must fit in i32")))
    } else if let Some(hex) = sanitized.strip_prefix("0x") {
        let magnitude = i64::from_str_radix(hex, 16)
            .map_err(|_| CliError(format!("invalid {name}: `{value}`")))?;
        i32::try_from(magnitude).map_err(|_| CliError(format!("{name} must fit in i32")))
    } else {
        sanitized
            .parse::<i32>()
            .map_err(|_| CliError(format!("invalid {name}: `{value}`")))
    }
}

fn write_address_word(dst: &mut [u8], address: [u8; 20]) {
    dst.fill(0);
    dst[12..32].copy_from_slice(&address);
}

fn write_uint_word(dst: &mut [u8], value: u128) {
    dst.fill(0);
    dst[16..32].copy_from_slice(&value.to_be_bytes());
}

fn write_int24_word(dst: &mut [u8], value: i32) {
    if !(-(1 << 23)..(1 << 23)).contains(&value) {
        panic!("tick spacing {value} does not fit in int24");
    }
    let fill = if value < 0 { 0xff } else { 0x00 };
    dst.fill(fill);
    let encoded = value.to_be_bytes();
    dst[29..32].copy_from_slice(&encoded[1..4]);
}

fn u96_to_be_bytes(value: u128) -> [u8; 12] {
    if value > MAX_U96 {
        panic!("value {value} does not fit in u96");
    }
    let raw = value.to_be_bytes();
    let mut out = [0u8; 12];
    out.copy_from_slice(&raw[4..16]);
    out
}

fn print_help() {
    println!(
        "\
Multithreaded local miner for PanopticFactoryV4 pool addresses.
The output also includes distinct last-nibble type choices at one rarity below the best result found.

Required inputs:
  --factory <address>        PanopticFactoryV4 address; CREATE3 depends on this
  --deployer <address>       Exact factory msg.sender for deployNewPool
  --risk-engine <address>    Risk engine passed to deployNewPool

Important:
  The deployer is the actual caller seen by the factory, not necessarily the signer.
  If a Safe, router, or another contract sends the transaction, use that contract address.

Pool input:
  --pool-id <bytes32>
  or
  --currency0 <address> --currency1 <address> --fee <uint24> --tick-spacing <int24> --hooks <address>

Search controls:
  --salt <uint96>            Starting user salt (default: 0)
  --loops <count>            Number of salts to scan
  --min-target-rarity <n>    Leading zero hex chars target (0..40, default: 0)
  --threads <n>              Worker threads (default: logical CPU count)
  --until-target             Repeatedly scan chunks until a target hit is found
  --chunk-loops <count>      Chunk size used with --until-target (default: 5000000)
  --json                     Emit machine-readable JSON

Examples:
  cargo run --release --manifest-path script/pool-address-miner/Cargo.toml -- \\
    --factory 0x1111111111111111111111111111111111111111 \\
    --deployer 0x2222222222222222222222222222222222222222 \\
    --risk-engine 0x3333333333333333333333333333333333333333 \\
    --pool-id 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \\
    --salt 0 --loops 1000000 --min-target-rarity 6

  cargo run --release --manifest-path script/pool-address-miner/Cargo.toml -- \\
    --factory 0x1111111111111111111111111111111111111111 \\
    --deployer 0x2222222222222222222222222222222222222222 \\
    --risk-engine 0x3333333333333333333333333333333333333333 \\
    --currency0 0x0000000000000000000000000000000000000000 \\
    --currency1 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \\
    --fee 500 --tick-spacing 10 --hooks 0x0000000000000000000000000000000000000000 \\
    --salt 0 --until-target --min-target-rarity 7 --chunk-loops 2000000
"
    );
}

fn print_human(
    args: &CliArgs,
    fixed_prefix: [u8; 20],
    result: SearchResult,
    full_salt: [u8; 32],
    hashed_loops: u128,
    elapsed_secs: f64,
    hashes_per_second: f64,
) {
    println!("factory: {}", hex_address(args.factory));
    println!("deployer: {}", hex_address(args.deployer));
    println!("risk_engine: {}", hex_address(args.risk_engine));
    println!("pool_id: {}", hex_bytes(&args.pool_id));
    println!("start_salt: {}", args.start_salt);
    if let Some(loops) = args.loops {
        println!("loops: {}", loops);
    } else {
        println!("loops: until target");
    }
    println!("threads: {}", args.threads);
    println!("min_target_rarity: {}", args.min_target_rarity);
    println!("fixed_salt_prefix: {}", hex_bytes(&fixed_prefix));
    println!(
        "result_kind: {}",
        if result.hit_found {
            "target_hit"
        } else {
            "best_in_range"
        }
    );
    println!("best_salt: {}", result.result.salt);
    println!("full_salt: {}", hex_bytes(&full_salt));
    println!("address: {}", hex_address(result.result.address));
    println!("rarity: {}", result.result.rarity);
    println!("hashed_loops: {}", hashed_loops);
    println!("elapsed_seconds: {:.6}", elapsed_secs);
    println!("hashes_per_second: {:.0}", hashes_per_second);

    let lower_rarity = result.result.rarity.saturating_sub(1);
    let lower_count = count_type_choices(&result.lower_rarity_choices);
    if lower_count > 0 {
        println!(
            "lower_rarity_type_choices: {} / 16 at rarity {}",
            lower_count, lower_rarity
        );
        for (type_index, candidate) in result.lower_rarity_choices.iter().enumerate() {
            if let Some(candidate) = candidate {
                println!(
                    "  type=0x{:x} salt={} address={} rarity={}",
                    type_index,
                    candidate.salt,
                    hex_address(candidate.address),
                    candidate.rarity,
                );
            }
        }
    }
}

fn print_json(
    args: &CliArgs,
    fixed_prefix: [u8; 20],
    result: SearchResult,
    full_salt: [u8; 32],
    hashed_loops: u128,
    elapsed_secs: f64,
    hashes_per_second: f64,
) {
    let lower_rarity = result.result.rarity.saturating_sub(1);
    println!(
        "{{\
\"factory\":\"{}\",\
\"deployer\":\"{}\",\
\"riskEngine\":\"{}\",\
\"poolId\":\"{}\",\
\"startSalt\":\"{}\",\
\"threads\":{},\
\"minTargetRarity\":{},\
\"fixedSaltPrefix\":\"{}\",\
\"resultKind\":\"{}\",\
\"bestSalt\":\"{}\",\
\"fullSalt\":\"{}\",\
\"address\":\"{}\",\
\"rarity\":{},\
\"lowerRarityChoicesRarity\":{},\
\"lowerRarityChoices\":[{}],\
\"hashedLoops\":\"{}\",\
\"elapsedSeconds\":{:.6},\
\"hashesPerSecond\":{:.0}\
}}",
        hex_address(args.factory),
        hex_address(args.deployer),
        hex_address(args.risk_engine),
        hex_bytes(&args.pool_id),
        args.start_salt,
        args.threads,
        args.min_target_rarity,
        hex_bytes(&fixed_prefix),
        if result.hit_found {
            "target_hit"
        } else {
            "best_in_range"
        },
        result.result.salt,
        hex_bytes(&full_salt),
        hex_address(result.result.address),
        result.result.rarity,
        lower_rarity,
        json_type_choices(&result.lower_rarity_choices),
        hashed_loops,
        elapsed_secs,
        hashes_per_second,
    );
}

fn hex_address(address: [u8; 20]) -> String {
    hex_bytes(&address)
}

fn last_nibble(address: [u8; 20]) -> u8 {
    address[19] & 0x0f
}

fn count_type_choices(choices: &TypeChoices) -> usize {
    choices
        .iter()
        .filter(|candidate| candidate.is_some())
        .count()
}

fn json_type_choices(choices: &TypeChoices) -> String {
    let mut out = String::new();
    let mut first = true;
    for (type_index, candidate) in choices.iter().enumerate() {
        if let Some(candidate) = candidate {
            if !first {
                out.push(',');
            }
            first = false;
            write!(
                &mut out,
                "{{\"type\":\"0x{:x}\",\"salt\":\"{}\",\"address\":\"{}\",\"rarity\":{}}}",
                type_index,
                candidate.salt,
                hex_address(candidate.address),
                candidate.rarity,
            )
            .expect("writing to string");
        }
    }
    out
}

fn progress_type_spectrum(choices: &TypeChoices) -> String {
    let mut out = String::new();
    let mut first = true;
    for (type_index, candidate) in choices.iter().enumerate() {
        if let Some(candidate) = candidate {
            if !first {
                out.push_str(", ");
            }
            first = false;
            write!(&mut out, "0x{:x}:{}", type_index, candidate.salt).expect("writing to string");
        }
    }
    out
}

fn hex_bytes(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(2 + bytes.len() * 2);
    out.push_str("0x");
    for byte in bytes {
        write!(&mut out, "{byte:02x}").expect("writing to string");
    }
    out
}

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

#[derive(Default)]
struct ParsedPoolKey {
    currency0: Option<[u8; 20]>,
    currency1: Option<[u8; 20]>,
    fee: Option<u32>,
    tick_spacing: Option<i32>,
    hooks: Option<[u8; 20]>,
}

impl ParsedPoolKey {
    fn finish(self) -> Result<Option<PoolKeyInput>, CliError> {
        let all_missing = self.currency0.is_none()
            && self.currency1.is_none()
            && self.fee.is_none()
            && self.tick_spacing.is_none()
            && self.hooks.is_none();

        if all_missing {
            return Ok(None);
        }

        let currency0 = self
            .currency0
            .ok_or_else(|| CliError("missing --currency0".into()))?;
        let currency1 = self
            .currency1
            .ok_or_else(|| CliError("missing --currency1".into()))?;
        let fee = self.fee.ok_or_else(|| CliError("missing --fee".into()))?;
        let tick_spacing = self
            .tick_spacing
            .ok_or_else(|| CliError("missing --tick-spacing".into()))?;
        let hooks = self
            .hooks
            .ok_or_else(|| CliError("missing --hooks".into()))?;

        if fee > 0x00ff_ffff {
            return Err(CliError("fee must fit in uint24".into()));
        }
        if !(-(1 << 23)..(1 << 23)).contains(&tick_spacing) {
            return Err(CliError("tick spacing must fit in int24".into()));
        }
        if currency0 > currency1 {
            return Err(CliError(
                "currency0 must be the numerically lower currency, matching Uniswap v4 PoolKey ordering"
                    .into(),
            ));
        }

        Ok(Some(PoolKeyInput {
            currency0,
            currency1,
            fee,
            tick_spacing,
            hooks,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keccak_known_vectors_match() {
        assert_eq!(
            hex_bytes(&keccak256(&[])),
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        );
        assert_eq!(
            keccak256(&CREATE3_PROXY_BYTECODE),
            CREATE3_PROXY_BYTECODE_HASH
        );
    }

    #[test]
    fn pool_id_fixture_matches_contract_encoding() {
        let key = PoolKeyInput {
            currency0: parse_address("0x0000000000000000000000000000000000000000").unwrap(),
            currency1: parse_address("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2").unwrap(),
            fee: 500,
            tick_spacing: 10,
            hooks: parse_address("0x0000000000000000000000000000000000000000").unwrap(),
        };
        assert_eq!(
            hex_bytes(&encode_pool_id(key)),
            "0xe541b44249066366e0edc2f6b71f431169e5747a50cbc3506e85203079af215a"
        );
    }

    #[test]
    fn salt_and_address_fixture_match_contract_derivation() {
        let factory = parse_address("0x1111111111111111111111111111111111111111").unwrap();
        let deployer = parse_address("0x2222222222222222222222222222222222222222").unwrap();
        let risk_engine = parse_address("0x3333333333333333333333333333333333333333").unwrap();
        let pool_id =
            parse_bytes32("0xe541b44249066366e0edc2f6b71f431169e5747a50cbc3506e85203079af215a")
                .unwrap();
        let fixed_prefix = make_fixed_prefix(deployer, pool_id, risk_engine);
        let full_salt = make_full_salt(fixed_prefix, 12345);
        let address = address_of_clone3(factory, full_salt);

        assert_eq!(
            hex_bytes(&fixed_prefix),
            "0x22222222222222222222b71f4311693333333333"
        );
        assert_eq!(
            hex_bytes(&full_salt),
            "0x22222222222222222222b71f4311693333333333000000000000000000003039"
        );
        assert_eq!(
            hex_bytes(&address),
            "0x3f5ed4354e0083a2e1fb427ca496b78570d5dca3"
        );
        assert_eq!(leading_zero_hex_chars(address), 0);
    }

    #[test]
    fn user_fixture_matches_onchain_cast_call() {
        let factory = parse_address("0x000000000000048a877bF34C0cF3F25510667a1e").unwrap();
        let deployer = parse_address("0x490539F53dd0344287b8C8FD85D0Ecb8eEF44DD0").unwrap();
        let risk_engine = parse_address("0x0000000000000E65545005B26207D7edFd031260").unwrap();
        let pool_id =
            parse_bytes32("0xdce6394339af00981949f5f3baf27e3610c76326a700af57e4b3e3ae4977f78d")
                .unwrap();
        let fixed_prefix = make_fixed_prefix(deployer, pool_id, risk_engine);
        let full_salt = make_full_salt(fixed_prefix, 51_587_321_653);
        let address = address_of_clone3(factory, full_salt);

        assert_eq!(
            hex_bytes(&fixed_prefix),
            "0x490539f53dd0344287b8baf27e36100000000000"
        );
        assert_eq!(
            hex_bytes(&full_salt),
            "0x490539f53dd0344287b8baf27e36100000000000000000000000000c02d80f35"
        );
        assert_eq!(
            hex_bytes(&address),
            "0x6f9dea3afc00a8e131d24753012718796da98263"
        );
    }

    #[test]
    fn best_candidate_prefers_earlier_salt_on_tie() {
        let first = Candidate {
            salt: 10,
            rarity: 4,
            address: [0; 20],
        };
        let second = Candidate {
            salt: 11,
            rarity: 4,
            address: [0; 20],
        };
        assert!(is_better(first, second));
        assert!(!is_better(second, first));
    }

    #[test]
    fn lower_rarity_choices_keep_one_candidate_per_type() {
        let mut buckets = empty_type_buckets();

        record_type_candidate(&mut buckets, synthetic_candidate(200, 6, 0x3));
        record_type_candidate(&mut buckets, synthetic_candidate(100, 6, 0x3));
        record_type_candidate(&mut buckets, synthetic_candidate(150, 6, 0xa));
        record_type_candidate(&mut buckets, synthetic_candidate(90, 7, 0x1));

        let choices = lower_rarity_choices(7, &buckets);

        assert_eq!(count_type_choices(&choices), 2);
        assert_eq!(choices[0x3].unwrap().salt, 100);
        assert_eq!(choices[0xa].unwrap().salt, 150);
        assert!(choices[0x1].is_none());
    }

    fn synthetic_candidate(salt: u128, rarity: u8, last_nibble: u8) -> Candidate {
        let mut address = [0u8; 20];
        address[19] = last_nibble & 0x0f;
        Candidate {
            salt,
            rarity,
            address,
        }
    }
}
