#!/bin/bash

# Script to dynamically downclock selected NVIDIA GPUs with per-GPU clock settings
# Requires: nvidia-smi, root privileges

# Configuration
LOW_USAGE_THRESHOLD=10  # % usage below which to downclock
HIGH_USAGE_THRESHOLD=50  # % usage above which to restore full clock
CHECK_INTERVAL=10  # Seconds between checks

# Selected GPUs to manage (1=manage, unset=ignore)
# Example: Manage GPUs 1 and 2, ignore 0 and 3
SELECTED_GPUS[1]=1
SELECTED_GPUS[2]=1
# SELECTED_GPUS[0]=1  # Uncomment to include GPU 0
# SELECTED_GPUS[3]=1  # Uncomment to include GPU 3

# Per-GPU clock settings (adjust based on nvidia-smi -q -d SUPPORTED_CLOCKS)
# Only set for GPUs in SELECTED_GPUS
LOW_CLOCKS[1]=544   # GPU 1 low clock
HIGH_CLOCKS[1]=1328 # GPU 1 high clock
LOW_CLOCKS[2]=135   # GPU 2 low clock
HIGH_CLOCKS[2]=1380 # GPU 2 high clock
# LOW_CLOCKS[0]=405   # GPU 0 low clock (uncomment if GPU 0 is selected)
# HIGH_CLOCKS[0]=1200 # GPU 0 high clock (uncomment if GPU 0 is selected)
# LOW_CLOCKS[3]=480   # GPU 3 low clock (uncomment if GPU 3 is selected)
# HIGH_CLOCKS[3]=1320 # GPU 3 high clock (uncomment if GPU 3 is selected)

# Ensure nvidia-smi is installed
if ! command -v nvidia-smi &> /dev/null; then
    echo "Error: nvidia-smi not found. Please install NVIDIA drivers."
    exit 1
fi

# Enable persistence mode for all GPUs
echo "Enabling persistence mode for all GPUs..."
sudo nvidia-smi -pm 1
if [ $? -ne 0 ]; then
    echo "Failed to enable persistence mode"
    exit 1
fi

# Function to get the number of GPUs
get_gpu_count() {
    local count=$(nvidia-smi --query-gpu=count --format=csv,noheader | awk '{print $1}')
    echo $count
}

# Function to get GPU usage for a specific GPU
get_gpu_usage() {
    local gpu_index=$1
    local raw_usage=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader -i $gpu_index)
    echo "GPU $gpu_index: Raw usage output: '$raw_usage'" >&2  # Debug log
    local usage=$(echo "$raw_usage" | cut -d' ' -f1 | tr -d '%')
    # Validate usage is a number
    if [[ "$usage" =~ ^[0-9]+$ ]]; then
        echo $usage
    else
        echo "GPU $gpu_index: Invalid usage data: '$usage'" >&2
        echo "-1"  # Return -1 for invalid usage
    fi
}

# Function to get current clock for a specific GPU
get_gpu_clock() {
    local gpu_index=$1
    local clock=$(nvidia-smi --query-gpu=clocks.gr --format=csv,noheader -i $gpu_index | cut -d' ' -f1)
    if [[ "$clock" =~ ^[0-9]+$ ]]; then
        echo $clock
    else
        echo "GPU $gpu_index: Invalid clock data: '$clock'" >&2
        echo "-1"  # Return -1 for invalid clock
    fi
}

# Function to validate clock speed for a GPU
validate_clock() {
    local gpu_index=$1
    local clock=$2
    local supported_clocks=$(nvidia-smi -q -d SUPPORTED_CLOCKS -i $gpu_index | grep "Graphics" | awk '{print $3}' | tr '\n' ' ')
    if echo "$supported_clocks" | grep -qw "$clock"; then
        return 0  # Valid clock
    else
        echo "GPU $gpu_index: Clock $clock MHz is not supported. Supported clocks: $supported_clocks" >&2
        return 1  # Invalid clock
    fi
}

# Function to set GPU clock for a specific GPU
set_gpu_clock() {
    local gpu_index=$1
    local clock=$2
    echo "GPU $gpu_index: Attempting to lock clock to $clock MHz"
    if validate_clock $gpu_index $clock; then
        sudo nvidia-smi -i $gpu_index -lgc $clock
        if [ $? -eq 0 ]; then
            sleep 1  # Wait for change to apply
            current_clock=$(get_gpu_clock $gpu_index)
            if [ "$current_clock" -eq "$clock" ]; then
                echo "GPU $gpu_index: Successfully locked clock to $current_clock MHz"
            else
                echo "GPU $gpu_index: Failed: Clock is $current_clock MHz, expected $clock MHz"
            fi
        else
            echo "GPU $gpu_index: Failed to execute nvidia-smi -lgc"
        fi
    else
        echo "GPU $gpu_index: Skipping clock adjustment due to invalid clock speed"
    fi
}

# Function to reset GPU clock to default for a specific GPU
reset_gpu_clock() {
    local gpu_index=$1
    echo "GPU $gpu_index: Resetting clock to default..."
    sudo nvidia-smi -i $gpu_index -rgc
    if [ $? -eq 0 ]; then
        echo "GPU $gpu_index: Clock reset to default"
    else
        echo "GPU $gpu_index: Failed to reset clock"
    fi
}

# Get the number of GPUs
gpu_count=$(get_gpu_count)
echo "Detected $gpu_count GPU(s)"

# Validate selected GPUs and their clock settings
selected_count=0
for gpu_index in "${!SELECTED_GPUS[@]}"; do
    if [ $gpu_index -ge $gpu_count ]; then
        echo "Error: GPU $gpu_index is selected but does not exist (only $gpu_count GPUs detected)"
        exit 1
    fi
    if [ -z "${LOW_CLOCKS[$gpu_index]}" ] || [ -z "${HIGH_CLOCKS[$gpu_index]}" ]; then
        echo "Error: LOW_CLOCK or HIGH_CLOCK not set for selected GPU $gpu_index"
        exit 1
    fi
    validate_clock $gpu_index ${LOW_CLOCKS[$gpu_index]} || exit 1
    validate_clock $gpu_index ${HIGH_CLOCKS[$gpu_index]} || exit 1
    ((selected_count++))
done
if [ $selected_count -eq 0 ]; then
    echo "Error: No GPUs selected for management"
    exit 1
fi
echo "Managing $selected_count GPU(s): ${!SELECTED_GPUS[@]}"

# Main loop
echo "Monitoring GPU usage and adjusting clock speeds for selected GPUs..."
while true; do
    for gpu_index in "${!SELECTED_GPUS[@]}"; do
        usage=$(get_gpu_usage $gpu_index)
        current_clock=$(get_gpu_clock $gpu_index)
        echo "GPU $gpu_index: Usage: $usage%, Current clock: $current_clock MHz"

        # Skip if usage is invalid
        if [ "$usage" -eq -1 ]; then
            echo "GPU $gpu_index: Skipping due to invalid usage data"
            continue
        fi

        if [ "$usage" -lt "$LOW_USAGE_THRESHOLD" ]; then
            echo "GPU $gpu_index: Usage low (<$LOW_USAGE_THRESHOLD%). Downclocking..."
            set_gpu_clock $gpu_index ${LOW_CLOCKS[$gpu_index]}
        elif [ "$usage" -gt "$HIGH_USAGE_THRESHOLD" ]; then
            echo "GPU $gpu_index: Usage high (>$HIGH_USAGE_THRESHOLD%). Restoring full clock..."
            set_gpu_clock $gpu_index ${HIGH_CLOCKS[$gpu_index]}
        else
            echo "GPU $gpu_index: Usage in normal range ($LOW_USAGE_THRESHOLD%-$HIGH_USAGE_THRESHOLD%). No changes."
        fi
    done

    sleep $CHECK_INTERVAL
done

# Reset selected GPU clocks on script exit (Ctrl+C)
trap 'for gpu_index in "${!SELECTED_GPUS[@]}"; do reset_gpu_clock $gpu_index; done; exit' SIGINT SIGTERM