# GPU Dynamic Downclock

Script to dynamically downclock selected NVIDIA GPUs with per-GPU clock settings.

## The Problem
Applications like ComfyUI often lock the clock high on the running GPU on Linux, even during idle moments between generations. 

## The Solution
This script monitors your GPU utilization in real-time. When usage drops, it dynamically lowers the clock speeds, power limits, and PowerMizer modes. When a load is detected, it restores them. This will help you **save electricity and reduce heat generation**. 

### Features
* Dynamically toggles between minimum and maximum supported clocks based on load.
* Configurable usage thresholds.
* Configurable `HIGH_POWER_OFFSET` to permanently lower the maximum power limit during heavy workloads to reduce temperatures.
* Auto-detects the legal clock and power limits for each specific GPU.

## Tested Hardware
It worked on my **TESLA V100, P100, and RTX 3090**.

## Usage

1. Make the script executable:
   ```bash
   chmod +x gpu_downclock.sh
   ```

2. Run the script with root privileges (required by `nvidia-smi` to change clocks and power limits):
   ```bash
   sudo ./gpu_downclock.sh
   ```

*(Note: You can open the script in a text editor to configure thresholds, select specific GPUs to monitor, or adjust the underclock offsets at the top of the file).*

## Status
**Still needs improvement.** Feel free to fork, modify, or submit pull requests!

## License
[Apache License Version 2.0](https://www.apache.org/licenses/LICENSE-2.0)
