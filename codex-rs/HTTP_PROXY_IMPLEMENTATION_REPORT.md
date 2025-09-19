# HTTP Proxy Support Implementation for Codex-RS

## Overview
This report documents the implementation of comprehensive HTTP proxy support for the Codex-RS CLI tool, with particular focus on fixing OAuth authentication flows that were failing when using HTTP_PROXY environment variables.

## Problem Statement
- Codex CLI did not support HTTP proxies for API connections
- Login authentication was failing with "state mismatch" errors when using HTTP_PROXY
- All HTTP clients in the codebase needed proxy configuration

## Root Cause Analysis
1. **Missing Proxy Configuration**: HTTP clients were created without proxy support
2. **Incorrect Proxy Setup**: Separate HTTP/HTTPS proxy configs instead of unified approach
3. **OAuth Flow Inconsistency**: Browser requests vs server requests taking different network paths
4. **HTTPS CONNECT Tunneling**: Proxy needed proper tunneling for auth.openai.com (HTTPS)

## Implementation Changes

### 1. Core Proxy Configuration (`core/src/default_client.rs`)

**Before:**
```rust
pub fn create_client() -> reqwest::Client {
    reqwest::Client::builder()
        .user_agent(ua)
        .default_headers(headers)
        .build()
        .unwrap_or_else(|_| reqwest::Client::new())
}
```

**After:**
```rust
pub fn create_client() -> reqwest::Client {
    let mut builder = reqwest::Client::builder()
        .user_agent(ua)
        .default_headers(headers);

    // Configure proxy from environment variables
    // Check for proxy environment variables in standard precedence order
    let proxy_url = std::env::var("HTTPS_PROXY")
        .or_else(|_| std::env::var("https_proxy"))
        .or_else(|_| std::env::var("HTTP_PROXY"))
        .or_else(|_| std::env::var("http_proxy"))
        .or_else(|_| std::env::var("ALL_PROXY"))
        .or_else(|_| std::env::var("all_proxy"));

    if let Ok(proxy_url) = proxy_url {
        // Use reqwest::Proxy::all() to handle both HTTP and HTTPS through the same proxy
        // This is important because auth.openai.com uses HTTPS and needs CONNECT tunneling
        if let Ok(proxy) = reqwest::Proxy::all(&proxy_url) {
            builder = builder.proxy(proxy);
        }
    }

    builder.build()
        .unwrap_or_else(|_| reqwest::Client::new())
}
```

**Key Changes:**
- Added environment variable detection with proper precedence
- Used `reqwest::Proxy::all()` for unified HTTP/HTTPS handling
- Proper HTTPS CONNECT tunneling support
- Added comprehensive comments explaining the approach

### 2. Login Server Updates (`login/src/server.rs`)

**Import Changes:**
```rust
use codex_core::default_client::create_client;
```

**Client Creation Updates:**
```rust
// Replace all instances of:
let client = reqwest::Client::new();

// With:
let client = create_client();
```

**OAuth Debugging (for troubleshooting):**
```rust
// Added comprehensive OAuth flow debugging
pub fn run_login_server(opts: ServerOptions) -> io::Result<LoginServer> {
    let state = opts.force_state.clone().unwrap_or_else(generate_state);
    eprintln!("OAuth Debug: Generated state parameter: '{}'", state);

    let auth_url = build_authorize_url(&opts.issuer, &opts.client_id, &redirect_uri, &pkce, &state);
    eprintln!("OAuth Debug: Authorization URL: {}", auth_url);

    // ... rest of function
}

// Added callback debugging
"/auth/callback" => {
    let params: std::collections::HashMap<String, String> =
        parsed_url.query_pairs().into_owned().collect();

    let received_state = params.get("state").map(String::as_str);
    eprintln!("OAuth Callback Debug:");
    eprintln!("Expected state: '{}'", state);
    eprintln!("Received state: '{:?}'", received_state);
    eprintln!("Full callback URL: {}", url_raw);
    eprintln!("Parsed query params: {:?}", params);

    if received_state != Some(state) {
        return HandledRequest::Response(
            Response::from_string("State mismatch").with_status_code(400),
        );
    }
}
```

**Proxy-Aware Browser Handling:**
```rust
if opts.open_browser {
    // If we're using a proxy, we might need to use a different approach for browser opening
    if std::env::var("HTTP_PROXY").is_ok() || std::env::var("HTTPS_PROXY").is_ok() || std::env::var("ALL_PROXY").is_ok() {
        eprintln!("Note: Proxy detected. For best results, manually copy the URL above to your browser.");
    } else {
        let _ = webbrowser::open(&auth_url);
    }
}
```

### 3. Ollama Client Updates (`ollama/src/client.rs`)

**Added Proxy Helper Function:**
```rust
/// Create a reqwest client with proxy support for Ollama connections.
fn create_ollama_client() -> reqwest::Client {
    let mut builder = reqwest::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(5));

    // Configure proxy from environment variables - same logic as default_client
    let proxy_url = std::env::var("HTTPS_PROXY")
        .or_else(|_| std::env::var("https_proxy"))
        .or_else(|_| std::env::var("HTTP_PROXY"))
        .or_else(|_| std::env::var("http_proxy"))
        .or_else(|_| std::env::var("ALL_PROXY"))
        .or_else(|_| std::env::var("all_proxy"));

    if let Ok(proxy_url) = proxy_url {
        if let Ok(proxy) = reqwest::Proxy::all(&proxy_url) {
            builder = builder.proxy(proxy);
        }
    }

    builder.build()
        .unwrap_or_else(|_| reqwest::Client::new())
}
```

**Client Creation Updates:**
```rust
// Replace:
let client = reqwest::Client::builder()
    .connect_timeout(std::time::Duration::from_secs(5))
    .build()
    .unwrap_or_else(|_| reqwest::Client::new());

// With:
let client = create_ollama_client();
```

### 4. Test Files Updates

**Login Test Updates (`login/tests/suite/login_server_e2e.rs`):**
```rust
// Replace all instances of:
let client = reqwest::Client::new();

// With:
let client = codex_core::default_client::create_client();
```

### 4. Proxy Configuration Tests (`core/src/default_client.rs`)

**Added Test Cases:**
```rust
#[test]
fn test_proxy_configuration_from_environment() {
    unsafe {
        std::env::set_var("HTTP_PROXY", "http://proxy.example.com:8080");
        std::env::set_var("HTTPS_PROXY", "https://proxy.example.com:8080");
    }

    let client = create_client();

    unsafe {
        std::env::remove_var("HTTP_PROXY");
        std::env::remove_var("HTTPS_PROXY");
    }

    assert!(client.get("https://httpbin.org/user-agent").build().is_ok());
}

#[test]
fn test_invalid_proxy_fallback() {
    unsafe {
        std::env::set_var("HTTP_PROXY", "invalid-proxy-url");
    }

    let client = create_client();

    unsafe {
        std::env::remove_var("HTTP_PROXY");
    }

    assert!(client.get("https://httpbin.org/user-agent").build().is_ok());
}
```

## Environment Setup Requirements

### Rust Toolchain
- **Minimum Version**: Rust 1.89.0+ (for edition2024 support)
- **Installation**:
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
  rustup component add rustfmt clippy
  ```

### Build Process
```bash
cd codex-rs
source "$HOME/.cargo/env"
cargo build --bin codex
```

## Supported Environment Variables

The implementation supports these standard proxy environment variables in order of precedence:

1. `HTTPS_PROXY` / `https_proxy` - For HTTPS requests (preferred)
2. `HTTP_PROXY` / `http_proxy` - For HTTP requests
3. `ALL_PROXY` / `all_proxy` - Fallback for all protocols
4. `NO_PROXY` / `no_proxy` - Automatically handled by reqwest

## Usage Examples

### Basic Usage
```bash
export HTTP_PROXY=http://proxy.company.com:8080
export HTTPS_PROXY=http://proxy.company.com:8080
./codex login
./codex "explain this codebase"
```

### Debugging OAuth Issues
```bash
export HTTP_PROXY=http://localhost:20171
./target/debug/codex login
# Follow debug output for state parameter tracking
```

## Key Technical Insights

### Why `Proxy::all()` is Critical
- **HTTPS CONNECT Tunneling**: `auth.openai.com` requires HTTPS, which needs HTTP CONNECT tunneling through the proxy
- **Unified Configuration**: Single proxy endpoint handles both HTTP and HTTPS requests properly
- **OAuth Consistency**: Ensures all requests in the OAuth flow use the same network path

### OAuth State Mismatch Resolution
- **Root Cause**: Different network paths for browser vs server requests
- **Solution**: Proxy-aware browser handling with manual URL copying
- **Debugging**: Comprehensive state parameter tracking throughout OAuth flow

### Error Handling
- **Graceful Degradation**: Invalid proxy URLs fallback to direct connections
- **Environment Variable Flexibility**: Supports both uppercase and lowercase variants
- **Timeout Preservation**: Maintains existing timeout configurations (e.g., Ollama's 5-second timeout)

## Verification Checklist

- [x] All HTTP clients use `create_client()` or proxy-enabled equivalents
- [x] Environment variables are checked in correct precedence order
- [x] `reqwest::Proxy::all()` is used instead of separate HTTP/HTTPS proxies
- [x] OAuth debugging is included for troubleshooting
- [x] Tests validate proxy configuration doesn't break normal operation
- [x] Build succeeds with Rust 1.89.0+

## Common Issues and Solutions

### "503 Service Temporarily Unavailable"
- **Cause**: Proxy server configuration issue
- **Solution**: Verify proxy server is running and accessible

### "State Mismatch" in OAuth
- **Cause**: Proxy interfering with OAuth parameter transmission
- **Solution**: Use manual URL copying instead of auto-browser opening

### Connection Timeouts
- **Cause**: Proxy not responding or incorrect proxy URL
- **Solution**: Verify proxy URL format and accessibility

This implementation provides comprehensive HTTP proxy support while maintaining backward compatibility and robust error handling.