#!/bin/bash
# Script to dynamically downclock selected NVIDIA GPUs + set power limits + PowerMizer modes
# Requires: nvidia-smi, nvidia-settings (optional for PowerMizer), root privileges
#
# FIX: Detects per-GPU min/max power limits and min/max supported graphics clocks
#      for GPU 0 .. GPU (N-1) instead of using hardcoded values that often
#      fall outside the card's legal range.

# Configuration
LOW_USAGE_THRESHOLD=5   # % usage below which to downclock + lower power
HIGH_USAGE_THRESHOLD=10  # % usage above which to restore full clock + full power
CHECK_INTERVAL=10        # Seconds between checks

# NEW: Offset to subtract from the maximum supported clock for the HIGH state (in MHz)
# e.g., set to 100 to underclock the maximum frequency by 100 MHz.
HIGH_CLOCK_OFFSET=100

# Optional: leave empty to manage ALL detected GPUs.
# Example to manage only 0 and 2: SELECTED_GPUS=(0 2)
SELECTED_GPUS=()

# Optional overrides (leave empty to auto-detect).
# If set, values are still clamped into the GPU's legal [min, max] range.
declare -A OVERRIDE_LOW_CLOCK OVERRIDE_HIGH_CLOCK
declare -A OVERRIDE_LOW_POWER OVERRIDE_HIGH_POWER

# Safety: when auto-picking LOW_POWER, stay this many watts above the hardware min
# so the card can still idle stably. Set to 0 to use the exact min.
LOW_POWER_MARGIN_W=0

# === Safety checks ===
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run with root privileges (sudo ./script.sh)"
    exit 1
fi
if ! command -v nvidia-smi &> /dev/null; then
    echo "Error: nvidia-smi not found. Please install NVIDIA drivers."
    exit 1
fi
HAS_NVIDIA_SETTINGS=0
if command -v nvidia-settings &> /dev/null; then
    HAS_NVIDIA_SETTINGS=1
else
    echo "Warning: nvidia-settings not found. PowerMizer mode changes will be skipped."
fi

# Enable persistence mode (quiet)
echo "Enabling persistence mode for all GPUs..."
nvidia-smi -pm 1 >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Failed to enable persistence mode"
    exit 1
fi

strip_num() {
    echo "$1" | tr -d '[:space:]' | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1
}

get_gpu_count() {
    local n
    n=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -dc '0-9')
    if [ -z "$n" ]; then
        n=$(nvidia-smi -L 2>/dev/null | wc -l)
    fi
    echo "${n:-0}"
}

get_gpu_usage() {
    local gpu_index=$1
    local raw_usage
    raw_usage=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits -i "$gpu_index" 2>/dev/null)
    local usage
    usage=$(strip_num "$raw_usage")
    if [[ "$usage" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "${usage%%.*}"
    else
        echo "GPU $gpu_index: Invalid usage data: '$raw_usage'" >&2
        echo "-1"
    fi
}

get_gpu_clock() {
    local gpu_index=$1
    local raw_clock
    raw_clock=$(nvidia-smi --query-gpu=clocks.gr --format=csv,noheader,nounits -i "$gpu_index" 2>/dev/null)
    local clock
    clock=$(strip_num "$raw_clock")
    if [[ "$clock" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "${clock%%.*}"
    else
        echo "GPU $gpu_index: Invalid clock data: '$raw_clock'" >&2
        echo "-1"
    fi
}

get_power_limits() {
    local gpu_index=$1
    local min_p max_p raw
    raw=$(nvidia-smi --query-gpu=power.min_limit,power.max_limit --format=csv,noheader,nounits -i "$gpu_index" 2>/dev/null)
    min_p=$(echo "$raw" | awk -F',' '{print $1}' | tr -d ' ')
    max_p=$(echo "$raw" | awk -F',' '{print $2}' | tr -d ' ')
    min_p=$(strip_num "$min_p")
    max_p=$(strip_num "$max_p")

    if [ -z "$min_p" ] || [ -z "$max_p" ]; then
        local power_data
        power_data=$(nvidia-smi -q -d POWER -i "$gpu_index" 2>/dev/null)
        min_p=$(echo "$power_data" | awk -F: '/Min Power Limit/ {gsub(/[^0-9.]/,"",$2); print $2; exit}')
        max_p=$(echo "$power_data" | awk -F: '/Max Power Limit/ {gsub(/[^0-9.]/,"",$2); print $2; exit}')
    fi

    if [ -z "$min_p" ] || [ -z "$max_p" ]; then
        echo "GPU $gpu_index: Could not parse Min/Max power limits" >&2
        return 1
    fi
    echo "$min_p $max_p"
}

get_supported_graphics_clocks() {
    local gpu_index=$1
    local clocks min_c max_c listed max_query

    listed=$(nvidia-smi --query-supported-clocks=gr --format=csv,noheader,nounits -i "$gpu_index" 2>/dev/null | tr -dc '0-9\n' | grep -E '^[0-9]+$' | sort -n | uniq)
    if [ -z "$listed" ]; then
        listed=$(nvidia-smi -q -d SUPPORTED_CLOCKS -i "$gpu_index" 2>/dev/null | \
                 awk '/Graphics/{flag=1} flag && /[0-9]+ MHz/{print $1} /Memory/{if(flag && seen++) exit}' | \
                 tr -dc '0-9\n' | grep -E '^[0-9]+$' | sort -n | uniq)
    fi

    max_query=$(nvidia-smi --query-gpu=clocks.max.gr --format=csv,noheader,nounits -i "$gpu_index" 2>/dev/null)
    max_query=$(strip_num "$max_query")

    if [ -n "$listed" ]; then
        min_c=$(echo "$listed" | head -n1)
        max_c=$(echo "$listed" | tail -n1)
    fi

    if [ -n "$max_query" ]; then
        if [ -z "$max_c" ] || [ "$(awk "BEGIN{print ($max_query > $max_c) ? 1 : 0}")" -eq 1 ]; then
            max_c="$max_query"
        fi
    fi

    if [ -z "$min_c" ] || [ -z "$max_c" ]; then
        echo "GPU $gpu_index: Could not determine supported graphics clocks" >&2
        return 1
    fi
    echo "$min_c $max_c"
}

clock_is_supported() {
    local gpu_index=$1
    local clock=$2
    local listed
    listed=$(nvidia-smi --query-supported-clocks=gr --format=csv,noheader,nounits -i "$gpu_index" 2>/dev/null | tr -dc '0-9\n')
    if [ -z "$listed" ]; then
        listed=$(nvidia-smi -q -d SUPPORTED_CLOCKS -i "$gpu_index" 2>/dev/null | grep -oE '[0-9]+ MHz' | grep -oE '[0-9]+')
    fi
    if [ -z "$listed" ]; then
        return 0
    fi
    echo "$listed" | grep -qx "$clock"
}

validate_clock() {
    local gpu_index=$1
    local clock=$2
    if ! [[ "$clock" =~ ^[0-9]+$ ]]; then
        echo "GPU $gpu_index: Clock '$clock' is not a valid integer MHz" >&2
        return 1
    fi
    local range
    range=$(get_supported_graphics_clocks "$gpu_index") || return 1
    local min_c max_c
    min_c=$(echo "$range" | awk '{print $1}')
    max_c=$(echo "$range" | awk '{print $2}')
    if [ "$clock" -lt "$min_c" ] || [ "$clock" -gt "$max_c" ]; then
        echo "GPU $gpu_index: Clock $clock MHz outside supported range [$min_c, $max_c]" >&2
        return 1
    fi
    if ! clock_is_supported "$gpu_index" "$clock"; then
        echo "GPU $gpu_index: Clock $clock MHz is not in the supported-clocks list (range ok: $min_c-$max_c)" >&2
        return 0
    fi
    return 0
}

validate_power() {
    local gpu_index=$1
    local power=$2
    if ! [[ "$power" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "GPU $gpu_index: Power limit '$power' is not a valid number" >&2
        return 1
    fi
    local limits min_power max_power
    limits=$(get_power_limits "$gpu_index") || return 1
    min_power=$(echo "$limits" | awk '{print $1}')
    max_power=$(echo "$limits" | awk '{print $2}')

    if (( $(awk "BEGIN {print ($power < $min_power) ? 1 : 0}") )); then
        echo "GPU $gpu_index: Power $power W is BELOW minimum ($min_power W)" >&2
        return 1
    fi
    if (( $(awk "BEGIN {print ($power > $max_power) ? 1 : 0}") )); then
        echo "GPU $gpu_index: Power $power W is ABOVE maximum ($max_power W)" >&2
        return 1
    fi
    return 0
}

clamp() {
    local val=$1 min=$2 max=$3
    awk -v v="$val" -v lo="$min" -v hi="$max" 'BEGIN {
        if (v < lo) v = lo;
        if (v > hi) v = hi;
        print v;
    }'
}

set_gpu_clock() {
    local gpu_index=$1
    local clock=$2
    echo "GPU $gpu_index: Attempting to lock clock to $clock MHz"
    if validate_clock "$gpu_index" "$clock"; then
        nvidia-smi -i "$gpu_index" -lgc "$clock"
        if [ $? -eq 0 ]; then
            sleep 1
            local current_clock
            current_clock=$(get_gpu_clock "$gpu_index")
            if [ "$current_clock" = "$clock" ]; then
                echo "GPU $gpu_index: Clock locked to $current_clock MHz"
            else
                echo "GPU $gpu_index: Clock command accepted (now $current_clock MHz; requested $clock)"
            fi
        else
            echo "GPU $gpu_index: Failed to execute -lgc" >&2
        fi
    else
        echo "GPU $gpu_index: Skipping invalid clock" >&2
    fi
}

set_power_limit() {
    local gpu_index=$1
    local power=$2
    echo "GPU $gpu_index: Attempting to set power limit to $power W"
    if validate_power "$gpu_index" "$power"; then
        nvidia-smi -i "$gpu_index" --power-limit="$power"
        if [ $? -eq 0 ]; then
            echo "GPU $gpu_index: Power limit successfully set to $power W"
        else
            echo "GPU $gpu_index: Failed to set power limit" >&2
        fi
    else
        echo "GPU $gpu_index: Skipping invalid power limit" >&2
    fi
}

set_powermizer_mode() {
    local gpu_index=$1
    local mode=$2
    if [ "$HAS_NVIDIA_SETTINGS" -ne 1 ]; then
        return 0
    fi
    local mode_name="Adaptive (Level 0-2)"
    if [ "$mode" -eq 1 ]; then
        mode_name="Maximum Performance (Level 4)"
    fi
    echo "GPU $gpu_index: Attempting to set PowerMizer mode to $mode_name"
    export DISPLAY="${DISPLAY:-:0}"
    nvidia-settings -a "[gpu:$gpu_index]/GpuPowerMizerMode=$mode" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "GPU $gpu_index: PowerMizer mode successfully set to $mode_name"
    else
        echo "GPU $gpu_index: Failed to set PowerMizer mode (Is an X server running on DISPLAY=${DISPLAY}?)" >&2
    fi
}

reset_gpu_clock() {
    local gpu_index=$1
    echo "GPU $gpu_index: Resetting clock to default..."
    nvidia-smi -i "$gpu_index" -rgc
    if [ $? -eq 0 ]; then
        echo "GPU $gpu_index: Clock reset complete"
    else
        echo "GPU $gpu_index: Failed to reset clock" >&2
    fi
}

reset_power_limit() {
    local gpu_index=$1
    echo "GPU $gpu_index: Resetting power limit to maximum..."
    local limits max_power
    limits=$(get_power_limits "$gpu_index")
    max_power=$(echo "$limits" | awk '{print $2}')
    if [ -n "$max_power" ]; then
        nvidia-smi -i "$gpu_index" --power-limit="$max_power"
        if [ $? -eq 0 ]; then
            echo "GPU $gpu_index: Power limit reset to $max_power W"
        else
            echo "GPU $gpu_index: Failed to reset power limit" >&2
        fi
    else
        echo "GPU $gpu_index: Could not determine max power limit - skipping reset" >&2
    fi
}

reset_powermizer() {
    local gpu_index=$1
    if [ "$HAS_NVIDIA_SETTINGS" -ne 1 ]; then
        return 0
    fi
    echo "GPU $gpu_index: Resetting PowerMizer mode to Adaptive..."
    export DISPLAY="${DISPLAY:-:0}"
    nvidia-settings -a "[gpu:$gpu_index]/GpuPowerMizerMode=0" >/dev/null 2>&1
}

gpu_count=$(get_gpu_count)
echo "Detected $gpu_count GPU(s)"
if [ "$gpu_count" -eq 0 ]; then
    echo "Error: No NVIDIA GPUs found"
    exit 1
fi

declare -a LOW_CLOCKS HIGH_CLOCKS LOW_POWER HIGH_POWER
declare -a GPU_MIN_POWER GPU_MAX_POWER GPU_MIN_CLOCK GPU_MAX_CLOCK

if [ "${#SELECTED_GPUS[@]}" -eq 0 ]; then
    for ((i=0; i<gpu_count; i++)); do
        SELECTED_GPUS+=("$i")
    done
fi

echo "----- Detected hardware limits -----"
for gpu_index in "${SELECTED_GPUS[@]}"; do
    if ! [[ "$gpu_index" =~ ^[0-9]+$ ]] || [ "$gpu_index" -ge "$gpu_count" ]; then
        echo "Error: GPU $gpu_index selected but only $gpu_count GPUs exist (indices 0..$((gpu_count-1)))"
        exit 1
    fi

    name=$(nvidia-smi --query-gpu=name --format=csv,noheader -i "$gpu_index" 2>/dev/null)
    limits=$(get_power_limits "$gpu_index") || exit 1
    min_p=$(echo "$limits" | awk '{print $1}')
    max_p=$(echo "$limits" | awk '{print $2}')
    clocks=$(get_supported_graphics_clocks "$gpu_index") || exit 1
    min_c=$(echo "$clocks" | awk '{print $1}')
    max_c=$(echo "$clocks" | awk '{print $2}')

    GPU_MIN_POWER[$gpu_index]=$min_p
    GPU_MAX_POWER[$gpu_index]=$max_p
    GPU_MIN_CLOCK[$gpu_index]=$min_c
    GPU_MAX_CLOCK[$gpu_index]=$max_c

    low_c=${OVERRIDE_LOW_CLOCK[$gpu_index]:-$min_c}
    
    # NEW: Calculate the underclocked high by subtracting the offset
    underclocked_max=$(( max_c - HIGH_CLOCK_OFFSET ))
    high_c=${OVERRIDE_HIGH_CLOCK[$gpu_index]:-$underclocked_max}
    
    low_p=${OVERRIDE_LOW_POWER[$gpu_index]:-}
    high_p=${OVERRIDE_HIGH_POWER[$gpu_index]:-$max_p}

    if [ -z "$low_p" ]; then
        low_p=$(awk -v min="$min_p" -v m="$LOW_POWER_MARGIN_W" 'BEGIN{v=min+m; print v}')
    fi

    LOW_CLOCKS[$gpu_index]=$(clamp "$low_c" "$min_c" "$max_c")
    HIGH_CLOCKS[$gpu_index]=$(clamp "$high_c" "$min_c" "$max_c")
    LOW_CLOCKS[$gpu_index]=${LOW_CLOCKS[$gpu_index]%%.*}
    HIGH_CLOCKS[$gpu_index]=${HIGH_CLOCKS[$gpu_index]%%.*}

    LOW_POWER[$gpu_index]=$(clamp "$low_p" "$min_p" "$max_p")
    HIGH_POWER[$gpu_index]=$(clamp "$high_p" "$min_p" "$max_p")

    echo "GPU $gpu_index ($name)"
    echo "  Power legal range : ${min_p} W .. ${max_p} W"
    echo "  Clock legal range : ${min_c} MHz .. ${max_c} MHz"
    echo "  Using LOW         : ${LOW_CLOCKS[$gpu_index]} MHz / ${LOW_POWER[$gpu_index]} W"
    echo "  Using HIGH        : ${HIGH_CLOCKS[$gpu_index]} MHz (Underclocked by ${HIGH_CLOCK_OFFSET} MHz) / ${HIGH_POWER[$gpu_index]} W"
done
echo "-----------------------------------"

for gpu_index in "${SELECTED_GPUS[@]}"; do
    validate_clock "$gpu_index" "${LOW_CLOCKS[$gpu_index]}" || exit 1
    validate_clock "$gpu_index" "${HIGH_CLOCKS[$gpu_index]}" || exit 1
    validate_power "$gpu_index" "${LOW_POWER[$gpu_index]}" || exit 1
    validate_power "$gpu_index" "${HIGH_POWER[$gpu_index]}" || exit 1
done

echo "Managing ${#SELECTED_GPUS[@]} GPU(s): ${SELECTED_GPUS[*]}"

trap 'echo "Caught exit signal - resetting clocks, power limits, and PowerMizer modes..."; \
      for gpu_index in "${SELECTED_GPUS[@]}"; do \
          reset_gpu_clock "$gpu_index"; \
          reset_power_limit "$gpu_index"; \
          reset_powermizer "$gpu_index"; \
      done; \
      echo "Cleanup complete."; exit 0' SIGINT SIGTERM

echo "Starting monitoring (downclock + min power + Adaptive when idle, max clock + max power + Max Perf when busy)..."
while true; do
    for gpu_index in "${SELECTED_GPUS[@]}"; do
        usage=$(get_gpu_usage "$gpu_index")
        current_clock=$(get_gpu_clock "$gpu_index")
        echo "GPU $gpu_index: Usage: $usage%, Current clock: $current_clock MHz (legal clocks ${GPU_MIN_CLOCK[$gpu_index]}-${GPU_MAX_CLOCK[$gpu_index]} MHz, legal power ${GPU_MIN_POWER[$gpu_index]}-${GPU_MAX_POWER[$gpu_index]} W)"
        if [ "$usage" -eq -1 ] || [ "$current_clock" -eq -1 ]; then
            echo "GPU $gpu_index: Skipping due to invalid data"
            continue
        fi
        if [ "$usage" -lt "$LOW_USAGE_THRESHOLD" ]; then
            echo "GPU $gpu_index: Usage low → min clock + min power + Adaptive Mode"
            set_gpu_clock "$gpu_index" "${LOW_CLOCKS[$gpu_index]}"
            set_power_limit "$gpu_index" "${LOW_POWER[$gpu_index]}"
            set_powermizer_mode "$gpu_index" "0"
        elif [ "$usage" -gt "$HIGH_USAGE_THRESHOLD" ]; then
            echo "GPU $gpu_index: Usage high → max clock + max power + Max Perf Mode"
            set_gpu_clock "$gpu_index" "${HIGH_CLOCKS[$gpu_index]}"
            set_power_limit "$gpu_index" "${HIGH_POWER[$gpu_index]}"
            set_powermizer_mode "$gpu_index" "1"
        else
            echo "GPU $gpu_index: Usage normal → no change"
        fi
    done
    sleep "$CHECK_INTERVAL"
done
