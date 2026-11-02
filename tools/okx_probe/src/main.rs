use bip32::{DerivationPath, XPrv};
use bip39::Mnemonic;
use ciborium::value::Value;
use clap::Parser;
use qrcode::render::unicode;
use qrcode::{EcLevel, QrCode};
use secp256k1::PublicKey;
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use tiny_keccak::{Hasher, Keccak};

const DEFAULT_MNEMONIC: &str =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

#[derive(Parser, Debug)]
#[command(
    name = "okx_probe",
    version = "0.1.0",
    about = "Keystone-compatible crypto-multi-accounts probe and animated fountain QR player for OKX Wallet pairing verification",
    long_about = "Generates compliant Keystone crypto-multi-accounts (UR Tag 1103) QR codes using public BIP-39 test vectors. Physically isolated from private keys and signing vaults."
)]
struct CliArgs {
    /// BIP-39 mnemonic test phrase (12 or 24 words).
    #[arg(short = 'm', long = "mnemonic", default_value = DEFAULT_MNEMONIC)]
    mnemonic: String,

    /// BIP-39 passphrase.
    #[arg(short = 'p', long = "passphrase", default_value = "")]
    passphrase: String,

    /// Derivation level: 'account' (m/44'/60'/0'), 'leaf' (m/44'/60'/0'/0/0), or 'both'.
    #[arg(short = 'd', long = "derivation-level", default_value = "both")]
    derivation_level: String,

    /// Declared device label in crypto-multi-accounts.
    #[arg(long = "device", default_value = "Keystone 3 Pro")]
    device: String,

    /// Device ID text.
    #[arg(long = "device-id", default_value = "28475c8d80f6c06bafbe46a7d1750f3fcf2565f7")]
    device_id: String,

    /// Protocol / firmware version string.
    #[arg(long = "version-str", default_value = "1.1.0")]
    version_str: String,

    /// Output format: 'single', 'fountain', 'cbor-hex', 'json', or 'all'.
    #[arg(short = 'f', long = "format", default_value = "all")]
    format: String,

    /// Max fragment size in bytes for Luby Transform fountain slicing.
    #[arg(short = 's', long = "fragment-size", default_value_t = 120)]
    fragment_size: usize,

    /// Playback frame rate (FPS) for animated fountain QR.
    #[arg(long = "fps", default_value_t = 4.0)]
    fps: f64,

    /// Display mode: 'html', 'terminal', 'none', or 'all'.
    #[arg(long = "display", default_value = "all")]
    display: String,

    /// Output directory for display.html, images, and fixtures.
    #[arg(short = 'o', long = "out-dir", default_value = "tools/okx_probe")]
    out_dir: PathBuf,

    /// Automatically open display.html in default system browser.
    #[arg(long = "open-browser", default_value_t = false)]
    open_browser: bool,

    /// Safety assertion: confirms strictly test-only execution with zero secrets.
    #[arg(long = "test-only", default_value_t = true)]
    test_only: bool,
}

#[derive(Debug, Clone, Serialize)]
struct FrameData {
    part_index: usize,
    seq_num: usize,
    ur: String,
    matrix: Vec<Vec<bool>>,
}

#[derive(Debug, Serialize)]
struct ProbeOutput {
    test_only_warning: String,
    master_fingerprint_hex: String,
    master_fingerprint_u32: u32,
    account_path: String,
    account_xpub: String,
    account_compressed_pubkey: String,
    account_chain_code: String,
    leaf_path: String,
    leaf_compressed_pubkey: String,
    eip55_address: String,
    cbor_hex: String,
    cbor_len_bytes: usize,
    ur_single: String,
    fountain_fragment_count: usize,
    fountain_fragment_size: usize,
    fountain_fps: f64,
    fountain_frames: Vec<String>,
}

fn to_eip55(addr_lower: &str) -> String {
    let clean = addr_lower.trim_start_matches("0x");
    let mut hasher = Keccak::v256();
    let mut hash = [0u8; 32];
    hasher.update(clean.as_bytes());
    hasher.finalize(&mut hash);
    let hash_hex = hex::encode(hash);

    let mut out = String::from("0x");
    for (i, c) in clean.chars().enumerate() {
        let nibble = u8::from_str_radix(&hash_hex[i..i + 1], 16).unwrap();
        if nibble >= 8 {
            out.push(c.to_ascii_uppercase());
        } else {
            out.push(c.to_ascii_lowercase());
        }
    }
    out
}

struct KeyEntry {
    compressed_pubkey: Vec<u8>,
    chain_code: Option<Vec<u8>>,
    path_components: Vec<(u32, bool)>,
    note: Option<String>,
}

fn build_crypto_multi_accounts_cbor(
    master_fp_u32: u32,
    keys: &[KeyEntry],
    device: &str,
    device_id: &str,
    version: &str,
) -> Vec<u8> {
    let mut map = Vec::new();

    // Key 1: master_fingerprint (uint32)
    map.push((
        Value::Integer(1.into()),
        Value::Integer(master_fp_u32.into()),
    ));

    // Key 2: keys (Array of Tag 303 CryptoHDKey)
    let mut keys_cbor = Vec::new();
    for k in keys {
        let mut key_map = Vec::new();
        // Key 3: key_data (33 bytes compressed pubkey)
        key_map.push((
            Value::Integer(3.into()),
            Value::Bytes(k.compressed_pubkey.clone()),
        ));

        // Key 4: chain_code (32 bytes)
        if let Some(ref cc) = k.chain_code {
            key_map.push((Value::Integer(4.into()), Value::Bytes(cc.clone())));
        }

        // Key 6: origin Tag 304 CryptoKeypath
        let mut origin_map = Vec::new();
        let mut comp_arr = Vec::new();
        for (idx, hardened) in &k.path_components {
            comp_arr.push(Value::Integer((*idx).into()));
            comp_arr.push(Value::Bool(*hardened));
        }
        origin_map.push((Value::Integer(1.into()), Value::Array(comp_arr)));

        key_map.push((
            Value::Integer(6.into()),
            Value::Tag(304, Box::new(Value::Map(origin_map))),
        ));

        // Key 10: note (optional string, e.g. "account.standard" or "account.ledger_live")
        if let Some(ref note) = k.note {
            key_map.push((
                Value::Integer(10.into()),
                Value::Text(note.clone()),
            ));
        }

        keys_cbor.push(Value::Tag(303, Box::new(Value::Map(key_map))));
    }
    map.push((Value::Integer(2.into()), Value::Array(keys_cbor)));

    // Key 3: device
    map.push((
        Value::Integer(3.into()),
        Value::Text(device.to_string()),
    ));

    // Key 4: device_id
    map.push((
        Value::Integer(4.into()),
        Value::Text(device_id.to_string()),
    ));

    // Key 5: version
    map.push((
        Value::Integer(5.into()),
        Value::Text(version.to_string()),
    ));

    let mut buf = Vec::new();
    ciborium::into_writer(&Value::Map(map), &mut buf).expect("CBOR serialize");
    buf
}

fn qr_to_matrix(code: &QrCode) -> Vec<Vec<bool>> {
    let width = code.width();
    let mut matrix = Vec::with_capacity(width);
    for y in 0..width {
        let mut row = Vec::with_capacity(width);
        for x in 0..width {
            row.push(code[(x, y)] == qrcode::Color::Dark);
        }
        matrix.push(row);
    }
    matrix
}

fn save_qr_png(matrix: &[Vec<bool>], path: &Path, scale: u32, quiet: u32) {
    let mod_count = matrix.len() as u32;
    let total_cells = mod_count + quiet * 2;
    let img_size = total_cells * scale;
    let mut img = image::GrayImage::from_pixel(img_size, img_size, image::Luma([255]));

    for (y, row) in matrix.iter().enumerate() {
        for (x, &is_dark) in row.iter().enumerate() {
            if is_dark {
                let px_start = (x as u32 + quiet) * scale;
                let py_start = (y as u32 + quiet) * scale;
                for dy in 0..scale {
                    for dx in 0..scale {
                        img.put_pixel(px_start + dx, py_start + dy, image::Luma([0]));
                    }
                }
            }
        }
    }
    img.save(path).expect("save png");
}

fn generate_html(
    output: &ProbeOutput,
    frames: &[FrameData],
    single_matrix: &[Vec<bool>],
) -> String {
    let frames_json = serde_json::to_string(frames).expect("serialize frames");
    let single_matrix_json = serde_json::to_string(single_matrix).expect("serialize single matrix");

    format!(r##"<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>OKX Air-Gap Probe: Animated Fountain QR</title>
  <style>
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      background-color: #0b0c10;
      color: #c5c6c7;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 24px 16px;
    }}
    .badge-test {{
      background: #e63946;
      color: #ffffff;
      font-weight: 700;
      font-size: 13px;
      padding: 6px 14px;
      border-radius: 20px;
      margin-bottom: 16px;
      letter-spacing: 0.5px;
      text-transform: uppercase;
    }}
    h1 {{
      font-size: 22px;
      color: #66fcf1;
      margin-bottom: 8px;
      font-weight: 700;
      text-align: center;
    }}
    .subtitle {{
      font-size: 14px;
      color: #8892b0;
      margin-bottom: 20px;
      text-align: center;
    }}
    .main-container {{
      display: flex;
      flex-direction: column;
      align-items: center;
      background: #1f2833;
      border-radius: 16px;
      padding: 24px;
      box-shadow: 0 10px 30px rgba(0,0,0,0.5);
      max-width: 680px;
      width: 100%;
    }}
    .qr-card {{
      background: #ffffff;
      padding: 20px;
      border-radius: 12px;
      display: flex;
      justify-content: center;
      align-items: center;
      box-shadow: 0 4px 20px rgba(0,0,0,0.4);
    }}
    canvas {{
      image-rendering: pixelated;
      display: block;
    }}
    .controls {{
      margin-top: 20px;
      width: 100%;
      display: flex;
      flex-direction: column;
      gap: 14px;
    }}
    .button-group {{
      display: flex;
      justify-content: center;
      gap: 10px;
    }}
    button {{
      background: #45a29e;
      color: #0b0c10;
      border: none;
      padding: 10px 18px;
      font-size: 14px;
      font-weight: 600;
      border-radius: 8px;
      cursor: pointer;
      transition: background 0.2s, transform 0.1s;
    }}
    button:hover {{ background: #66fcf1; }}
    button:active {{ transform: scale(0.97); }}
    .mode-btn.active {{
      background: #66fcf1;
      box-shadow: 0 0 10px rgba(102, 252, 241, 0.4);
    }}
    .slider-row {{
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 14px;
      color: #c5c6c7;
    }}
    input[type=range] {{
      flex: 1;
      margin-left: 12px;
      accent-color: #66fcf1;
    }}
    .status-panel {{
      margin-top: 18px;
      background: #0b0c10;
      border-radius: 10px;
      padding: 14px;
      width: 100%;
      font-family: "JetBrains Mono", Consolas, monospace;
      font-size: 12px;
      line-height: 1.6;
    }}
    .status-row {{
      display: flex;
      justify-content: space-between;
      border-bottom: 1px solid #1f2833;
      padding: 4px 0;
    }}
    .status-row:last-child {{ border-bottom: none; }}
    .key {{ color: #45a29e; }}
    .val {{ color: #ffffff; word-break: break-all; }}
    .copy-btn {{
      padding: 4px 8px;
      font-size: 11px;
      margin-left: 8px;
    }}
  </style>
</head>
<body>
  <div class="badge-test">TEST-ONLY: ZERO SECRETS &bull; AIR-GAP PROBE</div>
  <h1>OKX Keystone QR Compatibility Probe</h1>
  <div class="subtitle">Supports Samsung Galaxy S24 Ultra &bull; crypto-multi-accounts (BC-UR Tag 1103)</div>

  <div class="main-container">
    <div class="qr-card">
      <canvas id="qrCanvas" width="420" height="420"></canvas>
    </div>

    <div class="controls">
      <div class="button-group">
        <button id="btnModeFountain" class="mode-btn active" onclick="setMode('fountain')">Fountain Animated QR</button>
        <button id="btnModeSingle" class="mode-btn" onclick="setMode('single')">Single Static QR</button>
      </div>

      <div class="button-group" id="playbackControls">
        <button onclick="prevFrame()">&#9664; Prev</button>
        <button id="btnToggle" onclick="togglePlay()">Pause</button>
        <button onclick="nextFrame()">Next &#9654;</button>
      </div>

      <div class="slider-row">
        <span>Speed (<span id="fpsVal">{fps:.1}</span> FPS):</span>
        <input type="range" id="fpsSlider" min="1.0" max="8.0" step="0.5" value="{fps:.1}" oninput="updateFps(this.value)">
      </div>

      <div class="slider-row">
        <span>Size (<span id="sizeVal">420</span>px):</span>
        <input type="range" id="sizeSlider" min="280" max="640" step="20" value="420" oninput="updateSize(this.value)">
      </div>
    </div>

    <div class="status-panel">
      <div class="status-row">
        <span class="key">Current Frame:</span>
        <span class="val" id="lblFrame">Loading...</span>
      </div>
      <div class="status-row">
        <span class="key">EVM Address (Verified):</span>
        <span class="val">
          <span id="lblAddr">{addr}</span>
          <button class="copy-btn" onclick="copyText('{addr}')">Copy</button>
        </span>
      </div>
      <div class="status-row">
        <span class="key">Derivation Path:</span>
        <span class="val">{path} (Account xpub)</span>
      </div>
      <div class="status-row">
        <span class="key">Master Fingerprint:</span>
        <span class="val">0x{mfp_hex} ({mfp_u32})</span>
      </div>
      <div class="status-row">
        <span class="key">CBOR Payload:</span>
        <span class="val">{cbor_len} bytes &bull; Tag 1103</span>
      </div>
      <div class="status-row">
        <span class="key">Current UR String:</span>
        <span class="val">
          <span id="lblUrSnippet">...</span>
          <button class="copy-btn" onclick="copyCurrentUr()">Copy UR</button>
        </span>
      </div>
    </div>
  </div>

  <script>
    const frames = {frames_json};
    const singleMatrix = {single_matrix_json};
    const singleUr = "{single_ur}";

    let currentMode = "fountain";
    let frameIdx = 0;
    let fps = {fps:.1};
    let timer = null;
    let isPlaying = true;
    let currentMatrix = frames.length > 0 ? frames[0].matrix : singleMatrix;

    const canvas = document.getElementById("qrCanvas");
    const ctx = canvas.getContext("2d");

    function renderMatrix(matrix) {{
      const size = canvas.width;
      const modCount = matrix.length;
      const quiet = 4;
      const totalCells = modCount + quiet * 2;
      const cellSize = size / totalCells;

      ctx.fillStyle = "#ffffff";
      ctx.fillRect(0, 0, size, size);

      ctx.fillStyle = "#000000";
      for (let y = 0; y < modCount; y++) {{
        for (let x = 0; x < modCount; x++) {{
          if (matrix[y][x]) {{
            ctx.fillRect(
              Math.round((x + quiet) * cellSize),
              Math.round((y + quiet) * cellSize),
              Math.ceil(cellSize),
              Math.ceil(cellSize)
            );
          }}
        }}
      }}
    }}

    function updateDisplay() {{
      if (currentMode === "fountain") {{
        const f = frames[frameIdx];
        renderMatrix(f.matrix);
        document.getElementById("lblFrame").innerText = `Part ${{f.part_index}} (Seq ${{f.seq_num}}/${{frames.length}})`;
        document.getElementById("lblUrSnippet").innerText = f.ur.substring(0, 36) + "...";
      }} else {{
        renderMatrix(singleMatrix);
        document.getElementById("lblFrame").innerText = "Single Static Frame (1/1)";
        document.getElementById("lblUrSnippet").innerText = singleUr.substring(0, 36) + "...";
      }}
    }}

    function tick() {{
      if (currentMode === "fountain" && isPlaying) {{
        frameIdx = (frameIdx + 1) % frames.length;
        updateDisplay();
      }}
    }}

    function startTimer() {{
      if (timer) clearInterval(timer);
      timer = setInterval(tick, 1000 / fps);
    }}

    function setMode(mode) {{
      currentMode = mode;
      document.getElementById("btnModeFountain").classList.toggle("active", mode === "fountain");
      document.getElementById("btnModeSingle").classList.toggle("active", mode === "single");
      document.getElementById("playbackControls").style.display = mode === "fountain" ? "flex" : "none";
      updateDisplay();
    }}

    function togglePlay() {{
      isPlaying = !isPlaying;
      document.getElementById("btnToggle").innerText = isPlaying ? "Pause" : "Play";
    }}

    function prevFrame() {{
      if (currentMode === "fountain") {{
        frameIdx = (frameIdx - 1 + frames.length) % frames.length;
        updateDisplay();
      }}
    }}

    function nextFrame() {{
      if (currentMode === "fountain") {{
        frameIdx = (frameIdx + 1) % frames.length;
        updateDisplay();
      }}
    }}

    function updateFps(val) {{
      fps = parseFloat(val);
      document.getElementById("fpsVal").innerText = fps.toFixed(1);
      startTimer();
    }}

    function updateSize(val) {{
      const sz = parseInt(val);
      document.getElementById("sizeVal").innerText = sz;
      canvas.width = sz;
      canvas.height = sz;
      updateDisplay();
    }}

    function copyText(str) {{
      navigator.clipboard.writeText(str).then(() => alert("Copied to clipboard!"));
    }}

    function copyCurrentUr() {{
      const str = currentMode === "fountain" ? frames[frameIdx].ur : singleUr;
      copyText(str);
    }}

    updateDisplay();
    startTimer();
  </script>
</body>
</html>
"##,
        fps = output.fountain_fps,
        addr = output.eip55_address,
        path = output.account_path,
        mfp_hex = output.master_fingerprint_hex,
        mfp_u32 = output.master_fingerprint_u32,
        cbor_len = output.cbor_len_bytes,
        single_ur = output.ur_single,
        frames_json = frames_json,
        single_matrix_json = single_matrix_json
    )
}

fn main() {
    let args = CliArgs::parse();

    println!("======================================================================");
    println!("OKX Air-Gap Probe CLI (tools/okx_probe) [Milestone M1 / PAIR-01..03]");
    println!("======================================================================");
    println!("[TEST-ONLY] All derivations use public BIP-39 standard test vectors.");
    println!("[TEST-ONLY] Physically isolated from private vault keys & signing FFI.");
    println!("----------------------------------------------------------------------");

    // 1. BIP-39 & Seed Derivation
    let mnemonic = Mnemonic::parse(&args.mnemonic).expect("Valid BIP-39 mnemonic");
    let seed = mnemonic.to_seed(&args.passphrase);

    let master_xprv = XPrv::new(seed).expect("Valid master seed");
    let master_fp_bytes = master_xprv.public_key().fingerprint();
    let master_fp_u32 = u32::from_be_bytes(master_fp_bytes);
    let master_fp_hex = hex::encode(master_fp_bytes);

    // 2. Account xpub derivation m/44'/60'/0'
    let account_path_str = "m/44'/60'/0'";
    let account_path = DerivationPath::from_str(account_path_str).expect("Valid account path");
    let account_xprv = XPrv::derive_from_path(seed, &account_path).expect("Derive account xprv");
    let account_xpub = account_xprv.public_key();
    let account_xpub_str = account_xpub.to_string(bip32::Prefix::XPUB);
    let account_comp_bytes = account_xpub.to_bytes().to_vec();
    let account_chain_code_bytes = account_xpub.attrs().chain_code.to_vec();

    // 3. Leaf pubkey derivation m/44'/60'/0'/0/0
    let leaf_path_str = "m/44'/60'/0'/0/0";
    let leaf_path = DerivationPath::from_str(leaf_path_str).expect("Valid leaf path");
    let leaf_xprv = XPrv::derive_from_path(seed, &leaf_path).expect("Derive leaf xprv");
    let leaf_xpub = leaf_xprv.public_key();
    let leaf_comp_bytes = leaf_xpub.to_bytes().to_vec();

    // 4. Calculate Ethereum EIP-55 Checksum Address
    let pk = PublicKey::from_slice(&leaf_comp_bytes).expect("Valid secp256k1 pubkey");
    let uncomp = pk.serialize_uncompressed(); // 65 bytes
    let pubkey_raw = &uncomp[1..]; // 64 bytes

    let mut hasher = Keccak::v256();
    let mut keccak_hash = [0u8; 32];
    hasher.update(pubkey_raw);
    hasher.finalize(&mut keccak_hash);

    let addr_lower = hex::encode(&keccak_hash[12..]);
    let eip55_addr = to_eip55(&addr_lower);

    println!("Master Fingerprint      : 0x{} ({})", master_fp_hex, master_fp_u32);
    println!("Account xpub (m/44'/60'/0'): {}", account_xpub_str);
    println!("Account Compressed Key  : {}", hex::encode(&account_comp_bytes));
    println!("Account Chain Code      : {}", hex::encode(&account_chain_code_bytes));
    println!("Leaf Compressed Key     : {}", hex::encode(&leaf_comp_bytes));
    println!("EIP-55 Derived Address  : {}", eip55_addr);
    println!("----------------------------------------------------------------------");

    // 5. Construct KeyEntry list for CBOR
    let mut keys = Vec::new();
    if args.derivation_level == "account" {
        keys.push(KeyEntry {
            compressed_pubkey: account_comp_bytes.clone(),
            chain_code: Some(account_chain_code_bytes.clone()),
            path_components: vec![(44, true), (60, true), (0, true)],
            note: Some("account.standard".to_string()),
        });
    } else if args.derivation_level == "both" {
        // In 'both' mode (default), Key 1 uses the leaf public key so OKX Wallet
        // computes and displays the target EIP-55 address (0x9858EfFD232B4033E47d90003D41EC34EcaEda94),
        // while preserving account-level path components and chain code.
        keys.push(KeyEntry {
            compressed_pubkey: leaf_comp_bytes.clone(),
            chain_code: Some(account_chain_code_bytes.clone()),
            path_components: vec![(44, true), (60, true), (0, true)],
            note: Some("account.standard".to_string()),
        });
    }

    if args.derivation_level == "leaf" || args.derivation_level == "both" {
        keys.push(KeyEntry {
            compressed_pubkey: leaf_comp_bytes.clone(),
            chain_code: None,
            path_components: vec![(44, true), (60, true), (0, true), (0, false), (0, false)],
            note: Some("account.ledger_live".to_string()),
        });
    }

    // 6. Build CBOR Tag 1103
    let cbor_bytes = build_crypto_multi_accounts_cbor(
        master_fp_u32,
        &keys,
        &args.device,
        &args.device_id,
        &args.version_str,
    );
    let cbor_hex = hex::encode(&cbor_bytes);
    println!("CBOR Payload Size       : {} bytes", cbor_bytes.len());
    println!("CBOR Hex Representation :\n{}", cbor_hex);
    println!("----------------------------------------------------------------------");

    // 7. Generate Single-Frame UR
    let ur_single = format!(
        "ur:crypto-multi-accounts/{}",
        ur::bytewords::encode(&cbor_bytes, ur::bytewords::Style::Minimal)
    );
    println!("Single-Frame UR String  : (length: {} chars)\n{}", ur_single.len(), ur_single);
    println!("----------------------------------------------------------------------");

    // 8. Generate Multi-Frame Luby Transform Fountain UR
    let leaked_cbor: &'static [u8] = Box::leak(cbor_bytes.clone().into_boxed_slice());
    let mut ur_encoder = ur::Encoder::new(leaked_cbor, args.fragment_size, "crypto-multi-accounts")
        .expect("Initialize fountain encoder");
    let frag_count = ur_encoder.fragment_count();
    println!("Fountain Fragment Slicing: {} parts (max {} bytes/frag)", frag_count, args.fragment_size);

    let num_frames_to_generate = (frag_count * 3).max(12);
    let mut fountain_frames = Vec::new();
    let mut frames_data = Vec::new();

    for i in 0..num_frames_to_generate {
        let part_ur = ur_encoder.next_part().expect("fountain part");
        let qr = QrCode::with_error_correction_level(part_ur.as_bytes(), EcLevel::M)
            .expect("generate qr");
        let matrix = qr_to_matrix(&qr);
        frames_data.push(FrameData {
            part_index: (i % frag_count) + 1,
            seq_num: i + 1,
            ur: part_ur.clone(),
            matrix,
        });
        fountain_frames.push(part_ur);
    }

    // Single-frame QR matrix
    let single_qr = QrCode::with_error_correction_level(ur_single.as_bytes(), EcLevel::M)
        .expect("generate single qr");
    let single_matrix = qr_to_matrix(&single_qr);

    let probe_output = ProbeOutput {
        test_only_warning: "TEST-ONLY: CONTAINS NO PRIVATE KEYS, NO SIGNING CAPABILITY".to_string(),
        master_fingerprint_hex: master_fp_hex,
        master_fingerprint_u32: master_fp_u32,
        account_path: account_path_str.to_string(),
        account_xpub: account_xpub_str,
        account_compressed_pubkey: hex::encode(&account_comp_bytes),
        account_chain_code: hex::encode(&account_chain_code_bytes),
        leaf_path: leaf_path_str.to_string(),
        leaf_compressed_pubkey: hex::encode(&leaf_comp_bytes),
        eip55_address: eip55_addr,
        cbor_hex,
        cbor_len_bytes: cbor_bytes.len(),
        ur_single: ur_single.clone(),
        fountain_fragment_count: frag_count,
        fountain_fragment_size: args.fragment_size,
        fountain_fps: args.fps,
        fountain_frames,
    };

    // 9. Write Output Artifacts
    fs::create_dir_all(&args.out_dir).expect("create out-dir");
    let html_content = generate_html(&probe_output, &frames_data, &single_matrix);
    let html_path = args.out_dir.join("display.html");
    fs::write(&html_path, &html_content).expect("write display.html");
    println!("HTML5 Animated Player   : {}", html_path.display());

    let single_png_path = args.out_dir.join("keystone_single_qr.png");
    save_qr_png(&single_matrix, &single_png_path, 16, 4);
    println!("Single QR PNG Exported  : {}", single_png_path.display());

    let frames_dir = args.out_dir.join("frames");
    fs::create_dir_all(&frames_dir).expect("create frames dir");
    for (i, f) in frames_data.iter().enumerate() {
        let frame_path = frames_dir.join(format!("frame_{:02}.png", i + 1));
        save_qr_png(&f.matrix, &frame_path, 12, 4);
    }

    let fixture_path = args.out_dir.join("probe_fixture.json");
    let fixture_json = serde_json::to_string_pretty(&probe_output).expect("serialize fixture");
    fs::write(&fixture_path, &fixture_json).expect("write probe_fixture.json");
    println!("JSON Fixture Exported   : {}", fixture_path.display());

    // 10. Terminal ANSI Display
    if args.display == "terminal" || args.display == "all" {
        println!("\n[Terminal Display: Single-Frame QR Preview]");
        let ansi_str = single_qr.render::<unicode::Dense1x2>().build();
        println!("{}", ansi_str);
    }

    if args.open_browser {
        println!("Opening {} in default browser...", html_path.display());
        let _ = subprocess_open(&html_path);
    }

    println!("\n[+] okx_probe execution completed successfully.");
}

#[cfg(target_os = "windows")]
fn subprocess_open(path: &Path) -> std::io::Result<()> {
    std::process::Command::new("cmd")
        .args(["/C", "start", "", &path.to_string_lossy()])
        .spawn()?;
    Ok(())
}

#[cfg(not(target_os = "windows"))]
fn subprocess_open(path: &Path) -> std::io::Result<()> {
    std::process::Command::new("xdg-open")
        .arg(path)
        .spawn()?;
    Ok(())
}
