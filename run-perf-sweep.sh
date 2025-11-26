#!/bin/bash

# CDT Performance Sweep Script
# Measures CDT performance across different I/O throttle delays
# Usage: ./run-perf-sweep.sh [start_delay] [end_delay] [increment]
# Default: 1ms to 50ms with 10ms increments

set -e

# Configuration
START_DELAY=${1:-1}
END_DELAY=${2:-50}
INCREMENT=${3:-10}
MOUNT_POINT="$HOME/throttled_io"
RESULTS_FILE="cdt-perf-results-$(date +%Y%m%d-%H%M%S).csv"
REPORT_FILE="cdt-perf-report-$(date +%Y%m%d-%H%M%S).txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_header() {
    echo -e "\n${CYAN}${BOLD}$1${NC}"
}

# Arrays to store results
declare -a DELAYS
declare -a THROUGHPUTS
declare -a DCB_READ_TIMES
declare -a BROTLI_READ_TIMES
declare -a GAPS

# Parse test output to extract timing information
parse_test_output() {
    local output="$1"
    local dcb_time=""
    local brotli_time=""
    
    # Extract "Diff (cache): duration=XXms" - this is DCB (dictionary compressed brotli)
    dcb_time=$(echo "$output" | grep -oP 'Diff \(cache\):.*?duration=\K[0-9.]+' | head -1)
    
    # Extract "Base (cache): duration=XXms" - this is regular Brotli
    brotli_time=$(echo "$output" | grep -oP 'Base \(cache\):.*?duration=\K[0-9.]+' | head -1)
    
    echo "$dcb_time,$brotli_time"
}

# Get throughput from setup script output (parses dd output)
parse_throughput() {
    local output="$1"
    local read_speed=""
    
    # Extract speed from dd output: "10485760 bytes (10 MB, 10 MiB) copied, 0.323269 s, 32.4 MB/s"
    read_speed=$(echo "$output" | grep -oP '[0-9.]+ [MGK]B/s' | tail -1)
    
    if [ -n "$read_speed" ]; then
        echo "$read_speed"
    else
        echo "N/A"
    fi
}

# Run a single test iteration
run_test_iteration() {
    local delay=$1
    
    log_header "Testing with I/O delay: ${delay}ms"
    echo "=========================================="
    
    # Setup throttled I/O
    log_info "Setting up throttled I/O with ${delay}ms delay..."
    local setup_output
    setup_output=$(./setup-throttled-io.sh "$delay" 2>&1) || {
        log_error "Failed to setup throttled I/O"
        echo "$setup_output"
        return 1
    }
    
    # Parse throughput from setup output
    local throughput
    throughput=$(parse_throughput "$setup_output")
    log_info "Measured throughput: $throughput"
    
    # Run the CDT test
    log_info "Running CDT performance test..."
    local test_output
    test_output=$(CDT_CACHE_DIR="$MOUNT_POINT" /usr/bin/npm test 2>&1) || {
        log_error "CDT test failed"
        echo "$test_output"
        return 1
    }
    
    # Parse timing results
    local timings
    timings=$(parse_test_output "$test_output")
    local dcb_time=$(echo "$timings" | cut -d',' -f1)
    local brotli_time=$(echo "$timings" | cut -d',' -f2)
    
    # Calculate gap
    local gap="N/A"
    if [ -n "$dcb_time" ] && [ -n "$brotli_time" ]; then
        gap=$(echo "scale=2; $dcb_time - $brotli_time" | bc)
    fi
    
    log_info "Results: DCB=${dcb_time}ms, Brotli=${brotli_time}ms, Gap=${gap}ms"
    
    # Store results
    DELAYS+=("$delay")
    THROUGHPUTS+=("$throughput")
    DCB_READ_TIMES+=("${dcb_time:-N/A}")
    BROTLI_READ_TIMES+=("${brotli_time:-N/A}")
    GAPS+=("${gap}")
    
    # Write to CSV
    echo "${delay},${throughput},${dcb_time:-N/A},${brotli_time:-N/A},${gap}" >> "$RESULTS_FILE"
    
    # Brief pause between iterations
    sleep 2
    
    return 0
}

# Generate final report
generate_report() {
    log_header "Generating Final Report"
    
    local report=""
    
    report+="================================================================================\n"
    report+="                    CDT CACHE READ PERFORMANCE SWEEP REPORT\n"
    report+="================================================================================\n"
    report+="\n"
    report+="Test Date: $(date)\n"
    report+="Delay Range: ${START_DELAY}ms to ${END_DELAY}ms (increment: ${INCREMENT}ms)\n"
    report+="\n"
    report+="--------------------------------------------------------------------------------\n"
    report+="                              RESULTS TABLE\n"
    report+="--------------------------------------------------------------------------------\n"
    report+="\n"
    
    # Table header
    printf -v header "%-15s %-15s %-15s %-15s %-10s" \
        "IO Delay" "Throughput" "DCB Read" "Brotli Read" "Gap"
    report+="$header\n"
    printf -v header "%-15s %-15s %-15s %-15s %-10s" \
        "(per read)" "" "Time" "Time" ""
    report+="$header\n"
    report+="--------------------------------------------------------------------------------\n"
    
    # Table rows
    for i in "${!DELAYS[@]}"; do
        local delay_str="${DELAYS[$i]} ms"
        local throughput="${THROUGHPUTS[$i]}"
        local dcb="${DCB_READ_TIMES[$i]}"
        local brotli="${BROTLI_READ_TIMES[$i]}"
        local gap="${GAPS[$i]}"
        
        # Format times with "ms" suffix if numeric
        [[ "$dcb" =~ ^[0-9.]+$ ]] && dcb="${dcb} ms"
        [[ "$brotli" =~ ^[0-9.]+$ ]] && brotli="${brotli} ms"
        [[ "$gap" =~ ^-?[0-9.]+$ ]] && gap="${gap} ms"
        
        printf -v row "%-15s %-15s %-15s %-15s %-10s" \
            "$delay_str" "$throughput" "$dcb" "$brotli" "$gap"
        report+="$row\n"
    done
    
    report+="\n"
    report+="--------------------------------------------------------------------------------\n"
    report+="                              ANALYSIS\n"
    report+="--------------------------------------------------------------------------------\n"
    report+="\n"
    report+="DCB (Dictionary Compressed Brotli) uses the base file as a dictionary.\n"
    report+="Brotli is standard brotli compression without dictionary.\n"
    report+="Gap = DCB Read Time - Brotli Read Time\n"
    report+="\n"
    report+="Positive gap: DCB is slower (requires reading dictionary from cache)\n"
    report+="Negative gap: DCB is faster\n"
    report+="\n"
    report+="As I/O delay increases, the gap typically increases because DCB\n"
    report+="requires additional I/O to read the dictionary from disk cache.\n"
    report+="\n"
    report+="================================================================================\n"
    report+="Results saved to: $RESULTS_FILE\n"
    report+="Report saved to: $REPORT_FILE\n"
    report+="================================================================================\n"
    
    echo -e "$report" | tee "$REPORT_FILE"
}

# Main execution
main() {
    echo ""
    log_header "CDT Performance Sweep"
    echo "=========================================="
    echo "Start Delay: ${START_DELAY}ms"
    echo "End Delay: ${END_DELAY}ms"
    echo "Increment: ${INCREMENT}ms"
    echo "Results file: $RESULTS_FILE"
    echo "=========================================="
    echo ""
    
    # Check prerequisites
    if [ ! -x "./setup-throttled-io.sh" ]; then
        log_error "setup-throttled-io.sh not found or not executable"
        exit 1
    fi
    
    if [ ! -f "package.json" ]; then
        log_error "package.json not found. Run from project root."
        exit 1
    fi
    
    # Check for sudo
    if ! sudo -v; then
        log_error "This script requires sudo privileges for I/O throttling"
        exit 1
    fi
    
    # Initialize CSV file
    echo "Delay_ms,Throughput,DCB_Read_ms,Brotli_Read_ms,Gap_ms" > "$RESULTS_FILE"
    
    # Run control test (no delay) first
    log_header "Running control test (no throttling)..."
    
    # For control, just run without throttled I/O
    log_info "Running CDT test without I/O throttling..."
    local control_output
    control_output=$(CDT_CACHE_DIR="$HOME/.cache/cdt-test-control" /usr/bin/npm test 2>&1) || {
        log_warn "Control test failed, continuing with throttled tests"
    }
    
    local control_timings
    control_timings=$(parse_test_output "$control_output")
    local control_dcb=$(echo "$control_timings" | cut -d',' -f1)
    local control_brotli=$(echo "$control_timings" | cut -d',' -f2)
    local control_gap="~0"
    
    if [ -n "$control_dcb" ] && [ -n "$control_brotli" ]; then
        control_gap=$(echo "scale=2; $control_dcb - $control_brotli" | bc)
    fi
    
    # Add control to results
    DELAYS+=("0 (control)")
    THROUGHPUTS+=("~1 GB/s")
    DCB_READ_TIMES+=("${control_dcb:-N/A}")
    BROTLI_READ_TIMES+=("${control_brotli:-N/A}")
    GAPS+=("${control_gap}")
    
    echo "0 (control),~1 GB/s,${control_dcb:-N/A},${control_brotli:-N/A},${control_gap}" >> "$RESULTS_FILE"
    
    log_info "Control results: DCB=${control_dcb}ms, Brotli=${control_brotli}ms"
    
    # Run tests for each delay value
    local delay=$START_DELAY
    local test_count=0
    local total_tests=$(( (END_DELAY - START_DELAY) / INCREMENT + 1 ))
    
    while [ "$delay" -le "$END_DELAY" ]; do
        test_count=$((test_count + 1))
        log_info "Test $test_count of $total_tests"
        
        if ! run_test_iteration "$delay"; then
            log_error "Test iteration failed for delay=${delay}ms"
            # Continue with next iteration
        fi
        
        delay=$((delay + INCREMENT))
    done
    
    # Generate final report
    generate_report
    
    log_info "Performance sweep complete!"
}

# Run main
main "$@"
