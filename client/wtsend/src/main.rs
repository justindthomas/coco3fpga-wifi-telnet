//! wtsend - upload a file to a CoCo3FPGA running wtbridge.
//!
//! Wire protocol: see ../../docs/file-transfer.md.

use std::env;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::process::ExitCode;
use std::time::Duration;

const DEFAULT_PORT: u16 = 23;
const MAX_NAME: usize = 240;
const MAX_SIZE: u32 = u16::MAX as u32; // bridge caps at 16-bit

fn usage() -> ! {
    eprintln!(
        "usage: wtsend --host HOST[:PORT] --remote NITROS9_PATH LOCAL_FILE\n\
         \n\
         Uploads LOCAL_FILE over TCP to a CoCo3FPGA running wtbridge,\n\
         creating NITROS9_PATH on the target.  Default port is {DEFAULT_PORT}."
    );
    std::process::exit(2);
}

fn parse_args() -> (String, String, String) {
    let args: Vec<String> = env::args().collect();
    let mut host: Option<String> = None;
    let mut remote: Option<String> = None;
    let mut local: Option<String> = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--host" => {
                i += 1;
                host = Some(args.get(i).cloned().unwrap_or_else(|| usage()));
            }
            "--remote" => {
                i += 1;
                remote = Some(args.get(i).cloned().unwrap_or_else(|| usage()));
            }
            "-h" | "--help" => usage(),
            s if !s.starts_with('-') => local = Some(s.to_string()),
            _ => usage(),
        }
        i += 1;
    }
    (
        host.unwrap_or_else(|| usage()),
        remote.unwrap_or_else(|| usage()),
        local.unwrap_or_else(|| usage()),
    )
}

fn main() -> ExitCode {
    let (host, remote, local) = parse_args();
    let addr = if host.contains(':') {
        host
    } else {
        format!("{host}:{DEFAULT_PORT}")
    };

    let data = match fs::read(&local) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("wtsend: read {local}: {e}");
            return ExitCode::from(10);
        }
    };
    let size: u32 = match u32::try_from(data.len()) {
        Ok(n) if n <= MAX_SIZE => n,
        _ => {
            eprintln!("wtsend: {local} is too large (max {MAX_SIZE} bytes)");
            return ExitCode::from(11);
        }
    };
    let name_bytes = remote.as_bytes();
    if name_bytes.is_empty() || name_bytes.len() > MAX_NAME {
        eprintln!("wtsend: --remote length out of range (1..{MAX_NAME})");
        return ExitCode::from(12);
    }
    if !name_bytes.iter().all(|&b| b.is_ascii() && b >= 0x20 && b != 0x7F) {
        eprintln!("wtsend: --remote must be printable ASCII");
        return ExitCode::from(12);
    }

    let mut sock = match TcpStream::connect(&addr) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("wtsend: connect {addr}: {e}");
            return ExitCode::from(13);
        }
    };
    let _ = sock.set_nodelay(true);
    let _ = sock.set_read_timeout(Some(Duration::from_secs(60)));
    let _ = sock.set_write_timeout(Some(Duration::from_secs(60)));

    let mut hdr = Vec::with_capacity(4 + 1 + name_bytes.len() + 4);
    hdr.extend_from_slice(b"WTUP");
    hdr.push(name_bytes.len() as u8);
    hdr.extend_from_slice(name_bytes);
    hdr.extend_from_slice(&size.to_be_bytes());

    if let Err(e) = sock.write_all(&hdr) {
        eprintln!("wtsend: write header: {e}");
        return ExitCode::from(14);
    }
    if let Err(e) = sock.write_all(&data) {
        eprintln!("wtsend: write payload: {e}");
        return ExitCode::from(15);
    }

    let mut status = [0u8; 1];
    if let Err(e) = sock.read_exact(&mut status) {
        eprintln!("wtsend: read status: {e}");
        return ExitCode::from(16);
    }

    match status[0] {
        0 => {
            eprintln!("wtsend: {local} -> {remote} ({size} bytes) OK");
            ExitCode::SUCCESS
        }
        1 => {
            eprintln!("wtsend: server: open failed (path invalid? disk full?)");
            ExitCode::from(1)
        }
        2 => {
            eprintln!("wtsend: server: write failed mid-stream");
            ExitCode::from(2)
        }
        3 => {
            eprintln!("wtsend: server: bad name length");
            ExitCode::from(3)
        }
        4 => {
            eprintln!("wtsend: server: file too big");
            ExitCode::from(4)
        }
        5 => {
            eprintln!("wtsend: server: busy - another upload in progress");
            ExitCode::from(5)
        }
        n => {
            eprintln!("wtsend: server: unknown status {n}");
            ExitCode::from(n)
        }
    }
}
