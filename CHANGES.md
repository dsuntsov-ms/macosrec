# Changes Summary - Version 0.9.0

## Major Improvements

### 1. **Direct-to-Disk Video Recording**
Videos are now streamed directly to disk during recording instead of buffering in memory:
- ✅ **File created immediately** when recording starts
- ✅ **Frames written incrementally** as they're captured
- ✅ **Minimal memory usage** - no frame buffering
- ✅ **Third-party tools can detect** the file exists immediately
- ✅ **Progress visible** in real-time

### 2. **Simplified Feature Set**
Removed unused features for a cleaner, more focused tool:
- ❌ Removed GIF support (MOV only)
- ❌ Removed OCR functionality
- ❌ Removed speech-to-text functionality
- ✅ Kept screenshot functionality (PNG)
- ✅ Kept video recording (MOV)

### 3. **Technical Implementation**

#### Old Approach (Memory Buffering)
```
Recording → Capture frame → Store in array → ... → Stop → Write all frames to disk
```
- File appears only when stopping
- All frames stored in memory
- High memory usage for long recordings

#### New Approach (Direct Streaming)
```
Recording → Create file → Capture frame → Write to disk → Capture frame → Write to disk → ... → Stop → Finalize
```
- File appears immediately
- Frames written as captured
- Low memory usage
- Uses `AVAssetWriter` with real-time media data

## Usage Examples

### Recording a Window
```bash
# List windows
$ macosrec --list
21902 Emacs
22024 Dock
22035 Firefox

# Start recording (file created immediately)
$ macosrec --record 21902
Recording to: ~/Desktop/2024-11-26-10:30:45-Emacs.mov
^C
Saving...
~/Desktop/2024-11-26-10:30:45-Emacs.mov

# Or with custom output path
$ macosrec --record emacs --output ~/Videos/demo.mov
Recording to: ~/Videos/demo.mov
^C
Saving...
~/Videos/demo.mov
```

### Screenshots (Unchanged)
```bash
$ macosrec --screenshot 21902
~/Desktop/2024-11-26-10:30:45-Emacs.png
```

## Build & Install

```bash
# Build
swift build

# Install locally
make install

# Or with Homebrew
brew tap xenodium/macosrec
brew install macosrec
```

## Benefits for Third-Party Monitoring

The file is created immediately when recording starts, so external tools can:
- Detect the recording file exists
- Monitor file size growth
- Track recording progress
- Verify recording is active by checking file modification time


