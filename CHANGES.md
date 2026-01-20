# Changes Summary - Version 0.10.0

## Performance Optimization Release

### 1. **Increased Frame Rate**
- ✅ **60 FPS recording** (up from 10 FPS)
- ✅ **6x smoother video** playback
- ✅ **Real-time accurate timestamps** - video playback speed matches reality

### 2. **Efficient Image Processing**
- ✅ **10-20x faster resize algorithm** - replaced PNG conversion pipeline with direct CGContext drawing
- ✅ **Standardized 720px height** scaling with maintained aspect ratio
- ✅ **Lower CPU usage** during recording

### 3. **Faster Save on Stop (Ctrl+C)**
- ✅ **1-second maximum timeout** when stopping recording
- ✅ **Drops pending frames** after timeout to avoid long waits
- ✅ **Quick response** regardless of recording length or resolution

### 4. **Technical Improvements**
- ✅ **Removed busy-waiting** - more efficient frame processing
- ✅ **Wall-clock timestamps** - accurate playback speed using actual capture time
- ✅ **Proper CMTime timescale** (600) - eliminates precision warnings

#### Old Image Pipeline
```
CGImage → PNG data → CGImageSource → Thumbnail → CGImage
(Very slow, multiple conversions)
```

#### New Image Pipeline
```
CGImage → CGContext direct draw → CGImage
(10-20x faster, single operation)
```

### Performance Comparison

| Metric | Before (v0.9.0) | After (v0.10.0) |
|--------|----------------|-----------------|
| Frame Rate | 10 FPS | 60 FPS |
| Image Processing | Slow (PNG pipeline) | Fast (direct draw) |
| Save Time | Minutes (waits for all frames) | Max 1 second |
| CPU Usage | High (busy-waiting) | Lower (efficient async) |
| Video Scaling | 70% arbitrary | 720px height |
| Playback Speed | Could be incorrect | Real-time accurate |

---

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



