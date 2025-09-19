#!/bin/bash

set -e  # Exit on error

echo "🔨 Building codex in release mode..."

# Build the codex binary in release mode
cargo build --release --bin codex

# Check if build was successful
if [ ! -f "target/release/codex" ]; then
    echo "❌ Build failed - codex binary not found"
    exit 1
fi

echo "✅ Build successful!"

# Create ~/.local/bin if it doesn't exist (common location for user binaries)
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"

# Copy the binary to ~/.local/bin
echo "📦 Installing codex to $LOCAL_BIN..."
cp target/release/codex "$LOCAL_BIN/codex"
chmod +x "$LOCAL_BIN/codex"

echo "✅ codex installed to $LOCAL_BIN/codex"

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
    echo ""
    echo "⚠️  Note: $LOCAL_BIN is not in your PATH"
    echo "   Add this to your ~/.bashrc or ~/.zshrc:"
    echo "   export PATH=\"$LOCAL_BIN:\$PATH\""
    echo ""
    echo "   Or run: echo 'export PATH=\"$LOCAL_BIN:\$PATH\"' >> ~/.bashrc"
    echo "   Then reload with: source ~/.bashrc"
else
    echo "✅ $LOCAL_BIN is already in your PATH"
fi

echo ""
echo "🎉 Installation complete!"
echo "   Binary location: $LOCAL_BIN/codex"
echo "   Test with: codex --version"