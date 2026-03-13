# Git Commands for GPU Trading Pipeline Implementation

## LOCAL MACHINE: Stage and Commit Changes

### Step 1: Check Status (Already Done Above)
```bash
cd /path/to/DOCAGPUNetIO-application_LIX2_FYP_HKUST
git status
```

**Current status:**
- Modified files: 7
- Untracked files: 4
- Branch: `development`

### Step 2: Stage All Changes

**Option A: Stage everything at once**
```bash
git add -A
```

**Option B: Stage selectively (more control)**
```bash
# Stage modified files
git add mini_trader/Makefile
git add mini_trader/README.md
git add mini_trader/include/market_event.h
git add mini_trader/src/gpu_staging.cu
git add mini_trader/src/results_logger.cpp
git add mini_trader/src/udp_receiver.cpp
git add mini_trader/src/udp_replayer.cpp

# Stage new documentation
git add mini_trader/PIPELINE_SPEC.md
git add mini_trader/TESTING_GUIDE.md

# Stage build/test scripts
git add mini_trader/binance_downloader.sh
git add mini_trader/quickstart.sh
```

### Step 3: Verify Staging
```bash
git status
# Should show all files in "Changes to be committed"
```

**Expected output:**
```
Changes to be committed:
  (use "git rm --cached <file>..." to unstage)
        modified:   mini_trader/Makefile
        modified:   mini_trader/README.md
        modified:   mini_trader/include/market_event.h
        modified:   mini_trader/src/gpu_staging.cu
        modified:   mini_trader/src/results_logger.cpp
        modified:   mini_trader/src/udp_receiver.cpp
        modified:   mini_trader/src/udp_replayer.cpp
        new file:   mini_trader/PIPELINE_SPEC.md
        new file:   mini_trader/TESTING_GUIDE.md
        new file:   mini_trader/binance_downloader.sh
        new file:   mini_trader/quickstart.sh
```

### Step 4: Create Commit

```bash
git commit -m "Implement modular GPU-accelerated trading pipeline with full specification

- Phase 0: Define binary market event model (MarketEvent, Candle, Order structs)
- Phase 1-2: Binance data downloader + CSV to binary converter
- Phase 3: UDP replayer with micro-batching and configurable pacing modes
- Phase 4-6: Integrated UDP receiver + full GPU kernel pipeline
  * decode_parse_kernel: event validation
  * apply_events_kernel: OHLCV candle aggregation (60-second intervals)
  * strategy_kernel: momentum + VWAP signal generation (BUY/SELL)
  * pack_orders_kernel: order compaction + statistics
- Phase 5: Standalone GPU pipeline test (no UDP)
- Phase 7: Results logger with CSV output + summary statistics

Key features:
- Binary event format (no CSV parsing on GPU hot path)
- Real-time per-symbol candle aggregation with history buffer
- Pinned host memory + async CUDA streams for minimal overhead
- Supports real Binance data + synthetic data generation
- Throughput benchmarking with detailed metrics
- Future-ready: GPU kernels decoupled from UDP ingress (can swap to DPDK/GPUNetIO)

New files:
- binance_downloader.sh: Download Binance trades for 10 symbols
- PIPELINE_SPEC.md: Complete specification (400+ lines)
- TESTING_GUIDE.md: Comprehensive testing walkthrough

Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Step 5: Verify Commit
```bash
git log -1 --oneline
# Shows: (commit hash) Implement modular GPU-accelerated trading pipeline...
```

---

## PUSH TO REMOTE

### Check Remote Configuration
```bash
git remote -v
# Shows:
# origin  https://github.com/yourorg/repo.git (fetch)
# origin  https://github.com/yourorg/repo.git (push)
```

### Push to Development Branch
```bash
git push origin development
```

**Expected output:**
```
Enumerating objects: 15, done.
Counting objects: 100% (15/15), done.
Delta compression using up to 8 threads
Compressing objects: 100% (12/12), done.
Writing objects: 100% (12/12), 2.50 MiB, done.
Total 12 (delta 3), reused 0 (delta 0), pack-reused 0
remote: Resolving deltas: 100% (3/3)
To https://github.com/yourorg/repo.git
   71e3d2a..abc1234  development -> development
```

### Verify Push Succeeded
```bash
git status
# Should show: "Your branch is up to date with 'origin/development'."
```

---

## OPTIONAL: Create Pull Request (Main Branch)

If you want to merge into `main` branch:

### Create PR on GitHub (Web UI)
1. Go to: https://github.com/yourorg/repo/pulls
2. Click "New Pull Request"
3. Base: `main`
4. Compare: `development`
5. Add description:
   ```
   ## Summary

   Complete implementation of modular GPU-accelerated trading pipeline as per FYP specification.

   Includes:
   - Binary event format pipeline (Phase 0-2)
   - UDP simulation + GPU integration (Phase 3-6)
   - Results logging (Phase 7)
   - Full documentation and testing guide

   ## Testing

   - [ ] GPU standalone test: `./gpu_staging 100000 50000`
   - [ ] UDP end-to-end test: receiver + replayer
   - [ ] Real data test with Binance downloader
   ```
6. Click "Create Pull Request"

---

## SERVER: Pull Latest Changes

### SSH to Server
```bash
ssh user@server.com
cd /path/to/DOCAGPUNetIO-application_LIX2_FYP_HKUST
```

### Fetch Latest Changes
```bash
git fetch origin
```

### Switch to Development Branch (if not already)
```bash
git checkout development
```

### Pull Latest Changes
```bash
git pull origin development
```

**Expected output:**
```
remote: Enumerating objects: 15, done.
remote: Counting objects: 100% (15/15), done.
remote: Compressing objects: 100% (12/12), done.
remote: Total 12 (delta 3), reused 12 (delta 3), pack-reused 0
Unpacking objects: 100% (12/12), 1.50 MiB, done.
From https://github.com/yourorg/repo
   71e3d2a..abc1234  development -> origin/development
Updating 71e3d2a..abc1234
Fast-forward
 mini_trader/Makefile                  |   2 +-
 mini_trader/README.md                 | 250 ++++++++++++++-------
 mini_trader/include/market_event.h    | 100 +++++++++
 mini_trader/src/gpu_staging.cu        | 357 +++++++++++++++++++++++++++++
 mini_trader/src/results_logger.cpp    | 127 ++++++-----
 mini_trader/src/udp_receiver.cpp      | 360 +++++++++++++++++++++++++++++
 mini_trader/src/udp_replayer.cpp      | 114 +++++-----
 mini_trader/PIPELINE_SPEC.md          | new file mode 100644
 mini_trader/TESTING_GUIDE.md          | new file mode 100644
 mini_trader/binance_downloader.sh     | new file mode 100644
 mini_trader/quickstart.sh             | new file mode 100644
```

### Verify Pull
```bash
git log --oneline -5
# Should show latest commit at top
```

### Build on Server
```bash
cd mini_trader
make clean && make all
```

---

## QUICK REFERENCE - LOCAL COMMANDS

```bash
# 1. Stage everything
git add -A

# 2. Check staging
git status

# 3. Commit with detailed message
git commit -m "Implement modular GPU-accelerated trading pipeline with full specification

# Key changes:
# - Phase 0-7: Complete pipeline as per specification
# - Real candle aggregation, signal generation, results logging
# - Documentation: PIPELINE_SPEC.md, TESTING_GUIDE.md
# - Scripts: binance_downloader.sh, quickstart.sh

Co-Authored-By: Claude <noreply@anthropic.com>"

# 4. Verify commit
git log -1 --oneline

# 5. Push to origin
git push origin development

# 6. Verify push
git status
```

---

## QUICK REFERENCE - SERVER COMMANDS

```bash
# 1. Fetch updates
git fetch origin

# 2. Switch to development
git checkout development

# 3. Pull latest
git pull origin development

# 4. Build
cd mini_trader
make clean && make all

# 5. Test
./gpu_staging 100000 50000
```

---

## UNDO / ROLLBACK (If Needed)

### Undo Staging (Before Commit)
```bash
# Unstage specific file
git reset mini_trader/src/gpu_staging.cu

# Unstage everything
git reset
```

### Undo Last Commit (Before Push)
```bash
# Keep changes locally
git reset --soft HEAD~1

# Discard changes entirely
git reset --hard HEAD~1
```

### Undo After Push
```bash
# Create a new commit that reverts the changes
git revert HEAD

# This creates a NEW commit, doesn't delete history
git push origin development
```

---

## VIEW CHANGES BEFORE COMMIT

### See Diff of Modified Files
```bash
git diff mini_trader/src/gpu_staging.cu
# Shows: lines added/removed
```

### See Diff of ALL Changes
```bash
git diff
# Shows all unstaged changes
```

### See Staged Changes
```bash
git diff --cached
# Shows what will be committed
```

---

## BRANCH MANAGEMENT

### List Local Branches
```bash
git branch
# Shows: * development, main
```

### List Remote Branches
```bash
git branch -r
# Shows: origin/development, origin/main
```

### Create Feature Branch (Optional)
```bash
git checkout -b feature/gpu-pipeline-testing
git push -u origin feature/gpu-pipeline-testing
```

### Switch Branches
```bash
git checkout main
git checkout development
```

---

## SUMMARY

### LOCAL (Your Machine)
1. `git add -A` - Stage all changes
2. `git status` - Verify
3. `git commit -m "..."` - Commit with message
4. `git log -1` - Verify commit
5. `git push origin development` - Push to remote

### SERVER
1. `git fetch origin` - Get updates
2. `git pull origin development` - Merge locally
3. `make clean && make all` - Rebuild
4. Test your changes

Done! Your code is now in version control and on the server.
